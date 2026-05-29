# CrowdStrike Falcon Operator EKS Node Installation

These scripts automate the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS cluster with node pools (EC2 worker nodes).

## Overview

Both the `eks_node_operator_install.sh` and `eks_node_operator_install_exist_image.sh` scripts deploy the Falcon Operator and use the `FalconDeploymentNode.yaml` manifest to install the following security components via custom resources managed by the operator:

- **Falcon Node Sensor** (`deployNodeSensor: true`) - DaemonSet providing endpoint protection on every EKS node
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning
- **Container Sensor disabled** (`deployContainerSensor: false`) - Not needed on EC2 node pools since Node Sensor covers workloads

### Choosing an installation script

Two installation scripts are provided. Pick the one that matches the state of your AWS ECR:

| Script | When to use | Inputs file |
|--------|-------------|-------------|
| `eks_node_operator_install.sh` | The Falcon Sensor, KAC and IAR images are **not** yet in ECR. The script pulls them from the CrowdStrike registry and pushes them to your ECR. | `eks_node_operator_inputs.txt` |
| `eks_node_operator_install_exist_image.sh` | The Falcon Sensor, KAC and IAR images **already exist** in your ECR (for example, mirrored by a separate process or previous run). The script skips the CrowdStrike pull / ECR push and references the existing images directly. | `eks_node_operator_inputs_exist_image.txt` |

The "exist image" variant additionally validates that each referenced image+tag is actually present in ECR (via `aws ecr describe-images`) before proceeding, and uses the user-supplied image names and tags when substituting into the `FalconDeploymentNode.yaml` manifest.

### Optional: Falcon Node Sensor Auto-Update

A second manifest, `FalconDeploymentNodeAutoUpdate.yaml`, is provided for deployments that want the **Falcon Node Sensor to auto-upgrade** via a Falcon sensor update policy. It is identical to `FalconDeploymentNode.yaml` but adds the following `advanced` block under `spec.falconNodeSensor.node`:

```yaml
advanced:
  autoUpdate: normal
  updatePolicy: linux-prod
```

With this configuration:
- `autoUpdate: normal` enables automatic sensor version updates for the Node Sensor DaemonSet
- `updatePolicy: linux-prod` binds the sensor to a named Falcon **Sensor update policy** in the Falcon console

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying this manifest, and it must be configured to target the node architecture in use on the EKS worker nodes (either `amd64` or `arm64`). If a mismatch exists between the policy's architecture and the nodes, the sensor will not receive updates.

To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux** and ensure a policy called `linux-prod` exists with the correct host group membership / architecture.

#### Using the auto-update manifest

To deploy with auto-update, either:

- Rename / symlink `FalconDeploymentNodeAutoUpdate.yaml` to `FalconDeploymentNode.yaml` before running `eks_node_operator_install.sh` (the script looks for `FalconDeploymentNode.yaml` by default), or
- Edit `eks_node_operator_install.sh` and change the `DEPLOYMENT_MANIFEST` variable to point at `FalconDeploymentNodeAutoUpdate.yaml`

### Key Features

- Automatically downloads and pushes Falcon container images to AWS ECR
- Installs a pinned version of the Falcon Operator from the official GitHub release
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentNode.yaml` (`<YOUR_AWS_ACCOUNT_ID>`, `<AWS_REGIONS>`, `<YOUR_NAMESPACE>`, `<TAG>`)
- Comprehensive logging and error handling

## What the Script Does

1. **Loads configuration** from `eks_node_operator_inputs.txt` (or `eks_node_operator_inputs_exist_image.txt` for the existing-image variant)
2. **Installs `eksctl`** automatically if it is not already present on the host (with checksum verification). `eksctl` is then used later in step 8 to **configure an IAM OIDC provider** for the EKS cluster if one is not already associated.
3. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo *(only if `eks_node_operator_install.sh` is used)*
4. **Logs into AWS ECR** using the AWS CLI and Docker *(only if `eks_node_operator_install.sh` is used)*
5. **Retrieves image tags** for `falcon-sensor`, `falcon-kac`, and `falcon-imageanalyzer` *(only if `eks_node_operator_install.sh` is used)*
6. **Pulls and pushes** those images to your ECR namespace *(only if `eks_node_operator_install.sh` is used)*

   *When `eks_node_operator_install_exist_image.sh` is used instead, steps 3-6 are replaced by an `aws ecr describe-images` verification confirming each user-supplied image+tag is already present in ECR.*
7. **Updates kubeconfig** for the target EKS cluster
8. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`
9. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is Available
10. **Creates** the `falcon-secret` namespace and the `falcon-secrets` kubernetes secret with your Falcon API credentials
11. **Processes** `FalconDeploymentNode.yaml` - substituting the account ID, region, namespace and each image tag
12. **Applies** the processed `FalconDeployment` manifest
13. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments and component pods

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write)
- **Falcon Container Image** (Read/Write)
- **Sensor Update Policies** (Read) - required only if using `FalconDeploymentNodeAutoUpdate.yaml` (advanced `autoUpdate` enabled), so the Node Sensor can resolve the `linux-prod` update policy

### EKS Cluster Requirements

- An existing **EKS cluster with EC2 node pools** (not Fargate-only)
- Node pools must have access to ECR (or the private registry holding the Falcon images)
- The EKS cluster must have an **IAM OIDC provider** associated with it. The script will automatically associate one using `eksctl utils associate-iam-oidc-provider --approve` (and will install `eksctl` first if it is not present). If you prefer to do this manually beforehand, run:
  ```bash
  eksctl utils associate-iam-oidc-provider \
    --region "<YOUR_AWS_REGION>" \
    --cluster "<YOUR_EKS_CLUSTER_NAME>" \
    --approve
  ```
- The Falcon components need outbound Internet access to send telemetry to the CrowdStrike cloud

### System Requirements

- AWS CLI configured with appropriate permissions (ECR push, EKS describe/update)
- Linux/Unix environment with the following tools installed:
  - `bash`
  - `curl`
  - `aws-cli`
  - `sed`
  - `docker`
  - `kubectl`
  - `eksctl` (auto-installed by the script if missing)

> Tip: You can use AWS CloudShell where most tools are pre-installed.

### AWS ECR Repositories

Create the following ECR repositories in your AWS account ahead of time:

```
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-sensor
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-kac
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-imageanalyzer
```

## Installation Steps

### Step 1: Prepare Environment

1. **Configure AWS CLI**: Log into the AWS account containing your EKS cluster
   ```bash
   aws configure
   # or use AWS profiles
   aws configure --profile your-profile-name
   ```

2. **Prepare Files**: Ensure all required files are in the same directory:
   - `eks_node_operator_install.sh` **or** `eks_node_operator_install_exist_image.sh`
   - `FalconDeploymentNode.yaml`
   - `eks_node_operator_inputs.txt` **or** `eks_node_operator_inputs_exist_image.txt`

3. **Configure Variables**: Edit the appropriate inputs file for the script you are running.

   **`eks_node_operator_inputs.txt`** (used by `eks_node_operator_install.sh`):

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS cluster and ECR |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `AWS_ACCOUNT_ID` | AWS account ID hosting the ECR repos |
   | `IMAGE_REPO_NAMESPACE` | ECR repository namespace (prefix path before each image name) |
   | `CLUSTER_NAME` | Name of the target EKS cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |

   **`eks_node_operator_inputs_exist_image.txt`** (used by `eks_node_operator_install_exist_image.sh`) - same as above, plus the existing image names and tags already in ECR:

   | Variable | Description |
   |----------|-------------|
   | `SENSOR_IMAGE_NAME` | ECR repo name for the Falcon Node Sensor (e.g. `falcon-sensor`) |
   | `SENSOR_IMAGE_TAG` | Existing tag of the Falcon Node Sensor image in ECR |
   | `KAC_IMAGE_NAME` | ECR repo name for the Falcon KAC (e.g. `falcon-kac`) |
   | `KAC_IMAGE_TAG` | Existing tag of the Falcon KAC image in ECR |
   | `IAR_IMAGE_NAME` | ECR repo name for the Falcon Image Analyzer (e.g. `falcon-imageanalyzer`) |
   | `IAR_IMAGE_TAG` | Existing tag of the Falcon Image Analyzer image in ECR |

4. **Review Customization** (Optional): Check the [Falcon Operator repo](https://github.com/crowdstrike/falcon-operator) for additional `FalconDeployment` configuration options, including node selectors, resource limits and tolerations.

### Step 2: Execute Installation

If pulling and pushing images from the CrowdStrike registry to ECR:

```bash
# Make the script executable (already done by the install script if you followed the setup)
chmod +x eks_node_operator_install.sh

# Run the installation
./eks_node_operator_install.sh
```

If the Sensor, KAC and IAR images already exist in your ECR:

```bash
# Make the script executable
chmod +x eks_node_operator_install_exist_image.sh

# Run the installation (uses eks_node_operator_inputs_exist_image.txt)
./eks_node_operator_install_exist_image.sh
```

### Step 3: Verify Deployment

#### Check the FalconDeployment custom resource
```bash
kubectl get falcondeployments
kubectl describe falcondeployment falcon-deployment
```

#### Check the Falcon Operator
```bash
kubectl get deployments -n falcon-operator
kubectl get pods -n falcon-operator
```

#### Check the Falcon components
```bash
kubectl get pods -n falcon-operator | grep falconadmission
kubectl get pods -n falcon-operator | grep falconnodesensor
kubectl get pods -n falcon-operator | grep falconimageanalyzer
```

#### Check the Falcon Node Sensor DaemonSet
```bash
kubectl get daemonsets -A | grep falcon
```

### Step 4: Verify on Falcon Platform

Navigate to **Cloud Security > Assets > Kubernetes and container inventory** in the Falcon console. You should see the EKS cluster reporting with:
- A **KAC sensor ID** assigned
- **KAC agent status** and **Cluster status** showing **Active**
- **Management status** showing **Managed**

## File Structure

```
AWS/scripts/operator/
├── README_eks_node_operator.md                  # This documentation
├── eks_node_operator_install.sh                 # Installation script (pulls images from CrowdStrike, pushes to ECR)
├── eks_node_operator_install_exist_image.sh     # Installation script for images already present in ECR
├── FalconDeploymentNode.yaml                    # FalconDeployment manifest template (no auto-update)
├── FalconDeploymentNodeAutoUpdate.yaml          # FalconDeployment manifest with Node Sensor auto-update enabled
├── eks_node_operator_inputs.txt                 # Configuration variables for eks_node_operator_install.sh
├── eks_node_operator_inputs_exist_image.txt     # Configuration variables for eks_node_operator_install_exist_image.sh
└── operator.md                                  # Step-by-step manual operator reference
```

## Template Processing

The script uses `sed` to substitute the following placeholders in `FalconDeploymentNode.yaml`:

| Placeholder | Replaced with |
|-------------|---------------|
| `<YOUR_AWS_ACCOUNT_ID>` | `AWS_ACCOUNT_ID` from inputs |
| `<AWS_REGIONS>` | `AWS_REGION` from inputs |
| `<YOUR_NAMESPACE>` | `IMAGE_REPO_NAMESPACE` from inputs |
| `<TAG>` (falcon-sensor line) | Latest falcon-sensor tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-kac line) | Latest falcon-kac tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-imageanalyzer line) | Latest falcon-imageanalyzer tag pulled from CrowdStrike registry |

The processed manifest is written to `/tmp/FalconDeploymentNode_processed.yaml`, applied with `kubectl apply`, and then removed at the end of the script.

## Updating Component Versions

After initial deployment, you can update sensor, KAC and IAR versions by editing the `FalconDeployment` resource:

```bash
kubectl get falcondeployments
kubectl edit falcondeployment falcon-deployment
```

Alternatively, re-run the script to pull the current latest images into ECR and re-apply the manifest.

## Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm ECR push, EKS describe, and `kubectl` access
3. **Inspect Operator logs**:
   ```bash
   kubectl logs -n falcon-operator deploy/falcon-operator-controller-manager
   ```
4. **Inspect Component logs**: Use `kubectl logs` against pods in the `falcon-operator` namespace
5. **Verify Secret**: Confirm the `falcon-secrets` secret exists in the `falcon-secret` namespace:
   ```bash
   kubectl get secret falcon-secrets -n falcon-secret
   ```
6. **Validate Configuration**: Ensure all variables in `eks_node_operator_inputs.txt` are correct
7. **Review manifest**: Inspect `/tmp/FalconDeploymentNode_processed.yaml` during a run to confirm substitutions

## Additional Resources

- [Falcon Operator (GitHub)](https://github.com/crowdstrike/falcon-operator)
- [Falcon Operator node sensor sample manifest](https://github.com/CrowdStrike/falcon-operator/blob/main/config/samples/falcon_v1alpha1_falcondeployment-node-sensor.yaml)
- [Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)
- [Plan Your Deployment](https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0)
