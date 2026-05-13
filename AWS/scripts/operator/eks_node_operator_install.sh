#!/bin/bash

# Falcon Operator EKS Node Installation Script
# This script installs the CrowdStrike Falcon Operator on an existing AWS EKS cluster
# with node pools, and deploys FalconAdmission, FalconNodeSensor and FalconImageAnalyzer
# using the FalconDeploymentNode.yaml manifest.

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
INPUTS_FILE="${SCRIPT_DIR}/eks_node_operator_inputs.txt"
DEPLOYMENT_MANIFEST="${SCRIPT_DIR}/FalconDeploymentNode.yaml"

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

SENSOR_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-sensor \
  --get-image-path)
export SENSOR_TAG="${SENSOR_IMAGE_PATH##*:}"

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

log_success "Retrieved image tags - Sensor: $SENSOR_TAG, KAC: $KAC_TAG, IAR: $IAR_TAG"

# Set registry paths
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_REPO_NAMESPACE}"
export SENSOR_REGISTRY="${ECR_BASE}/falcon-sensor"
export KAC_REGISTRY="${ECR_BASE}/falcon-kac"
export IAR_REGISTRY="${ECR_BASE}/falcon-imageanalyzer"

# Download and push images to ECR
log_info "Downloading and pushing Falcon Sensor image to ECR"
./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --version "${SENSOR_TAG}" \
  --type falcon-sensor \
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
PROCESSED_MANIFEST="/tmp/FalconDeploymentNode_processed.yaml"

# Copy original file to temporary location
cp "${DEPLOYMENT_MANIFEST}" "${PROCESSED_MANIFEST}"

# Use sed to substitute placeholders in the manifest. The FalconDeploymentNode.yaml
# template uses <YOUR_AWS_ACCOUNT_ID>, <AWS_REGIONS>, <YOUR_NAMESPACE> and <TAG> placeholders
# for each of falcon-sensor, falcon-kac, and falcon-imageanalyzer images.
sed -i.bak \
  -e "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|<AWS_REGIONS>|${AWS_REGION}|g" \
  -e "s|<YOUR_NAMESPACE>|${IMAGE_REPO_NAMESPACE}|g" \
  "${PROCESSED_MANIFEST}"

# Replace the <TAG> placeholders per-image. Each image line appears on its own line,
# so we match using the image path to scope the replacement.
sed -i.bak \
  -e "/falcon-sensor:<TAG>/ s|<TAG>|${SENSOR_TAG}|g" \
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
log_info "FalconAdmission pods:"
kubectl get pods -n falcon-operator | grep -i falconadmission || true

echo
log_info "FalconNodeSensor pods:"
kubectl get pods -n falcon-operator | grep -i falconnodesensor || true

echo
log_info "FalconImageAnalyzer pods:"
kubectl get pods -n falcon-operator | grep -i falconimageanalyzer || true

echo
log_success "Falcon Operator installation for EKS Node completed successfully!"
log_info "Please verify that all Falcon components are running correctly."
log_info "You can manage deployments with: kubectl get falcondeployments"
log_info "To edit the deployment later: kubectl edit falcondeployments falcon-deployment"

# Cleanup
rm -f falcon-container-sensor-pull.sh
rm -f "${PROCESSED_MANIFEST}"

log_info "Installation script completed."
