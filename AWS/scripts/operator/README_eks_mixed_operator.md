# CrowdStrike Falcon Operator EKS Mixed (Node + Fargate) Installation

This script automates the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS cluster that runs **both EC2 node pools and Fargate** in the same cluster.

## Overview

The `eks_mixed_operator_install.sh` script deploys the Falcon Operator and uses the `FalconDeploymentMixedAutoUpdate.yaml` (default) or `FalconDeploymentMixed.yaml` manifest to install the following security components:

- **Falcon Node Sensor** (`deployNodeSensor: true`) - DaemonSet that runs on every EC2 node, providing endpoint protection for workloads scheduled on EC2
- **Falcon Container Sensor / Sidecar Injector** (`deployContainerSensor: true`) - Mutating webhook (deployed in the **`falcon-injector`** namespace) that injects the sensor as a sidecar into pods scheduled on **Fargate**
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement, deployed onto **EC2 nodes**
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning, deployed onto **EC2 nodes**

### Component placement

| Component | Where it runs | How it pulls from ECR |
|-----------|---------------|------------------------|
| FalconNodeSensor (DaemonSet) | EC2 nodes only (DaemonSets cannot land on Fargate) | Node IAM role |
| FalconContainerSensor injector | **Fargate** (namespace `falcon-injector`) | **IRSA** (one IAM role) |
| FalconAdmission (KAC) | EC2 nodes | Node IAM role |
| FalconImageAnalyzer (IAR) | EC2 nodes | Node IAM role |

This is enforced by which namespaces are covered by Fargate profiles:
- A Fargate profile **must** cover `falcon-injector` (and any workload namespaces you want sidecar-injected on Fargate)
- Fargate profiles **must NOT** cover `falcon-kac`, `falcon-image-analyzer`, or `falcon-system` so those pods schedule on EC2 nodes
- `falcon-operator` and `falcon-secret` do **not** need Fargate profile coverage in a mixed cluster: the operator's controller-manager Deployment will schedule onto EC2 nodes, and `falcon-secret` only holds a Kubernetes Secret object (no pods)

### Deployment manifest options

Two manifest variants are provided, switchable via the `DEPLOYMENT_MANIFEST_NAME` variable in `eks_mixed_operator_inputs.txt`:

- **`FalconDeploymentMixedAutoUpdate.yaml`** (default) - enables sensor auto-update for both the Node Sensor and the Container Sensor sidecar via a Falcon Sensor update policy:
  ```yaml
  advanced:
    autoUpdate: normal
    updatePolicy: linux-prod
  ```
  - `autoUpdate: normal` enables automatic sensor version updates
  - `updatePolicy: linux-prod` binds the sensor to a named Falcon **Sensor update policy** in the Falcon console
- **`FalconDeploymentMixed.yaml`** - same components, no auto-update; sensor versions are pinned to the image tags pulled at install time

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying the auto-update manifest, configured to target the architecture in use (`amd64` and/or `arm64`). To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux**.

#### Switching between manifests

Edit `eks_mixed_operator_inputs.txt` and set `DEPLOYMENT_MANIFEST_NAME`:

```bash
# Auto-update (default)
DEPLOYMENT_MANIFEST_NAME="FalconDeploymentMixedAutoUpdate.yaml"

# No auto-update
DEPLOYMENT_MANIFEST_NAME="FalconDeploymentMixed.yaml"
```

### Key Features

- Pulls and pushes all four Falcon container images (`falcon-sensor`, `falcon-container`, `falcon-kac`, `falcon-imageanalyzer`) to AWS ECR
- Installs a pinned version of the Falcon Operator from the official GitHub release
- Associates an IAM OIDC provider with the EKS cluster (required for IRSA on Fargate)
- Creates a single IAM role for the **falcon-injector** ServiceAccount (only the injector runs on Fargate; KAC and IAR rely on the node IAM role)
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Performs `sed`-based substitution of the placeholders in the chosen mixed manifest (account, region, ECR namespace, per-image tags, and the injector IAM role name)
- Comprehensive logging and error handling

## What the Script Does

1. **Loads configuration** from `eks_mixed_operator_inputs.txt` (including `DEPLOYMENT_MANIFEST_NAME`)
2. **Installs `eksctl`** automatically if it is not already present (with checksum verification)
3. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo
4. **Logs into AWS ECR** using the AWS CLI and Docker
5. **Retrieves image tags** for `falcon-sensor`, `falcon-container`, `falcon-kac`, and `falcon-imageanalyzer`
6. **Pulls and pushes** those four images to your ECR namespace
7. **Updates kubeconfig** for the target EKS cluster
8. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`
9. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`
10. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent)
11. **Creates one IAM role** with an OIDC trust policy bound to `system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME}` and attaches the ECR-pull policy
12. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is Available
13. **Creates** the `falcon-secret` namespace and the `falcon-secrets` Kubernetes secret with your Falcon API credentials
14. **Processes** the chosen mixed manifest - substituting account ID, region, ECR namespace, per-image tags, and the injector IAM role name
15. **Applies** the processed `FalconDeployment` manifest. The operator then creates the components, including the `crowdstrike-falcon-sa` ServiceAccount in `falcon-injector` annotated with `eks.amazonaws.com/role-arn`
16. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments, component pods, and webhook configurations

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write)
- **Falcon Container Image** (Read/Write)
- **Sensor update policies** (Read) - required for the auto-update manifest variant

### EKS Cluster Requirements

- An existing **EKS cluster with both EC2 node pools and Fargate profiles**
- **Fargate profile coverage required for**:
  - `falcon-injector` (FalconContainerSensor injector)
  - Any **workload namespaces** scheduled on Fargate that you want sidecar-injected
- **Fargate profile coverage NOT required for** (these pods schedule onto EC2 in a mixed cluster):
  - `falcon-operator` (operator controller-manager Deployment)
  - `falcon-secret` (contains only a Secret resource; no pods)
- **Fargate profile coverage MUST NOT include**:
  - `falcon-kac` (KAC must run on EC2)
  - `falcon-image-analyzer` (IAR must run on EC2)
  - `falcon-system` (not used in this topology)
- The EKS cluster must have an **IAM OIDC provider** associated with it. The script associates one automatically (and installs `eksctl` first if needed). To do it manually:
  ```bash
  eksctl utils associate-iam-oidc-provider \
    --region "<YOUR_AWS_REGION>" \
    --cluster "<YOUR_EKS_CLUSTER_NAME>" \
    --approve
  ```
- EC2 node IAM role must have ECR pull permissions (so KAC and IAR can pull from your ECR repos)
- The Falcon components need outbound Internet access to send telemetry to the CrowdStrike cloud

### System Requirements

- AWS CLI configured with permissions for ECR (push), EKS (describe/update), and IAM (create policies/roles, attach role policies, manage OIDC providers)
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
<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<IMAGE_REPO_NAMESPACE>/falcon-container
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
   - `eks_mixed_operator_install.sh`
   - `FalconDeploymentMixedAutoUpdate.yaml` (auto-update; default)
   - `FalconDeploymentMixed.yaml` (no auto-update; alternative)
   - `eks_mixed_operator_inputs.txt`

3. **Configure Variables**: Edit `eks_mixed_operator_inputs.txt` with your environment-specific values.

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS cluster and ECR |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `AWS_ACCOUNT_ID` | AWS account ID hosting the ECR repos |
   | `IMAGE_REPO_NAMESPACE` | ECR repository namespace (prefix path before each image name) |
   | `CLUSTER_NAME` | Name of the target mixed EKS cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |
   | `DEPLOYMENT_MANIFEST_NAME` | `FalconDeploymentMixedAutoUpdate.yaml` (default) or `FalconDeploymentMixed.yaml` |
   | `FALCON_INJECTOR_ROLE_NAME` | IAM role name to create/use for the falcon-injector SA. Default: `FalconContainerInjectorRole-${CLUSTER_NAME}` |
   | `FALCON_INJECTOR_NAMESPACE` | Namespace where the Container Sensor injector is deployed. Default: `falcon-injector` |
   | `FALCON_INJECTOR_SA_NAME` | SA name the operator creates for the injector. Default: `crowdstrike-falcon-sa` |

   > **Important**: The `FALCON_INJECTOR_NAMESPACE` must match the `spec.falconContainerSensor.installNamespace` in the manifest (`falcon-injector`). The `FALCON_INJECTOR_SA_NAME` must match the SA the operator creates. These are used to scope the OIDC trust policy.

4. **Review Customization** (Optional): Check the [Falcon Operator repo](https://github.com/crowdstrike/falcon-operator) for additional `FalconDeployment` configuration options, including node selectors, resource limits and tolerations.

### Step 2: Execute Installation

```bash
chmod +x eks_mixed_operator_install.sh
./eks_mixed_operator_install.sh
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
# Node Sensor DaemonSet (one pod per EC2 node)
kubectl get daemonsets -A | grep falcon
kubectl get pods -A -l crowdstrike.com/component=kernel_sensor

# Container Sensor injector (Fargate)
kubectl get pods -n falcon-injector -o wide

# KAC (EC2)
kubectl get pods -n falcon-kac -o wide

# IAR (EC2)
kubectl get pods -n falcon-image-analyzer -o wide
```

The `-o wide` output shows the node each pod is running on. Confirm:
- `falcon-injector` pods report a node like `fargate-ip-...`
- `falcon-kac` and `falcon-image-analyzer` pods report regular EC2 node names

#### Check the IRSA service account for the injector
```bash
kubectl get sa -n falcon-injector crowdstrike-falcon-sa -o yaml | grep role-arn
```

#### Check the webhook configurations
```bash
kubectl get mutatingwebhookconfigurations | grep falcon
kubectl get validatingwebhookconfigurations | grep falcon
```

#### Test sidecar injection on a Fargate pod

```bash
# Create a test namespace covered by a Fargate profile
kubectl create namespace fargate-test

# Run a pod into that namespace (assumes the Fargate profile selects it)
kubectl run test-pod --image=nginx --restart=Never -n fargate-test

# Verify the falcon container sidecar is present
kubectl describe pod test-pod -n fargate-test | grep -A2 falcon

# Check the Agent ID
kubectl exec -it test-pod -n fargate-test -c crowdstrike-falcon-container -- falconctl -g --aid
```

#### Test Node Sensor coverage on EC2

```bash
# Run a pod into a node-pool-only namespace (no Fargate profile)
kubectl run node-test --image=nginx --restart=Never

# Confirm it scheduled on EC2 (no fargate-ip prefix on NODE)
kubectl get pod node-test -o wide

# The DaemonSet sensor on that node provides protection - no sidecar injected
kubectl describe pod node-test | grep -A2 falcon  # should be empty
```

### Step 4: Verify on Falcon Platform

Navigate to **Cloud Security > Assets > Kubernetes and container inventory** in the Falcon console. You should see the EKS cluster reporting with:
- A **KAC sensor ID** assigned
- **KAC agent status** and **Cluster status** showing **Active**
- **Management status** showing **Managed**
- Both **kernel sensors** (Node Sensor on EC2) and **container sensors** (sidecar on Fargate) reporting hosts

## File Structure

```
AWS/scripts/operator/
├── README_eks_node_operator.md             # EKS node-pools (EC2) deployment doc
├── README_eks_fargate_operator.md          # EKS Fargate-only deployment doc
├── README_eks_mixed_operator.md            # This documentation (EKS mixed)
├── eks_node_operator_install.sh            # EKS node-pools install script
├── eks_fargate_operator_install.sh         # EKS Fargate install script
├── eks_mixed_operator_install.sh           # EKS mixed install script
├── eks_node_operator_inputs.txt            # EKS node-pools config
├── eks_fargate_operator_inputs.txt         # EKS Fargate config
├── eks_mixed_operator_inputs.txt           # EKS mixed config
├── FalconDeploymentNode.yaml               # Node deployment manifest
├── FalconDeploymentNodeAutoUpdate.yaml     # Node deployment manifest with auto-update
├── FalconDeploymentFargate.yaml            # Fargate deployment manifest (no auto-update)
├── FalconDeploymentFargateAutoUpdate.yaml  # Fargate deployment manifest with auto-update
├── FalconDeploymentMixed.yaml              # Mixed deployment manifest (no auto-update)
└── FalconDeploymentMixedAutoUpdate.yaml    # Mixed deployment manifest with auto-update
```

## Template Processing

The script uses `sed` to substitute the following placeholders in the chosen mixed manifest:

| Placeholder | Replaced with |
|-------------|---------------|
| `<YOUR_AWS_ACCOUNT_ID>` | `AWS_ACCOUNT_ID` from inputs |
| `<AWS_REGIONS>` | `AWS_REGION` from inputs |
| `<YOUR_NAMESPACE>` | `IMAGE_REPO_NAMESPACE` from inputs |
| `<TAG>` (falcon-sensor line) | Latest `falcon-sensor` tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-container line) | Latest `falcon-container` tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-kac line) | Latest `falcon-kac` tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-imageanalyzer line) | Latest `falcon-imageanalyzer` tag pulled from CrowdStrike registry |
| `<FALCON_CONTAINER_INJECTOR_ROLE>` | `FALCON_INJECTOR_ROLE_NAME` from inputs |

The processed manifest is written to `/tmp/<manifest-name>_processed.yaml`, applied with `kubectl apply`, and then removed at the end of the script.

## IAM / IRSA Architecture (Mixed Cluster)

Only the Falcon Container Sensor injector runs on Fargate, so only one IAM role is provisioned for IRSA. KAC and IAR run on EC2 nodes and use the node IAM role for ECR access.

```
EKS OIDC Provider
       |
       |-- Trust ---> IAM Role: ${FALCON_INJECTOR_ROLE_NAME}
                      (sub: system:serviceaccount:falcon-injector:crowdstrike-falcon-sa)
                      |-- Attached: FalconContainerEcrPull

EC2 Node IAM Role (existing)
       |-- Used by: FalconNodeSensor DaemonSet, FalconAdmission (KAC),
                    FalconImageAnalyzer (IAR), Falcon Operator controller
       |-- Required permissions: ecr:BatchGetImage, ecr:GetDownloadUrlForLayer,
                                 ecr:GetAuthorizationToken, ecr:DescribeImages,
                                 ecr:ListImages
```

The Falcon Operator (when applied with the processed manifest) creates the `crowdstrike-falcon-sa` ServiceAccount in `falcon-injector` and annotates it with `eks.amazonaws.com/role-arn`. From that point on, the injector pod assumes the IAM role via OIDC and pulls its image from ECR with the policy attached above.

## Updating Component Versions

After initial deployment, you can update sensor, KAC and IAR versions by editing the `FalconDeployment` resource:

```bash
kubectl get falcondeployments
kubectl edit falcondeployment falcon-deployment
```

Alternatively, re-run the script to pull the current latest images into ECR and re-apply the manifest.

If you opted into the auto-update manifest (`FalconDeploymentMixedAutoUpdate.yaml`) with `autoUpdate: normal` / `updatePolicy: linux-prod`:
- The **Node Sensor** DaemonSet version follows the Falcon `linux-prod` sensor update policy automatically
- The **Container Sensor sidecar** version follows the same policy automatically
- KAC and IAR images still need to be refreshed by re-running this script

## Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm ECR push, EKS describe, IAM (create policies/roles), and `kubectl` access
3. **Inspect Operator logs**:
   ```bash
   kubectl logs -n falcon-operator deploy/falcon-operator-controller-manager
   ```
4. **Inspect Component logs**: Use `kubectl logs` against pods in the component namespaces (`falcon-injector`, `falcon-kac`, `falcon-image-analyzer`, and the DaemonSet pods on each EC2 node)
5. **Verify Secret**: Confirm the `falcon-secrets` secret exists in the `falcon-secret` namespace:
   ```bash
   kubectl get secret falcon-secrets -n falcon-secret
   ```
6. **IRSA / ECR pull failures (injector on Fargate)**: If `falcon-injector` pods stay in `ImagePullBackOff`, check:
   - The SA actually has the `eks.amazonaws.com/role-arn` annotation
   - The OIDC trust policy `sub` is `system:serviceaccount:falcon-injector:crowdstrike-falcon-sa`
   - The IAM role has `FalconContainerEcrPull` attached
   - CloudTrail shows `AssumeRoleWithWebIdentity` events
7. **ECR pull failures (KAC / IAR on EC2)**: KAC/IAR pods should pull via the node IAM role. If they fail, verify the EC2 node IAM role has ECR pull permissions on your ECR repos
8. **Pod scheduling issues**:
   - `falcon-injector` stuck in `Pending` -> verify a Fargate profile selects the `falcon-injector` namespace
   - `falcon-kac` / `falcon-image-analyzer` ending up on Fargate -> remove those namespaces from any Fargate profile selectors so they fall back to EC2
   - Node Sensor DaemonSet pods missing on a node -> check tolerations and the EC2 node's taints
9. **Sidecar not injected on Fargate workloads**:
   - Verify the workload namespace is covered by a Fargate profile
   - Verify the `MutatingWebhookConfiguration` is present and targets the namespace
   - The injector pod must be Running before the workload pod is created
10. **Validate Configuration**: Ensure all variables in `eks_mixed_operator_inputs.txt` are correct
11. **Review manifest**: Inspect `/tmp/FalconDeploymentMixed*_processed.yaml` during a run to confirm substitutions

## Cleanup

```bash
# Delete the FalconDeployment (operator will tear down components)
kubectl delete falcondeployment falcon-deployment

# Uninstall the Falcon Operator
kubectl delete -f "https://github.com/crowdstrike/falcon-operator/releases/download/${FALCON_OPERATOR_VERSION}/falcon-operator.yaml"

# Delete remaining namespaces if needed
kubectl delete namespace falcon-secret falcon-injector falcon-kac falcon-image-analyzer

# Optional: delete the IAM role and policy
aws iam detach-role-policy --role-name "${FALCON_INJECTOR_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam delete-role --role-name "${FALCON_INJECTOR_ROLE_NAME}"
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
```

## Additional Resources

- [Falcon Operator (GitHub)](https://github.com/crowdstrike/falcon-operator)
- [Falcon Operator FalconDeployment samples](https://github.com/CrowdStrike/falcon-operator/tree/main/config/samples)
- [Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)
- [AWS EKS Fargate documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Plan Your Deployment](https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0)
