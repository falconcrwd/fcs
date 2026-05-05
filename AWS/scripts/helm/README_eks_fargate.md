# Falcon Platform EKS Fargate Deployment

This directory contains scripts and configuration files to deploy CrowdStrike Falcon Platform components (Container Sensor, KAC, and Image Analyzer) on AWS EKS Fargate.

## Files Overview

- `eks_fargate_helm_install.sh` - Main installation script with full automation
- `eks_fargate_helm.yaml` - Helm values template optimized for Fargate
- `eks_fargate_helm_inputs.txt` - Configuration file

## Prerequisites

1. **AWS CLI** configured with appropriate permissions
2. **kubectl** installed and configured
3. **Docker** installed and running
4. **EKS Fargate cluster** already created
5. **CrowdStrike Falcon API credentials** (Client ID and Secret)

> **Note**: The installation script will automatically install **helm** (version 3.x) and **eksctl** if they are not already present on your system.

## Quick Start

### 1. Configure Environment

Create and customize the configuration file:

Edit `eks_fargate_helm_inputs.txt` with your specific values:

```bash
# Example configuration
FALCON_CLIENT_ID="your-falcon-client-id"
FALCON_CLIENT_SECRET="your-falcon-client-secret"
AWS_REGION="us-west-2"
AWS_PROFILE="default"
AWS_ACCOUNT_ID="123456789012"
CLUSTER_NAME="my-fargate-cluster"
IMAGE_REPO_NAMESPACE="crwd"
FALCON_SECRET_NAME="falcon-secret"
# Note: Image registries and tags are automatically retrieved and configured
```

### 2. Run Installation

Execute the main installation script:

```bash
./eks_fargate_helm_install.sh
```

This script will:
1. Install `eksctl` if not present
2. Install `helm` if not present
3. Download the `falcon-container-sensor-pull.sh` script
4. Retrieve Falcon CID and image tags from CrowdStrike
5. Download and push all Falcon images to your ECR repositories
6. Associate the EKS cluster with IAM OIDC provider
7. Create IAM policies and roles for ECR access
8. Create Kubernetes service accounts with IAM role bindings
9. Create necessary secrets and namespaces
10. Deploy Falcon Platform components using Helm

## What Gets Deployed

### Container Sensor
- **Purpose**: Workload protection for containers running on Fargate
- **Deployment**: Mutating webhook that injects sensor into pods
- **Namespace**: `falcon-system`

### Kubernetes Admission Controller (KAC)
- **Purpose**: Policy enforcement and cluster visibility
- **Deployment**: Validating webhook for admission control
- **Namespace**: `falcon-kac`

### Image Analyzer (IAR)
- **Purpose**: Container image security scanning
- **Deployment**: Deployment with image scanning capabilities
- **Namespace**: `falcon-image-analyzer`

## Fargate-Specific Configuration

The deployment is optimized for AWS Fargate with these key differences from standard EKS:

1. **Container Sensor Only**: Node sensor is disabled since Fargate doesn't provide node access
2. **IAM Roles for Service Accounts (IRSA)**: Required for Fargate workloads to access AWS services
3. **ECR Integration**: Configured for pulling images from ECR repositories
4. **Webhook-based Injection**: Uses mutating webhooks to inject sensors into workloads

## Verification

After deployment, verify the installation:

```bash
# Check pod status
kubectl get pods -n falcon-system
kubectl get pods -n falcon-kac
kubectl get pods -n falcon-image-analyzer

# Check webhook configurations
kubectl get validatingwebhookconfigurations | grep falcon
kubectl get mutatingwebhookconfigurations | grep falcon

# Test sensor injection (create a test pod)
kubectl run test-pod --image=nginx --restart=Never
kubectl describe pod test-pod | grep falcon

# Verify Falcon sensor is running and get Agent ID from injected sidecar
kubectl exec -it <pod-name> -n <namespace> -c crowdstrike-falcon-container -- falconctl -g --aid
# Example: kubectl exec -it test-pod -c crowdstrike-falcon-container -- falconctl -g --aid
```

## Troubleshooting

### Common Issues

1. **Service Account Conflicts**
   - Error: "ServiceAccount exists and cannot be imported"
   - Solution: The script automatically cleans up conflicting service accounts

2. **IAM Permission Errors**
   - Ensure AWS profile has permissions for EKS, IAM, and ECR operations

3. **Image Pull Errors**
   - Verify ECR registry paths and image tags in configuration
   - Check that Docker is logged into ECR

4. **Webhook Failures**
   - Check that the cluster has proper DNS resolution
   - Verify webhook certificates are valid

### Logs and Debugging

```bash
# Check Falcon sensor logs
kubectl logs -n falcon-system -l app=falcon-sensor

# Check KAC logs
kubectl logs -n falcon-kac -l app=falcon-kac

# Check Image Analyzer logs
kubectl logs -n falcon-image-analyzer -l app=falcon-image-analyzer

# Check webhook configuration
kubectl get validatingwebhookconfigurations falcon-kac -o yaml
```

## Cleanup

To remove the Falcon Platform deployment:

```bash
# Uninstall Helm release
helm uninstall falcon-platform -n falcon-platform

# Delete namespaces
kubectl delete namespace falcon-system falcon-kac falcon-image-analyzer falcon-platform

# Delete IAM service accounts (optional)
eksctl delete iamserviceaccount --name crowdstrike-falcon-sa --namespace falcon-system --cluster $CLUSTER_NAME --region $AWS_REGION
eksctl delete iamserviceaccount --name falcon-kac-sa --namespace falcon-kac --cluster $CLUSTER_NAME --region $AWS_REGION
```

## Security Considerations

1. **Secrets Management**: Store sensitive credentials securely
2. **IAM Policies**: Follow principle of least privilege
3. **Network Policies**: Consider implementing network policies for isolation
4. **Image Security**: Use specific image tags rather than "latest"

## Support

For issues specific to this deployment:
1. Check the troubleshooting section above
2. Review CrowdStrike Falcon documentation
3. Consult AWS EKS Fargate documentation