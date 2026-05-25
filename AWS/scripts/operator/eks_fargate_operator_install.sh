#!/bin/bash

# Falcon Operator EKS Fargate Installation Script
# This script installs the CrowdStrike Falcon Operator on an existing AWS EKS Fargate cluster
# and deploys FalconAdmission (KAC), FalconImageAnalyzer (IAR) and FalconContainerSensor (sidecar
# injector) using the FalconDeploymentFargate.yaml manifest. To enable Container Sensor
# auto-update instead, point DEPLOYMENT_MANIFEST below at FalconDeploymentFargateAutoUpdate.yaml.
#
# Fargate-specific responsibilities handled by this script:
#   - Associates an IAM OIDC provider with the EKS cluster
#   - Creates an IAM ECR-pull policy
#   - Creates two IAM roles (one for the falcon-injector SA, one for the falcon-kac SA)
#     with trust policies scoped via OIDC to system:serviceaccount:<ns>:<sa-name>
#   - Substitutes both IAM role names AND image account/region/namespace/tags into the
#     FalconDeployment manifest before applying it. The Falcon Operator then creates the
#     service accounts with the eks.amazonaws.com/role-arn annotations populated, enabling
#     IRSA-based ECR pulls on Fargate (where node-level credentials are unavailable).

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
INPUTS_FILE="${SCRIPT_DIR}/eks_fargate_operator_inputs.txt"
DEPLOYMENT_MANIFEST="${SCRIPT_DIR}/FalconDeploymentFargate.yaml"

if [[ ! -f "$INPUTS_FILE" ]]; then
    log_error "Configuration file not found: $INPUTS_FILE"
    log_info "Please create $INPUTS_FILE with the required configuration variables"
    exit 1
fi

if [[ ! -f "$DEPLOYMENT_MANIFEST" ]]; then
    log_error "Deployment manifest file not found: $DEPLOYMENT_MANIFEST"
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
    "CLUSTER_NAME"
    "FALCON_OPERATOR_VERSION"
    "FALCON_INJECTOR_ROLE_NAME"
    "FALCON_ADMISSION_ROLE_NAME"
    "FALCON_INJECTOR_NAMESPACE"
    "FALCON_INJECTOR_SA_NAME"
    "FALCON_ADMISSION_NAMESPACE"
    "FALCON_ADMISSION_SA_NAME"
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

# Download falcon-container-sensor-pull script
log_info "Downloading falcon-container-sensor-pull.sh script"
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"
chmod +x falcon-container-sensor-pull.sh
log_success "Downloaded falcon-container-sensor-pull.sh"

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

# Update kubeconfig
log_info "Updating kubeconfig for EKS cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --profile "${AWS_PROFILE}" --no-paginate
log_success "Kubeconfig updated"

# Associate cluster with IAM OIDC provider
log_info "Associating EKS cluster with IAM OIDC provider"
eksctl utils associate-iam-oidc-provider \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --cluster "${CLUSTER_NAME}" \
  --approve
log_success "IAM OIDC provider associated with cluster"

# Get OIDC issuer URL for IRSA trust policies
log_info "Retrieving OIDC issuer URL for cluster: $CLUSTER_NAME"
OIDC_ISSUER=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "cluster.identity.oidc.issuer" \
  --output text \
  --no-paginate)

if [[ -z "$OIDC_ISSUER" ]]; then
    log_error "Failed to get OIDC issuer URL for cluster $CLUSTER_NAME"
    exit 1
fi
log_success "OIDC issuer URL: $OIDC_ISSUER"

# Create IAM policy for ECR pull access (shared by both roles)
export iam_policy_name="FalconContainerEcrPull"
export iam_policy_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${iam_policy_name}"

log_info "Creating IAM policy for ECR access (${iam_policy_name})"

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

if ! aws iam create-policy \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --policy-name "${iam_policy_name}" \
  --policy-document 'file://policy.json' \
  --description "Policy to enable Falcon Container Injector / KAC to pull images from ECR" \
  --no-paginate 2>/dev/null; then
    log_warning "IAM policy ${iam_policy_name} already exists, continuing..."
else
    log_success "IAM policy ${iam_policy_name} created"
fi

rm -f policy.json

# Helper to create or update an IRSA role
create_irsa_role() {
    local role_name="$1"
    local sa_namespace="$2"
    local sa_name="$3"
    local description="$4"

    local trust_policy_file
    trust_policy_file=$(mktemp)

    cat > "${trust_policy_file}" <<EOF
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
          "${OIDC_ISSUER#https://}:sub": "system:serviceaccount:${sa_namespace}:${sa_name}",
          "${OIDC_ISSUER#https://}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

    if ! aws iam create-role \
      --profile "${AWS_PROFILE}" \
      --role-name "${role_name}" \
      --assume-role-policy-document "file://${trust_policy_file}" \
      --description "${description}" \
      --no-paginate 2>/dev/null; then
        log_warning "IAM role ${role_name} already exists, updating trust policy..."
        aws iam update-assume-role-policy \
          --profile "${AWS_PROFILE}" \
          --role-name "${role_name}" \
          --policy-document "file://${trust_policy_file}" \
          --no-paginate > /dev/null 2>&1
    else
        log_success "IAM role ${role_name} created"
    fi

    aws iam attach-role-policy \
      --profile "${AWS_PROFILE}" \
      --role-name "${role_name}" \
      --policy-arn "${iam_policy_arn}" \
      --no-paginate > /dev/null 2>&1

    rm -f "${trust_policy_file}"
}

# Create IAM role for the Falcon Container injector ServiceAccount
log_info "Creating IAM role for Falcon Container Injector SA: ${FALCON_INJECTOR_NAMESPACE}/${FALCON_INJECTOR_SA_NAME}"
create_irsa_role \
    "${FALCON_INJECTOR_ROLE_NAME}" \
    "${FALCON_INJECTOR_NAMESPACE}" \
    "${FALCON_INJECTOR_SA_NAME}" \
    "IAM role for Falcon Container Injector on EKS Fargate"

# Create IAM role for the Falcon Admission (KAC) ServiceAccount
log_info "Creating IAM role for Falcon Admission (KAC) SA: ${FALCON_ADMISSION_NAMESPACE}/${FALCON_ADMISSION_SA_NAME}"
create_irsa_role \
    "${FALCON_ADMISSION_ROLE_NAME}" \
    "${FALCON_ADMISSION_NAMESPACE}" \
    "${FALCON_ADMISSION_SA_NAME}" \
    "IAM role for Falcon Admission Controller (KAC) on EKS Fargate"

log_success "IRSA IAM roles created"
log_info "Falcon Injector Role: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FALCON_INJECTOR_ROLE_NAME}"
log_info "Falcon Admission Role: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FALCON_ADMISSION_ROLE_NAME}"

# Install the Falcon Operator
log_info "Installing Falcon Operator version ${FALCON_OPERATOR_VERSION}"
kubectl apply -f "https://github.com/crowdstrike/falcon-operator/releases/download/${FALCON_OPERATOR_VERSION}/falcon-operator.yaml"

# Wait for the operator to be ready
log_info "Waiting for Falcon Operator deployment to become available"
kubectl wait --for=condition=Available \
  deployment/falcon-operator-controller-manager \
  -n falcon-operator \
  --timeout=5m
log_success "Falcon Operator is ready"

# Create falcon-secret namespace and secret (referenced by spec.falconSecret in the manifest)
log_info "Creating falcon-secret namespace"
kubectl create namespace falcon-secret --dry-run=client -o yaml | kubectl apply -f -

log_info "Creating Falcon API credentials secret (falcon-secrets) in falcon-secret namespace"
kubectl create secret generic falcon-secrets \
  -n falcon-secret \
  --from-literal=falcon-client-id="${FALCON_CLIENT_ID}" \
  --from-literal=falcon-client-secret="${FALCON_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_success "Secret created/updated"

# Process deployment manifest with environment variable substitution using sed
log_info "Processing FalconDeployment manifest with sed"
PROCESSED_MANIFEST="/tmp/FalconDeploymentFargate_processed.yaml"

# Copy original file to temporary location
cp "${DEPLOYMENT_MANIFEST}" "${PROCESSED_MANIFEST}"

# Use sed to substitute placeholders in the manifest. The
# FalconDeploymentFargate.yaml template uses these placeholders:
#   <YOUR_AWS_ACCOUNT_ID>            -> AWS account ID
#   <AWS_REGIONS>                    -> AWS region
#   <YOUR_NAMESPACE>                 -> ECR namespace prefix
#   <TAG>                            -> per-image, scoped via the image path
#   <FALCON_CONTAINER_INJECTOR_ROLE> -> IAM role name for the injector SA
#   <FALCON_ADMISSION_ROLE>          -> IAM role name for the KAC SA
sed -i.bak \
  -e "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<AWS_REGIONS>|${AWS_REGION}|g" \
  -e "s|<YOUR_NAMESPACE>|${IMAGE_REPO_NAMESPACE}|g" \
  -e "s|<FALCON_CONTAINER_INJECTOR_ROLE>|${FALCON_INJECTOR_ROLE_NAME}|g" \
  -e "s|<FALCON_ADMISSION_ROLE>|${FALCON_ADMISSION_ROLE_NAME}|g" \
  "${PROCESSED_MANIFEST}"

# Replace the <TAG> placeholders per-image. Each image line appears on its own line,
# so we match using the image path to scope the replacement.
sed -i.bak \
  -e "/falcon-container:<TAG>/ s|<TAG>|${CONTAINER_TAG}|g" \
  -e "/falcon-imageanalyzer:<TAG>/ s|<TAG>|${IAR_TAG}|g" \
  -e "/falcon-kac:<TAG>/ s|<TAG>|${KAC_TAG}|g" \
  "${PROCESSED_MANIFEST}"

# Remove backup files created by sed -i
rm -f "${PROCESSED_MANIFEST}.bak"

log_success "Manifest processed successfully"
log_info "Processed manifest: ${PROCESSED_MANIFEST}"

# Apply the FalconDeployment manifest
log_info "Applying FalconDeployment manifest"
kubectl apply -f "${PROCESSED_MANIFEST}"
log_success "FalconDeployment applied"

# Verify installation
log_info "Verifying installation"

echo
log_info "FalconDeployment resource:"
kubectl get falcondeployments

echo
log_info "Deployments in falcon-operator namespace:"
kubectl get deployments -n falcon-operator

echo
log_info "Pods in falcon-operator namespace:"
kubectl get pods -n falcon-operator

echo
log_info "FalconAdmission (KAC) pods:"
kubectl get pods -A | grep -i falcon-kac || true

echo
log_info "FalconContainerSensor (injector) pods:"
kubectl get pods -A | grep -i injector || true

echo
log_info "FalconImageAnalyzer pods:"
kubectl get pods -A | grep -i imageanalyzer || true

echo
log_info "Webhook configurations:"
kubectl get validatingwebhookconfigurations | grep falcon || true
kubectl get mutatingwebhookconfigurations | grep falcon || true

echo
log_success "Falcon Operator installation for EKS Fargate completed successfully!"
log_info "Reminders for Fargate:"
log_info "  - Ensure a Fargate profile exists that selects the Falcon component namespaces"
log_info "    (default: ${FALCON_INJECTOR_NAMESPACE}, ${FALCON_ADMISSION_NAMESPACE}, falcon-image-analyzer, falcon-operator, falcon-secret)"
log_info "  - Ensure target workload namespaces are also covered by a Fargate profile so the"
log_info "    mutating webhook can inject the Falcon Container sidecar at pod creation."
log_info "You can manage deployments with: kubectl get falcondeployments"
log_info "To edit the deployment later: kubectl edit falcondeployment falcon-deployment"

# Cleanup
rm -f falcon-container-sensor-pull.sh
rm -f "${PROCESSED_MANIFEST}"

log_info "Installation script completed."
