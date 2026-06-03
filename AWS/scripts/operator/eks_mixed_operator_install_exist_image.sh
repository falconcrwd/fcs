#!/bin/bash

# Falcon Operator EKS Mixed (Node + Fargate) Installation Script - Existing ECR Images
# This script installs the CrowdStrike Falcon Operator on an existing AWS EKS
# cluster that has BOTH EC2 node pools AND Fargate profiles, and deploys:
#   - FalconNodeSensor       (DaemonSet on EC2 nodes)
#   - FalconAdmission        (KAC, runs on EC2 nodes)
#   - FalconImageAnalyzer    (IAR, runs on EC2 nodes)
#   - FalconContainerSensor  (sidecar injector, runs on Fargate in the
#                             'falcon-injector' namespace)
# using the FalconDeploymentMixed.yaml manifest.
#
# Use this version when the Falcon Sensor, Container Sensor, KAC and Image
# Analyzer images are ALREADY present in your AWS Elastic Container Registry
# (ECR). The script skips downloading falcon-container-sensor-pull.sh, the
# CrowdStrike registry pull, and the ECR push steps. Image names and tags are
# read from eks_mixed_operator_inputs_exist_image.txt.
#
# Mixed-cluster IRSA scope:
#   - Only ONE IAM role is created for the Falcon Container injector
#     ServiceAccount on Fargate. Trust policy is scoped via OIDC to
#     system:serviceaccount:<FALCON_INJECTOR_NAMESPACE>:<FALCON_INJECTOR_SA_NAME>.
#   - KAC and IAR run on EC2 nodes and use the node IAM role for ECR pulls,
#     so they do NOT require IRSA in this topology.
#
# Note: this exist-image variant always applies FalconDeploymentMixed.yaml.
# Auto-update is intentionally not supported because auto-update is
# incompatible with private/ECR registries.

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
INPUTS_FILE="${SCRIPT_DIR}/eks_mixed_operator_inputs_exist_image.txt"
DEPLOYMENT_MANIFEST="${SCRIPT_DIR}/FalconDeploymentMixed.yaml"

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
    "FALCON_INJECTOR_NAMESPACE"
    "FALCON_INJECTOR_SA_NAME"
    "SENSOR_IMAGE_NAME"
    "SENSOR_IMAGE_TAG"
    "CONTAINER_IMAGE_NAME"
    "CONTAINER_IMAGE_TAG"
    "KAC_IMAGE_NAME"
    "KAC_IMAGE_TAG"
    "IAR_IMAGE_NAME"
    "IAR_IMAGE_TAG"
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

# Set registry paths from inputs (existing images in ECR - no pull/push needed)
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_REPO_NAMESPACE}"
export SENSOR_REGISTRY="${ECR_BASE}/${SENSOR_IMAGE_NAME}"
export CONTAINER_REGISTRY="${ECR_BASE}/${CONTAINER_IMAGE_NAME}"
export KAC_REGISTRY="${ECR_BASE}/${KAC_IMAGE_NAME}"
export IAR_REGISTRY="${ECR_BASE}/${IAR_IMAGE_NAME}"
export SENSOR_TAG="${SENSOR_IMAGE_TAG}"
export CONTAINER_TAG="${CONTAINER_IMAGE_TAG}"
export KAC_TAG="${KAC_IMAGE_TAG}"
export IAR_TAG="${IAR_IMAGE_TAG}"

log_info "Using existing ECR images:"
log_info "  Sensor:    ${SENSOR_REGISTRY}:${SENSOR_TAG}"
log_info "  Container: ${CONTAINER_REGISTRY}:${CONTAINER_TAG}"
log_info "  KAC:       ${KAC_REGISTRY}:${KAC_TAG}"
log_info "  IAR:       ${IAR_REGISTRY}:${IAR_TAG}"

# Verify the images exist in ECR
log_info "Verifying existing images in ECR"
verify_ecr_image() {
    local repo_name="$1"
    local image_tag="$2"
    if aws ecr describe-images \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --repository-name "${IMAGE_REPO_NAMESPACE}/${repo_name}" \
        --image-ids imageTag="${image_tag}" \
        --no-paginate > /dev/null 2>&1; then
        log_success "Found ${repo_name}:${image_tag} in ECR"
    else
        log_error "Image ${repo_name}:${image_tag} not found in ECR repository ${IMAGE_REPO_NAMESPACE}/${repo_name}"
        log_error "Please verify the image name and tag in ${INPUTS_FILE}"
        exit 1
    fi
}

verify_ecr_image "${SENSOR_IMAGE_NAME}" "${SENSOR_IMAGE_TAG}"
verify_ecr_image "${CONTAINER_IMAGE_NAME}" "${CONTAINER_IMAGE_TAG}"
verify_ecr_image "${KAC_IMAGE_NAME}" "${KAC_IMAGE_TAG}"
verify_ecr_image "${IAR_IMAGE_NAME}" "${IAR_IMAGE_TAG}"

log_success "All required images verified in ECR"

# Update kubeconfig
log_info "Updating kubeconfig for EKS cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --profile "${AWS_PROFILE}" --no-paginate
log_success "Kubeconfig updated"

# Associate cluster with IAM OIDC provider (required for IRSA on Fargate)
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

# Create IAM policy for ECR pull access (used by the injector role on Fargate)
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
  --description "Policy to enable Falcon Container Injector to pull images from ECR" \
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

# Create IAM role for the Falcon Container injector ServiceAccount (Fargate)
log_info "Creating IAM role for Falcon Container Injector SA: ${FALCON_INJECTOR_NAMESPACE}/${FALCON_INJECTOR_SA_NAME}"
create_irsa_role \
    "${FALCON_INJECTOR_ROLE_NAME}" \
    "${FALCON_INJECTOR_NAMESPACE}" \
    "${FALCON_INJECTOR_SA_NAME}" \
    "IAM role for Falcon Container Injector on EKS Fargate (mixed cluster)"

log_success "IRSA IAM role created"
log_info "Falcon Injector Role: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FALCON_INJECTOR_ROLE_NAME}"

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

# Create falcon-secret namespace and secret
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
PROCESSED_MANIFEST="/tmp/FalconDeploymentMixed_processed.yaml"

# Copy original file to temporary location
cp "${DEPLOYMENT_MANIFEST}" "${PROCESSED_MANIFEST}"

# Use sed to substitute the AWS placeholders and IAM role name. The
# FalconDeploymentMixed.yaml template uses these placeholders:
#   <YOUR_AWS_ACCOUNT_ID>            -> AWS account ID
#   <AWS_REGIONS>                    -> AWS region
#   <YOUR_NAMESPACE>                 -> ECR namespace prefix
#   <FALCON_CONTAINER_INJECTOR_ROLE> -> IAM role name for the injector SA
sed -i.bak \
  -e "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<AWS_REGIONS>|${AWS_REGION}|g" \
  -e "s|<YOUR_NAMESPACE>|${IMAGE_REPO_NAMESPACE}|g" \
  -e "s|<FALCON_CONTAINER_INJECTOR_ROLE>|${FALCON_INJECTOR_ROLE_NAME}|g" \
  "${PROCESSED_MANIFEST}"

# Replace the full image references for each of falcon-sensor, falcon-container,
# falcon-kac and falcon-imageanalyzer. We match each image line by the default
# image path component used in the template and rewrite the whole image: line
# to the user-specified existing ECR image path and tag.
SENSOR_FULL_IMAGE="${SENSOR_REGISTRY}:${SENSOR_TAG}"
CONTAINER_FULL_IMAGE="${CONTAINER_REGISTRY}:${CONTAINER_TAG}"
KAC_FULL_IMAGE="${KAC_REGISTRY}:${KAC_TAG}"
IAR_FULL_IMAGE="${IAR_REGISTRY}:${IAR_TAG}"

sed -i.bak \
  -e "/falcon-sensor:<TAG>/ s|image: .*falcon-sensor:<TAG>|image: ${SENSOR_FULL_IMAGE}|g" \
  -e "/falcon-container:<TAG>/ s|image: .*falcon-container:<TAG>|image: ${CONTAINER_FULL_IMAGE}|g" \
  -e "/falcon-imageanalyzer:<TAG>/ s|image: .*falcon-imageanalyzer:<TAG>|image: ${IAR_FULL_IMAGE}|g" \
  -e "/falcon-kac:<TAG>/ s|image: .*falcon-kac:<TAG>|image: ${KAC_FULL_IMAGE}|g" \
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
log_info "FalconNodeSensor DaemonSet (EC2 nodes):"
kubectl get daemonsets -A | grep -i falcon || true

echo
log_info "FalconContainerSensor injector pods (Fargate, namespace ${FALCON_INJECTOR_NAMESPACE}):"
kubectl get pods -n "${FALCON_INJECTOR_NAMESPACE}" 2>/dev/null || true

echo
log_info "FalconAdmission (KAC) pods:"
kubectl get pods -A | grep -i falcon-kac || true

echo
log_info "FalconImageAnalyzer pods:"
kubectl get pods -A | grep -i imageanalyzer || true

echo
log_info "Webhook configurations:"
kubectl get validatingwebhookconfigurations | grep falcon || true
kubectl get mutatingwebhookconfigurations | grep falcon || true

echo
log_success "Falcon Operator installation for EKS Mixed (Node + Fargate) completed successfully!"
log_info "Reminders for mixed clusters:"
log_info "  - Ensure a Fargate profile selects the '${FALCON_INJECTOR_NAMESPACE}' namespace"
log_info "    so the Falcon Container injector pod runs on Fargate."
log_info "  - Ensure target workload namespaces scheduled on Fargate are also covered"
log_info "    by a Fargate profile so the mutating webhook can sidecar-inject pods."
log_info "  - Fargate profile coverage is NOT required for falcon-operator (its"
log_info "    Deployment will run on EC2) or falcon-secret (no pods, just a Secret)."
log_info "  - DO NOT add Fargate profile coverage for falcon-kac, falcon-image-analyzer,"
log_info "    or falcon-system - those components are intended to run on EC2 nodes here."
log_info "You can manage deployments with: kubectl get falcondeployments"
log_info "To edit the deployment later: kubectl edit falcondeployment falcon-deployment"

# Cleanup
rm -f "${PROCESSED_MANIFEST}"

log_info "Installation script completed."
