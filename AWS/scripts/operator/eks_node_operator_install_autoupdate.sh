#!/bin/bash

# Falcon Operator EKS Node Installation Script (AutoUpdate variant)
# This script installs the CrowdStrike Falcon Operator on an existing AWS EKS cluster
# with node pools, and deploys FalconAdmission, FalconNodeSensor and FalconImageAnalyzer
# using the FalconDeploymentNodeAutoUpdate.yaml manifest.
#
# Unlike eks_node_operator_install.sh, this variant does NOT mirror images to ECR.
# Instead, it relies on the Falcon Operator's Falcon API credentials to:
#   1. Pull images directly from registry.crowdstrike.com.
#   2. Periodically check for new sensor versions and reconcile the daemonset
#      (autoUpdate). AutoUpdate requires a non-nil Spec.FalconAPI block and an
#      unpinned node image, both of which are configured in
#      FalconDeploymentNodeAutoUpdate.yaml.

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
INPUTS_FILE="${SCRIPT_DIR}/eks_node_operator_inputs_autoupdate.txt"
DEPLOYMENT_MANIFEST="${SCRIPT_DIR}/FalconDeploymentNodeAutoUpdate.yaml"

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

# Create falcon-secret namespace and secret. The Falcon Operator will read these
# values to populate Spec.FalconAPI.ClientId / ClientSecret on the child CRs and
# to authenticate with the CrowdStrike API for sensor version discovery and
# image pulls from registry.crowdstrike.com.
log_info "Creating falcon-secret namespace"
kubectl create namespace falcon-secret --dry-run=client -o yaml | kubectl apply -f -

log_info "Creating Falcon API credentials secret (falcon-secrets) in falcon-secret namespace"
kubectl create secret generic falcon-secrets \
  -n falcon-secret \
  --from-literal=falcon-client-id="${FALCON_CLIENT_ID}" \
  --from-literal=falcon-client-secret="${FALCON_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_success "Secret created/updated"

# Apply the FalconDeployment manifest. No image-path substitution is needed:
# images are unpinned in FalconDeploymentNodeAutoUpdate.yaml so the operator
# resolves them from the CrowdStrike registry using the API credentials above.
log_info "Applying FalconDeployment manifest: ${DEPLOYMENT_MANIFEST}"
kubectl apply -f "${DEPLOYMENT_MANIFEST}"
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
log_success "Falcon Operator (AutoUpdate) installation for EKS Node completed successfully!"
log_info "Sensor auto-update is enabled (autoUpdate: normal). The operator will"
log_info "poll the CrowdStrike API every 24h by default and reconcile the"
log_info "FalconNodeSensor daemonset when a new sensor version is available."
log_info "You can manage deployments with: kubectl get falcondeployments"
log_info "To edit the deployment later: kubectl edit falcondeployments falcon-deployment"

log_info "Installation script completed."
