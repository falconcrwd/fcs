#!/bin/bash

# Falcon Platform EKS Fargate Installation Script
# This script installs Falcon Container Sensor, KAC, and Image Analyzer on AWS EKS Fargate
# Includes eksctl installation, IAM OIDC association, and service account creation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration from inputs file
INPUTS_FILE="${SCRIPT_DIR}/eks_fargate_helm_inputs.txt"
HELM_VALUES_FILE="${SCRIPT_DIR}/eks_fargate_helm.yaml"

if [[ ! -f "$INPUTS_FILE" ]]; then
    log_error "Configuration file not found: $INPUTS_FILE"
    log_info "Please create $INPUTS_FILE with the required configuration variables"
    exit 1
fi

if [[ ! -f "$HELM_VALUES_FILE" ]]; then
    log_error "Helm values file not found: $HELM_VALUES_FILE"
    exit 1
fi

log_info "Loading configuration from $INPUTS_FILE"

# Source the configuration file
source "$INPUTS_FILE"

# Validate required variables
required_vars=(
    "FALCON_CLIENT_ID"
    "FALCON_CLIENT_SECRET"
    "AWS_REGION"
    "AWS_PROFILE"
    "AWS_ACCOUNT_ID"
    "IMAGE_REPO_NAMESPACE"
    "FALCON_SECRET_NAME"
    "CLUSTER_NAME"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required variable $var is not set in $INPUTS_FILE"
        exit 1
    fi
done

log_success "Configuration loaded successfully"

# Check if eksctl is installed, if not, install it
if ! command -v eksctl &> /dev/null; then
    log_info "eksctl not found. Installing eksctl..."

    ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
    PLATFORM=$(uname -s)_$ARCH

    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"

    # Verify checksum (optional but recommended)
    log_info "Verifying eksctl checksum..."
    if curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check; then
        log_success "Checksum verification passed"
    else
        log_warning "Checksum verification failed, but continuing with installation"
    fi

    tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz

    if [[ "$EUID" -eq 0 ]]; then
        # Running as root
        install -m 0755 /tmp/eksctl /usr/local/bin && rm /tmp/eksctl
    else
        # Running as non-root, use sudo
        sudo install -m 0755 /tmp/eksctl /usr/local/bin && rm /tmp/eksctl
    fi

    log_success "eksctl installed successfully"
else
    log_success "eksctl is already installed"
fi

# Check if Helm is installed, if not, install it
if ! command -v helm &> /dev/null; then
    log_info "Helm not found. Installing Helm..."

    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh

    # Clean up installation script
    rm -f get_helm.sh

    log_success "Helm installed successfully"
else
    log_success "Helm is already installed"
fi

# Download falcon-container-sensor-pull script
log_info "Downloading falcon-container-sensor-pull.sh script"
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"
chmod +x falcon-container-sensor-pull.sh
log_success "Downloaded falcon-container-sensor-pull.sh"

# Get Falcon CID if not provided
if [[ -z "${FALCON_CID:-}" ]]; then
    log_info "Falcon CID not provided. Retrieving from CrowdStrike API..."

    FALCON_CID=$(./falcon-container-sensor-pull.sh \
      --client-id "${FALCON_CLIENT_ID}" \
      --client-secret "${FALCON_CLIENT_SECRET}" \
      --type falcon-container \
      --get-cid)

    if [[ -z "$FALCON_CID" ]]; then
        log_error "Failed to retrieve Falcon CID"
        exit 1
    fi

    export FALCON_CID
    log_success "Retrieved Falcon CID: $FALCON_CID"
else
    export FALCON_CID
    log_success "Using provided Falcon CID: $FALCON_CID"
fi

# Associate cluster with IAM OIDC provider
log_info "Associating EKS cluster with IAM OIDC provider"
eksctl utils associate-iam-oidc-provider \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --cluster "${CLUSTER_NAME}" \
  --approve
log_success "IAM OIDC provider associated with cluster"

# Login to AWS ECR
log_info "Logging into AWS ECR"
aws ecr get-login-password --region "${AWS_REGION}" --profile "${AWS_PROFILE}" --no-paginate | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
log_success "Logged into AWS ECR"

# Get image tags from CrowdStrike registry
log_info "Retrieving image tags from CrowdStrike registry"

CONTAINER_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-container \
  --get-image-path)
export CONTAINER_TAG="${CONTAINER_IMAGE_PATH##*:}"

KAC_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-kac \
  --get-image-path)
export KAC_TAG="${KAC_IMAGE_PATH##*:}"

IAR_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-imageanalyzer \
  --get-image-path)
export IAR_TAG="${IAR_IMAGE_PATH##*:}"

log_success "Retrieved image tags - Container: $CONTAINER_TAG, KAC: $KAC_TAG, IAR: $IAR_TAG"

# Set registry paths
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_REPO_NAMESPACE}"
export CONTAINER_SENSOR_REGISTRY="${ECR_BASE}/falcon-container"
export KAC_REGISTRY="${ECR_BASE}/falcon-kac"
export IAR_REGISTRY="${ECR_BASE}/falcon-imageanalyzer"

# Download and push images to ECR
log_info "Downloading and pushing Falcon Container Sensor image to ECR"
./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --version "${CONTAINER_TAG}" \
  --type falcon-container \
  -c "${ECR_BASE}"

log_info "Downloading and pushing Falcon KAC image to ECR"
./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --version "${KAC_TAG}" \
  --type falcon-kac \
  -c "${ECR_BASE}"

log_info "Downloading and pushing Falcon Image Analyzer image to ECR"
./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --version "${IAR_TAG}" \
  --type falcon-imageanalyzer \
  -c "${ECR_BASE}"

log_success "All images pushed to ECR successfully"

# Set additional environment variables for Helm values
export CONTAINER_SENSOR_IMAGE_TAG="${CONTAINER_TAG}"
export KAC_IMAGE_TAG="${KAC_TAG}"
export IAR_IMAGE_TAG="${IAR_TAG}"

# Create IAM policy for ECR access
export iam_policy_name="FalconContainerEcrPull"
export iam_policy_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${iam_policy_name}"

log_info "Creating IAM policy for ECR access"

# Create policy document
cat <<EOF > policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowImagePull",
            "Effect": "Allow",
            "Action": [
                "ecr:BatchGetImage",
                "ecr:DescribeImages",
                "ecr:GetDownloadUrlForLayer",
                "ecr:ListImages"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowECRSetup",
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken"
            ],
            "Resource": "*"
        }
    ]
}
EOF

# Create IAM policy (ignore error if it already exists)
if ! aws iam create-policy \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --policy-name ${iam_policy_name} \
  --policy-document 'file://policy.json' \
  --description "Policy to enable Falcon Container Injector or KAC to pull container image from ECR" \
  --no-paginate 2>/dev/null; then
    log_warning "IAM policy ${iam_policy_name} already exists, continuing..."
else
    log_success "IAM policy ${iam_policy_name} created"
fi

# Clean up policy file
rm -f policy.json

# Update kubeconfig
log_info "Updating kubeconfig for EKS cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --profile "${AWS_PROFILE}" --no-paginate
log_success "Kubeconfig updated"

# Create namespaces
log_info "Creating Kubernetes namespaces"
kubectl create namespace falcon-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falcon-kac --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falcon-image-analyzer --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace falcon-platform --dry-run=client -o yaml | kubectl apply -f -
log_success "Namespaces created/verified"

# Create IAM role for service accounts (without creating the service accounts)
log_info "Creating IAM roles for Falcon service accounts"

# Get OIDC issuer URL first
log_info "Retrieving OIDC issuer URL for cluster: $CLUSTER_NAME"
OIDC_ISSUER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}" --query "cluster.identity.oidc.issuer" --output text --no-paginate)

if [[ -z "$OIDC_ISSUER" ]]; then
    log_error "Failed to get OIDC issuer URL for cluster $CLUSTER_NAME"
    exit 1
fi

log_success "OIDC issuer URL: $OIDC_ISSUER"

# Create IAM role for Falcon Container Sensor
FALCON_ROLE_NAME="FalconContainerSensorRole-${CLUSTER_NAME}"
FALCON_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER#https://}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER#https://}:sub": "system:serviceaccount:falcon-system:crowdstrike-falcon-sa",
          "${OIDC_ISSUER#https://}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

# Create Falcon sensor IAM role
echo "${FALCON_TRUST_POLICY}" > falcon-trust-policy.json

if ! aws iam create-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${FALCON_ROLE_NAME}" \
  --assume-role-policy-document file://falcon-trust-policy.json \
  --description "IAM role for Falcon Container Sensor in EKS Fargate" \
  --no-paginate 2>/dev/null; then
    log_warning "Falcon sensor IAM role already exists, updating trust policy..."
    aws iam update-assume-role-policy \
      --profile "${AWS_PROFILE}" \
      --role-name "${FALCON_ROLE_NAME}" \
      --policy-document file://falcon-trust-policy.json \
      --no-paginate > /dev/null 2>&1
fi

# Attach ECR policy to Falcon sensor role
aws iam attach-role-policy \
  --profile "${AWS_PROFILE}" \
  --role-name "${FALCON_ROLE_NAME}" \
  --policy-arn "${iam_policy_arn}" \
  --no-paginate > /dev/null 2>&1

export FALCON_SA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FALCON_ROLE_NAME}"

# Create KAC IAM role
KAC_ROLE_NAME="FalconKACRole-${CLUSTER_NAME}"
KAC_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER#https://}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER#https://}:sub": "system:serviceaccount:falcon-kac:falcon-kac-sa",
          "${OIDC_ISSUER#https://}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

echo "${KAC_TRUST_POLICY}" > kac-trust-policy.json

if ! aws iam create-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${KAC_ROLE_NAME}" \
  --assume-role-policy-document file://kac-trust-policy.json \
  --description "IAM role for Falcon KAC in EKS Fargate" \
  --no-paginate 2>/dev/null; then
    log_warning "Falcon KAC IAM role already exists, updating trust policy..."
    aws iam update-assume-role-policy \
      --profile "${AWS_PROFILE}" \
      --role-name "${KAC_ROLE_NAME}" \
      --policy-document file://kac-trust-policy.json \
      --no-paginate > /dev/null 2>&1
fi

# Attach ECR policy to KAC role
aws iam attach-role-policy \
  --profile "${AWS_PROFILE}" \
  --role-name "${KAC_ROLE_NAME}" \
  --policy-arn "${iam_policy_arn}" \
  --no-paginate > /dev/null 2>&1

export KAC_SA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KAC_ROLE_NAME}"

# Clean up policy files
rm -f falcon-trust-policy.json kac-trust-policy.json

log_success "IAM roles created successfully"
log_success "Falcon Sensor Role ARN: ${FALCON_SA_ROLE_ARN}"
log_success "Falcon KAC Role ARN: ${KAC_SA_ROLE_ARN}"

# Create secrets
log_info "Creating Falcon secrets"
kubectl create secret generic "${FALCON_SECRET_NAME}" \
  -n falcon-system \
  --from-literal=FALCONCTL_OPT_CID="${FALCON_CID}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${FALCON_SECRET_NAME}" \
  -n falcon-kac \
  --from-literal=FALCONCTL_OPT_CID="${FALCON_CID}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${FALCON_SECRET_NAME}" \
  -n falcon-image-analyzer \
  --from-literal=AGENT_CLIENT_ID="${FALCON_CLIENT_ID}" \
  --from-literal=AGENT_CLIENT_SECRET="${FALCON_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

log_success "Secrets created/updated"

# Add Helm repository
log_info "Adding CrowdStrike Helm repository"
helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm
helm repo update
log_success "Helm repository updated"

# Set environment variables for Helm values substitution
export CONTAINER_SENSOR_REGISTRY
export CONTAINER_SENSOR_IMAGE_TAG
export KAC_REGISTRY
export KAC_IMAGE_TAG
export IAR_REGISTRY
export IAR_IMAGE_TAG

# Process Helm values file with environment variable substitution using sed
log_info "Processing Helm values file with sed"
PROCESSED_VALUES_FILE="/tmp/eks_fargate_helm_processed.yaml"

# Copy original file to temporary location
cp "${HELM_VALUES_FILE}" "${PROCESSED_VALUES_FILE}"

# Use sed to substitute environment variables
# Note: Using different delimiters for sed to handle URLs and special characters
sed -i.bak \
  -e "s|\${FALCON_SECRET_NAME}|${FALCON_SECRET_NAME}|g" \
  -e "s|\${CONTAINER_SENSOR_REGISTRY}|${CONTAINER_SENSOR_REGISTRY}|g" \
  -e "s|\${CONTAINER_SENSOR_IMAGE_TAG}|${CONTAINER_SENSOR_IMAGE_TAG}|g" \
  -e "s|\${KAC_REGISTRY}|${KAC_REGISTRY}|g" \
  -e "s|\${KAC_IMAGE_TAG}|${KAC_IMAGE_TAG}|g" \
  -e "s|\${IAR_REGISTRY}|${IAR_REGISTRY}|g" \
  -e "s|\${IAR_IMAGE_TAG}|${IAR_IMAGE_TAG}|g" \
  -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
  -e "s|\${FALCON_CLIENT_ID}|${FALCON_CLIENT_ID}|g" \
  -e "s|\${FALCON_CLIENT_SECRET}|${FALCON_CLIENT_SECRET}|g" \
  -e "s|\${FALCON_CID}|${FALCON_CID}|g" \
  -e "s|\${FALCON_SA_ROLE_ARN}|${FALCON_SA_ROLE_ARN}|g" \
  -e "s|\${KAC_SA_ROLE_ARN}|${KAC_SA_ROLE_ARN}|g" \
  "${PROCESSED_VALUES_FILE}"

# Remove backup file created by sed -i
rm -f "${PROCESSED_VALUES_FILE}.bak"

# Install/upgrade Falcon Platform using Helm
log_info "Installing/upgrading Falcon Platform Helm chart for Fargate"
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --values "${PROCESSED_VALUES_FILE}" \
  --wait \
  --timeout=15m

log_success "Falcon Platform Helm chart installed successfully"

# Verify installation
log_info "Verifying installation"
echo
log_info "Checking pod status in falcon-system namespace:"
kubectl get pods -n falcon-system

echo
log_info "Checking pod status in falcon-kac namespace:"
kubectl get pods -n falcon-kac

echo
log_info "Checking pod status in falcon-image-analyzer namespace:"
kubectl get pods -n falcon-image-analyzer

echo
log_info "Checking webhook configurations:"
kubectl get validatingwebhookconfigurations | grep falcon || true
kubectl get mutatingwebhookconfigurations | grep falcon || true

echo
log_success "Falcon Platform installation for EKS Fargate completed successfully!"
log_info "Please verify that all pods are running correctly."
log_info "Container sensor will inject into new pods automatically via mutating webhook."

# Cleanup
rm -f falcon-container-sensor-pull.sh 2>/dev/null || true
rm -f "${PROCESSED_VALUES_FILE}"

log_info "Installation script completed."