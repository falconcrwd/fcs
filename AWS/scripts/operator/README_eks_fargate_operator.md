# CrowdStrike Falcon Operator EKS Fargate Installation

This script automates the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS **Fargate** cluster.

## Overview

The `eks_fargate_operator_install.sh` script deploys the Falcon Operator and uses the `FalconDeploymentFargate.yaml` manifest to install the following security components via custom resources managed by the operator:

- **Falcon Container Sensor / Sidecar Injector** (`deployContainerSensor: true`) - Mutating webhook that injects the sensor as a sidecar into Fargate pods
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning
- **Falcon Node Sensor disabled** (`deployNodeSensor: false`) - Not used on Fargate (no node access)

### Optional: Falcon Container Sensor Auto-Update

A second manifest, `FalconDeploymentFargateAutoUpdate.yaml`, is provided for deployments that want the **Falcon Container Sensor (sidecar) to auto-upgrade** via a Falcon sensor update policy. It is identical to `FalconDeploymentFargate.yaml` but adds the following `advanced` block under `spec.falconContainerSensor`:

```yaml
advanced:
  autoUpdate: normal
  updatePolicy: linux-prod
```

With this configuration:
- `autoUpdate: normal` enables automatic sensor version updates for the injected sidecar
- `updatePolicy: linux-prod` binds the sensor to a named Falcon **Sensor update policy** in the Falcon console

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying this manifest, and it must be configured to target the sensor architecture in use (typically `amd64` for Fargate). If a mismatch exists between the policy's architecture and the running sensor, the sensor will not receive updates.

To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux** and ensure a policy called `linux-prod` exists with the correct host group membership / architecture.

#### Using the auto-update manifest

To deploy with auto-update, either:

- Rename / symlink `FalconDeploymentFargateAutoUpdate.yaml` to `FalconDeploymentFargate.yaml` before running `eks_fargate_operator_install.sh` (the script looks for `FalconDeploymentFargate.yaml` by default), or
- Edit `eks_fargate_operator_install.sh` and change the `DEPLOYMENT_MANIFEST` variable to point at `FalconDeploymentFargateAutoUpdate.yaml`

### Key Features

- Automatically downloads and pushes Falcon container images to AWS ECR
- Installs a pinned version of the Falcon Operator from the official GitHub release
- **Associates an IAM OIDC provider** with the EKS cluster (required for IRSA on Fargate)
- **Creates two IAM roles** (one for the falcon-injector ServiceAccount, one for the falcon-kac ServiceAccount), each with an OIDC trust policy scoped to the exact `system:serviceaccount:<ns>:<name>` that the operator will create
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentFargate.yaml` (account, region, ECR namespace, per-image tags, and the two IAM role names)
- Comprehensive logging and error handling

## What the Script Does

1. **Loads configuration** from `eks_fargate_operator_inputs.txt`
2. **Installs `eksctl`** automatically if it is not already present (with checksum verification)
3. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo
4. **Logs into AWS ECR** using the AWS CLI and Docker
5. **Retrieves image tags** for `falcon-container`, `falcon-kac`, and `falcon-imageanalyzer`
6. **Pulls and pushes** those images to your ECR namespace
7. **Updates kubeconfig** for the target EKS cluster
8. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`
9. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`
10. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent)
11. **Creates two IAM roles** with OIDC trust policies (one per Falcon SA), and attaches the ECR-pull policy to each:
    - `${FALCON_INJECTOR_ROLE_NAME}` -> trusted by `system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME}`
    - `${FALCON_ADMISSION_ROLE_NAME}` -> trusted by `system:serviceaccount:${FALCON_ADMISSION_NAMESPACE}:${FALCON_ADMISSION_SA_NAME}`
12. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is Available
13. **Creates** the `falcon-secret` namespace and the `falcon-secrets` Kubernetes secret with your Falcon API credentials
14. **Processes** `FalconDeploymentFargate.yaml` - substituting the account ID, region, ECR namespace, per-image tags, and the two IAM role names
15. **Applies** the processed `FalconDeployment` manifest. The operator then creates the deployments and the two ServiceAccounts (`crowdstrike-falcon-sa`, `falcon-kac-sa`) annotated with `eks.amazonaws.com/role-arn`, enabling IRSA-based ECR pulls
16. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments, component pods, and webhook configurations

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write)
- **Falcon Container Image** (Read/Write)

### EKS Cluster Requirements

- An existing **EKS Fargate cluster** (Fargate-only or mixed Fargate/EC2)
- **Fargate profiles** must exist that select the Falcon component namespaces. By default this script requires Fargate profile coverage for:
  - `falcon-operator`
  - `falcon-secret`
  - `falcon-system` (FalconContainerSensor injector)
  - `falcon-kac` (FalconAdmission)
  - `falcon-image-analyzer` (FalconImageAnalyzer)
- **Fargate profiles must also cover the workload namespaces** you want protected (so workload pods scheduled on Fargate can be intercepted and sidecar-injected by the mutating webhook)
- The cluster must have access to ECR. The script will associate an IAM OIDC provider for IRSA - if you prefer to do this manually first:
  ```bash
  eksctl utils associate-iam-oidc-provider \
    --region "<YOUR_AWS_REGION>" \
    --cluster "<YOUR_EKS_CLUSTER_NAME>" \
    --approve
  ```
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
   - `eks_fargate_operator_install.sh`
   - `FalconDeploymentFargate.yaml` (or `FalconDeploymentFargateAutoUpdate.yaml` if you want auto-update)
   - `eks_fargate_operator_inputs.txt`

3. **Configure Variables**: Edit `eks_fargate_operator_inputs.txt` with your environment-specific values.

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS cluster and ECR |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `AWS_ACCOUNT_ID` | AWS account ID hosting the ECR repos |
   | `IMAGE_REPO_NAMESPACE` | ECR repository namespace (prefix path before each image name) |
   | `CLUSTER_NAME` | Name of the target EKS Fargate cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |
   | `FALCON_INJECTOR_ROLE_NAME` | IAM role name to create/use for the falcon-injector SA. Default: `FalconContainerInjectorRole-${CLUSTER_NAME}` |
   | `FALCON_ADMISSION_ROLE_NAME` | IAM role name to create/use for the falcon-kac SA. Default: `FalconAdmissionRole-${CLUSTER_NAME}` |
   | `FALCON_INJECTOR_NAMESPACE` | Namespace where the operator deploys the FalconContainerSensor injector. Default: `falcon-system` |
   | `FALCON_INJECTOR_SA_NAME` | SA name the operator creates for the injector. Default: `crowdstrike-falcon-sa` |
   | `FALCON_ADMISSION_NAMESPACE` | Namespace where the operator deploys FalconAdmission (KAC). Default: `falcon-kac` |
   | `FALCON_ADMISSION_SA_NAME` | SA name the operator creates for KAC. Default: `falcon-kac-sa` |

   > **Important**: The `FALCON_INJECTOR_*` and `FALCON_ADMISSION_*` namespace/SA values must match the names the Falcon Operator will create. They are used to scope the OIDC trust policies. The defaults match the operator's defaults for `FalconContainerSensor` and `FalconAdmission`. If your configuration differs (e.g. you change `installNamespace` in the manifest), update these values accordingly.

4. **Review Customization** (Optional): Check the [Falcon Operator repo](https://github.com/crowdstrike/falcon-operator) for additional `FalconDeployment` configuration options.

### Step 2: Execute Installation

```bash
# Make the script executable (already done if extracted with executable bit)
chmod +x eks_fargate_operator_install.sh

# Run the installation
./eks_fargate_operator_install.sh
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
# Container sensor injector (in falcon-system by default)
kubectl get pods -n falcon-system

# Admission controller (KAC) (in falcon-kac by default)
kubectl get pods -n falcon-kac

# Image analyzer (in falcon-image-analyzer by default)
kubectl get pods -n falcon-image-analyzer
```

#### Check the IRSA service accounts
The operator creates the SAs with the IAM role-arn annotation:
```bash
kubectl get sa -n falcon-system crowdstrike-falcon-sa -o yaml | grep role-arn
kubectl get sa -n falcon-kac falcon-kac-sa -o yaml | grep role-arn
```

#### Check the webhook configurations
```bash
kubectl get mutatingwebhookconfigurations | grep falcon
kubectl get validatingwebhookconfigurations | grep falcon
```

#### Test sidecar injection on a Fargate pod
```bash
# Create a test pod in a Fargate-covered namespace
kubectl run test-pod --image=nginx --restart=Never

# Verify the falcon container sidecar is present
kubectl describe pod test-pod | grep -A2 falcon

# Check the Agent ID
kubectl exec -it test-pod -c crowdstrike-falcon-container -- falconctl -g --aid
```

### Step 4: Verify on Falcon Platform

Navigate to **Cloud Security > Assets > Kubernetes and container inventory** in the Falcon console. You should see the EKS Fargate cluster reporting with:
- A **KAC sensor ID** assigned
- **KAC agent status** and **Cluster status** showing **Active**
- **Management status** showing **Managed**

## File Structure

```
AWS/scripts/operator/
├── README_eks_node_operator.md                # EKS node-pools (EC2) deployment doc
├── README_eks_fargate_operator.md             # This documentation (EKS Fargate)
├── eks_node_operator_install.sh               # EKS node-pools install script
├── eks_fargate_operator_install.sh            # EKS Fargate install script
├── eks_node_operator_inputs.txt               # EKS node-pools config
├── eks_fargate_operator_inputs.txt            # EKS Fargate config
├── FalconDeploymentNode.yaml                  # Node deployment manifest
├── FalconDeploymentNodeAutoUpdate.yaml        # Node deployment manifest with auto-update
├── FalconDeploymentFargate.yaml               # Fargate deployment manifest (no auto-update)
└── FalconDeploymentFargateAutoUpdate.yaml     # Fargate deployment manifest with Container Sensor auto-update enabled
```

## Template Processing

The script uses `sed` to substitute the following placeholders in `FalconDeploymentFargate.yaml` (or `FalconDeploymentFargateAutoUpdate.yaml`):

| Placeholder | Replaced with |
|-------------|---------------|
| `<YOUR_AWS_ACCOUNT_ID>` | `AWS_ACCOUNT_ID` from inputs |
| `<AWS_REGIONS>` | `AWS_REGION` from inputs |
| `<YOUR_NAMESPACE>` | `IMAGE_REPO_NAMESPACE` from inputs |
| `<TAG>` (falcon-container line) | Latest `falcon-container` tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-kac line) | Latest `falcon-kac` tag pulled from CrowdStrike registry |
| `<TAG>` (falcon-imageanalyzer line) | Latest `falcon-imageanalyzer` tag pulled from CrowdStrike registry |
| `<FALCON_CONTAINER_INJECTOR_ROLE>` | `FALCON_INJECTOR_ROLE_NAME` from inputs |
| `<FALCON_ADMISSION_ROLE>` | `FALCON_ADMISSION_ROLE_NAME` from inputs |

The processed manifest is written to `/tmp/FalconDeploymentFargate_processed.yaml`, applied with `kubectl apply`, and then removed at the end of the script.

## IAM / IRSA Architecture

Fargate pods cannot use the underlying node's IAM credentials, so ECR pulls and any AWS API calls must use IRSA (IAM Roles for Service Accounts). The script provisions:

```
EKS OIDC Provider
       |
       |-- Trust ---> IAM Role: ${FALCON_INJECTOR_ROLE_NAME}
       |              (sub: system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME})
       |              |-- Attached: FalconContainerEcrPull
       |
       |-- Trust ---> IAM Role: ${FALCON_ADMISSION_ROLE_NAME}
                      (sub: system:serviceaccount:${FALCON_ADMISSION_NAMESPACE}:${FALCON_ADMISSION_SA_NAME})
                      |-- Attached: FalconContainerEcrPull
```

The Falcon Operator (when applied with the processed manifest) creates the two ServiceAccounts and annotates each with the matching `eks.amazonaws.com/role-arn`. From that point on, pods running under those SAs assume the IAM role via OIDC and pull images from ECR with the policy attached above.

## Updating Component Versions

After initial deployment, you can update sensor, KAC and IAR versions by editing the `FalconDeployment` resource:

```bash
kubectl get falcondeployments
kubectl edit falcondeployment falcon-deployment
```

Alternatively, re-run the script to pull the current latest images into ECR and re-apply the manifest.

If you opted into the auto-update manifest (`FalconDeploymentFargateAutoUpdate.yaml`) with `autoUpdate: normal` / `updatePolicy: linux-prod`, the **container sensor sidecar** version follows the Falcon `linux-prod` sensor update policy automatically. The KAC and IAR images still need to be refreshed by re-running this script.

## Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm ECR push, EKS describe, IAM (create policies/roles), and `kubectl` access
3. **Inspect Operator logs**:
   ```bash
   kubectl logs -n falcon-operator deploy/falcon-operator-controller-manager
   ```
4. **Inspect Component logs**: Use `kubectl logs` against pods in the component namespaces (`falcon-system`, `falcon-kac`, `falcon-image-analyzer`)
5. **Verify Secret**: Confirm the `falcon-secrets` secret exists in the `falcon-secret` namespace:
   ```bash
   kubectl get secret falcon-secrets -n falcon-secret
   ```
6. **IRSA / ECR pull failures**: If pods stay in `ImagePullBackOff`, check:
   - The SA actually has the `eks.amazonaws.com/role-arn` annotation
   - The OIDC trust policy `sub` matches `system:serviceaccount:<ns>:<sa-name>` exactly
   - The IAM role has `FalconContainerEcrPull` attached
   - The pod logs show the role being assumed (look for `AssumeRoleWithWebIdentity` events in CloudTrail)
7. **Fargate scheduling issues**: If pods are stuck in `Pending`, verify a Fargate profile selects the namespace
8. **Validate Configuration**: Ensure all variables in `eks_fargate_operator_inputs.txt` are correct
9. **Review manifest**: Inspect `/tmp/FalconDeploymentFargate_processed.yaml` during a run to confirm substitutions

## Cleanup

```bash
# Delete the FalconDeployment (operator will tear down components)
kubectl delete falcondeployment falcon-deployment

# Uninstall the Falcon Operator
kubectl delete -f "https://github.com/crowdstrike/falcon-operator/releases/download/${FALCON_OPERATOR_VERSION}/falcon-operator.yaml"

# Delete remaining namespaces if needed
kubectl delete namespace falcon-secret falcon-system falcon-kac falcon-image-analyzer

# Optional: delete the IAM roles and policy
aws iam detach-role-policy --role-name "${FALCON_INJECTOR_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam detach-role-policy --role-name "${FALCON_ADMISSION_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam delete-role --role-name "${FALCON_INJECTOR_ROLE_NAME}"
aws iam delete-role --role-name "${FALCON_ADMISSION_ROLE_NAME}"
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
```

## Additional Resources

- [Falcon Operator (GitHub)](https://github.com/crowdstrike/falcon-operator)
- [Falcon Operator FalconDeployment sample (Fargate sidecar)](https://github.com/CrowdStrike/falcon-operator/tree/main/config/samples)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)
- [AWS EKS Fargate documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Plan Your Deployment](https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0)
