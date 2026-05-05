

#!/bin/bash

# Falcon Sensor EKS Node Installation Script
# This script installs Falcon Sensor, KAC, and Image Analyzer on an AWS EKS cluster

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
INPUTS_FILE="${SCRIPT_DIR}/eks_node_helm_inputs.txt"
HELM_VALUES_FILE="${SCRIPT_DIR}/eks_node_helm.yaml"

if [[ ! -f "$INPUTS_FILE" ]]; then
    log_error "Configuration file not found: $INPUTS_FILE"
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

# Get Falcon CID
log_info "Retrieving Falcon CID"
FALCON_CID=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-sensor \
  --get-cid)

if [[ -z "$FALCON_CID" ]]; then
    log_error "Failed to retrieve Falcon CID"
    exit 1
fi

export FALCON_CID
log_success "Retrieved Falcon CID: $FALCON_CID"

# Login to AWS ECR
log_info "Logging into AWS ECR"
aws ecr get-login-password --region "${AWS_REGION}" --profile "${AWS_PROFILE}" --no-paginate | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
log_success "Logged into AWS ECR"

# Encode Docker config
export ENCODED_DOCKER_CONFIG=$(base64 -w 0 ~/.docker/config.json 2>/dev/null || base64 -i ~/.docker/config.json)
log_success "Docker config encoded"

# Get image tags
log_info "Retrieving image tags from CrowdStrike registry"

KAC_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-kac \
  --get-image-path)
export KAC_TAG="${KAC_IMAGE_PATH##*:}"

SENSOR_IMAGE_PATH=$(./falcon-container-sensor-pull.sh \
  --client-id "${FALCON_CLIENT_ID}" \
  --client-secret "${FALCON_CLIENT_SECRET}" \
  --type falcon-sensor \
  --get-image-path)
export SENSOR_TAG="${SENSOR_IMAGE_PATH##*:}"

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

# Set additional environment variables for Helm values
export SENSOR_IMAGE_TAG="${SENSOR_TAG}"
export KAC_IMAGE_TAG="${KAC_TAG}"
export IAR_IMAGE_TAG="${IAR_TAG}"

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

# Process Helm values file with environment variable substitution using sed
log_info "Processing Helm values file with sed"
PROCESSED_VALUES_FILE="/tmp/eks_node_helm_processed.yaml"

# Copy original file to temporary location
cp "${HELM_VALUES_FILE}" "${PROCESSED_VALUES_FILE}"

# Use sed to substitute environment variables
# Note: Using different delimiters for sed to handle URLs and special characters
sed -i.bak \
  -e "s|\${FALCON_SECRET_NAME}|${FALCON_SECRET_NAME}|g" \
  -e "s|\${ENCODED_DOCKER_CONFIG}|${ENCODED_DOCKER_CONFIG}|g" \
  -e "s|\${SENSOR_REGISTRY}|${SENSOR_REGISTRY}|g" \
  -e "s|\${SENSOR_IMAGE_TAG}|${SENSOR_IMAGE_TAG}|g" \
  -e "s|\${KAC_REGISTRY}|${KAC_REGISTRY}|g" \
  -e "s|\${KAC_IMAGE_TAG}|${KAC_IMAGE_TAG}|g" \
  -e "s|\${IAR_REGISTRY}|${IAR_REGISTRY}|g" \
  -e "s|\${IAR_IMAGE_TAG}|${IAR_IMAGE_TAG}|g" \
  -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
  -e "s|\${FALCON_CID}|${FALCON_CID}|g" \
  "${PROCESSED_VALUES_FILE}"

# Remove backup file created by sed -i
rm -f "${PROCESSED_VALUES_FILE}.bak"

# Install/upgrade Falcon Platform using Helm
log_info "Installing/upgrading Falcon Platform Helm chart"
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --values "${PROCESSED_VALUES_FILE}" \
  --wait \
  --timeout=10m

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
log_success "Falcon Sensor installation completed successfully!"
log_info "Please verify that all pods are running correctly."

# Cleanup
rm -f falcon-container-sensor-pull.sh
rm -f "${PROCESSED_VALUES_FILE}"

log_info "Installation script completed."
