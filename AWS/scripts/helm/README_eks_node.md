# CrowdStrike Falcon EKS Node Installation

This script automates the deployment of CrowdStrike Falcon Platform components on AWS EKS clusters using Helm charts.

## 📋 Overview

The `eks_node_helm_install.sh` script uses the [CrowdStrike Falcon Platform Helm chart](https://github.com/CrowdStrike/falcon-helm/tree/main/helm-charts/falcon-platform) to install three security components on an existing AWS EKS cluster:

- **Falcon Sensor** - Deployed as a DaemonSet for endpoint protection
- **Kubernetes Admission Controller (KAC)** - Runtime security enforcement
- **Image Assessment at Runtime (IAR)** - Container image vulnerability scanning in watcher mode

### Key Features

- ✅ Configures DaemonSet sensor to tolerate taints on system node pools
- ✅ Automatically downloads and pushes container images to AWS ECR
- ✅ Uses environment variable substitution for flexible configuration
- ✅ Creates necessary Kubernetes namespaces and secrets
- ✅ Comprehensive logging and error handling

## 🛠 What the Script Does

1. **Installs Helm**: Automatically installs Helm if not already present on the system
2. **Downloads Images**: Retrieves the latest Falcon container images from CrowdStrike registry
3. **Pushes to ECR**: Uploads images to your AWS ECR repositories
4. **Configures Environment**: Sets up all necessary environment variables
5. **Deploys Components**: Installs the Falcon Platform using processed Helm values
6. **Verifies Installation**: Checks pod status across all relevant namespaces

## ⚙️ Prerequisites

### Required API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write)
- **Falcon Container Image** (Read/Write)

### System Requirements

- Access to CrowdStrike Falcon and AWS portals
- AWS CLI configured with appropriate permissions
- Linux/Unix environment with the following tools installed:
  - `bash`
  - `curl`
  - `aws-cli`
  - `sed`
  - `docker`
  - `kubectl`

> **💡 Tip**: You can use AWS CloudShell where most tools are pre-installed. The installation script will automatically install **Helm** if it's not already present on your system.

### Installation Commands

#### AWS CLI
```bash
# Follow the official guide
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
```

#### Docker
```bash
# Follow the official guide for your OS
# https://docs.docker.com/engine/install/
```

> **Note**: Helm will be automatically installed by the deployment script if not already present.

### AWS ECR Repositories

Create the following ECR repositories in your AWS account:

```
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-sensor
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-kac
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-imageanalyzer
```

## 🚀 Installation Steps

### Step 1: Prepare Environment

1. **Configure AWS CLI**: Log into the AWS account containing your EKS cluster
   ```bash
   aws configure
   # or use AWS profiles
   aws configure --profile your-profile-name
   ```

2. **Prepare Files**: Ensure all required files are in the same directory:
   - `eks_node_helm_install.sh`
   - `eks_node_helm.yaml`
   - `eks_node_helm_inputs.txt`

3. **Configure Variables**: Edit `eks_node_helm_inputs.txt` with your environment-specific values. For **FALCON_SECRET_NAME** you can choose any desired name

4. **Review Customization** (Optional): Check the [Falcon Platform Helm chart](https://github.com/CrowdStrike/falcon-helm/tree/main/helm-charts/falcon-platform) for additional configuration options

### Step 2: Execute Installation

```bash
# Make the script executable
chmod +x eks_node_helm_install.sh

# Run the installation
./eks_node_helm_install.sh
```

### Step 3: Verify Deployment

#### Check Helm Release Status
```bash
helm list -n falcon-platform
```

#### Verify Pod Status
```bash
# Check all Falcon Platform pods
kubectl get pods -l app.kubernetes.io/instance=falcon-platform -A

# Check individual namespaces
kubectl get pods -n falcon-system
kubectl get pods -n falcon-kac
kubectl get pods -n falcon-image-analyzer
```

#### Check DaemonSet Status
```bash
kubectl get daemonsets -n falcon-system
```

## 📁 File Structure

```
AWS/scripts/helm/
├── README.md                    # This documentation
├── eks_node_helm_install.sh     # Main installation script
├── eks_node_helm.yaml          # Helm values template
└── eks_node_helm_inputs.txt    # Configuration variables
```

## 🔧 Configuration

### Environment Variables

The script uses the following key environment variables (automatically set):

| Variable | Description |
|----------|-------------|
| `FALCON_CID` | Customer ID (retrieved via API) |
| `SENSOR_REGISTRY` | ECR path for Falcon Sensor |
| `KAC_REGISTRY` | ECR path for Kubernetes Admission Controller |
| `IAR_REGISTRY` | ECR path for Image Assessment Runtime |
| `ENCODED_DOCKER_CONFIG` | Base64 encoded Docker configuration |

### Template Processing

The script uses `sed` to substitute environment variables in `eks_node_helm.yaml`, creating a processed values file for Helm deployment. This approach ensures compatibility across different environments without requiring additional packages.

## 📚 Additional Resources

- [CrowdStrike Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)

## 🐛 Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm ECR and EKS access permissions
3. **Review Logs**: The script provides detailed logging for each step
4. **Check Pod Status**: Use kubectl to investigate pod startup issues
5. **Validate Configuration**: Ensure all variables in `eks_node_helm_inputs.txt` are correct





