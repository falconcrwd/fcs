# CrowdStrike Falcon Operator EKS Fargate Installation

These scripts automate the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS **Fargate** cluster.

## Overview

The `eks_fargate_operator_install.sh`, `eks_fargate_operator_install_exist_image.sh` and `eks_fargate_operator_install_autoupdate.sh` scripts deploy the Falcon Operator and a `FalconDeployment` manifest to install the following security components via custom resources managed by the operator:

- **Falcon Container Sensor / Sidecar Injector** (`deployContainerSensor: true`) - Mutating webhook that injects the sensor as a sidecar into Fargate pods
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning
- **Falcon Node Sensor disabled** (`deployNodeSensor: false`) - Not used on Fargate (no node access)

### Choosing an installation script

Three installation scripts are provided. Pick the one that matches your registry strategy and update strategy:

| Script | When to use | Inputs file | Manifest |
|--------|-------------|-------------|----------|
| `eks_fargate_operator_install.sh` | Falcon Container, KAC and IAR images are mirrored from `registry.crowdstrike.com` to your ECR. Fargate pods pull from ECR via IRSA. | `eks_fargate_operator_inputs.txt` | `FalconDeploymentFargate.yaml` |
| `eks_fargate_operator_install_exist_image.sh` | Falcon Container, KAC and IAR images **already exist** in your ECR (for example, mirrored by a separate process or previous run). The script skips the CrowdStrike pull / ECR push and references the existing images directly. Fargate pods pull from ECR via IRSA. | `eks_fargate_operator_inputs_exist_image.txt` | `FalconDeploymentFargate.yaml` |
| `eks_fargate_operator_install_autoupdate.sh` | You want the **Falcon Container Sensor (sidecar) to auto-upgrade** via a Falcon sensor update policy. Fargate pods pull images **directly from `registry.crowdstrike.com`** using a `dockerconfigjson` pull secret managed by the Falcon Operator. **No ECR mirroring is performed** and **no IRSA roles are required**. | `eks_fargate_operator_inputs_autoupdate.txt` | `FalconDeploymentFargateAutoUpdate.yaml` |

The "exist image" variant additionally validates that each referenced image+tag is actually present in ECR (via `aws ecr describe-images`) before proceeding, and uses the user-supplied image names and tags when substituting into the `FalconDeploymentFargate.yaml` manifest.

### Falcon Container Sensor Auto-Update

`eks_fargate_operator_install_autoupdate.sh` together with `eks_fargate_operator_inputs_autoupdate.txt` and `FalconDeploymentFargateAutoUpdate.yaml` enables sidecar auto-update. The manifest declares the following under `spec.falconContainerSensor`:

```yaml
advanced:
  autoUpdate: normal
  updatePolicy: linux-prod
```

It also declares a top-level `spec.falcon_api` block and **leaves all component image fields unpinned** so the operator can resolve and update them automatically:

```yaml
spec:
  falcon_api:
    cloud_region: autodiscover
  falconSecret:
    enabled: true
    namespace: falcon-secret
    secretName: falcon-secrets
  deployContainerSensor: true
  deployAdmissionController: true
  deployImageAnalyzer: true
  deployNodeSensor: false
  falconContainerSensor:
    installNamespace: falcon-system
    advanced:
      autoUpdate: normal
      updatePolicy: linux-prod
  falconImageAnalyzer: {}
  falconAdmission: {}
```

With this configuration:
- `autoUpdate: normal` enables automatic sensor version updates for the injected sidecar (the operator polls the CrowdStrike API every 24h by default)
- `updatePolicy: linux-prod` binds the sensor to a named Falcon **Sensor update policy** in the Falcon console
- `falcon_api: { cloud_region: autodiscover }` makes `Spec.FalconAPI` non-nil, which is a hard requirement enforced by the operator (`shouldTrackSensorVersions` in `falconcontainer_controller.go` returns `false` if `Spec.FalconAPI == nil`, even if `autoUpdate: normal` is set)
- Unpinned `image:` fields let the operator resolve image paths/digests from CrowdStrike on every reconcile
- **No IRSA `eks.amazonaws.com/role-arn` annotation is needed** on the injector or KAC ServiceAccount, because the pull happens at the Kubernetes layer using a `dockerconfigjson` pull secret created by the operator from the Falcon API credentials. Fargate scheduling is unaffected.

> [!IMPORTANT]
> **AutoUpdate only works when the Falcon images are pulled directly from `registry.crowdstrike.com`.** It will *not* work when images are mirrored into a private registry such as ECR, because:
> - The operator has no authority to push new images into your private registry, so newly-discovered sensor versions would simply not exist there.
> - The Falcon Operator's auto-update logic is also skipped whenever a specific image (or version) is pinned on the CR (per the operator docs: *"This has no effect if a specific image or version has been requested."*).
>
> If you need Fargate pods to pull images from a private registry (ECR or otherwise), use `eks_fargate_operator_install.sh` instead, and update sensor versions manually as described in [Manual updates with a private registry](#manual-updates-with-a-private-registry).

#### Manual updates with a private registry

When organizational policy requires mirroring CrowdStrike images into a private registry (ECR or otherwise) and having Fargate pods pull from there, sensor / KAC / IAR updates become a manual two-step process:

1. **Mirror the new image versions** from `registry.crowdstrike.com` into your private registry (for example, by re-running `eks_fargate_operator_install.sh`, which uses `falcon-container-sensor-pull.sh` to pull and push to ECR).
2. **Update the deployment manifest** (`FalconDeploymentFargate.yaml`) to reference the new image tags / digests, and re-apply with `kubectl apply -f`.

This workflow can be **automated at scale using a GitOps approach**:
- Store `FalconDeploymentFargate.yaml` (and any per-environment overlays) in Git as the **source of truth**.
- Use a CI pipeline to mirror new CrowdStrike images to the private registry and to bump the image tags in the manifest via pull request.
- Use a GitOps controller such as **[ArgoCD](https://argo-cd.readthedocs.io/)** or **[Flux](https://fluxcd.io/)** to continuously reconcile the cluster's `FalconDeployment` resource against the version checked into Git.

This pattern preserves the private-registry constraint while still giving you a controlled, auditable update mechanism for sensor, KAC and IAR versions.

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying `FalconDeploymentFargateAutoUpdate.yaml`, and it must be configured to target the sensor architecture in use (typically `amd64` for Fargate). If a mismatch exists between the policy's architecture and the running sensor, the sensor will not receive updates.

To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux** and ensure a policy called `linux-prod` exists with the correct architecture coverage. The name match is **case-sensitive and exact** (`linux_prod` will *not* match `linux-prod`).

#### Using the auto-update script

```bash
chmod +x eks_fargate_operator_install_autoupdate.sh
./eks_fargate_operator_install_autoupdate.sh
```

The script does **not** download `falcon-container-sensor-pull.sh`, log into ECR, push images, or create any IAM policies / IRSA roles, because images are pulled directly from CrowdStrike at pod scheduling time using a `dockerconfigjson` pull secret created by the Falcon Operator from your Falcon API credentials.

### Key Features

Common to all three scripts:
- Installs a pinned version of the Falcon Operator from the official GitHub release
- Auto-installs `eksctl` (with checksum verification) if not already present, and associates an IAM OIDC provider with the EKS cluster
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Comprehensive logging and error handling

Specific to `eks_fargate_operator_install.sh` only:
- Automatically downloads Falcon container images from the CrowdStrike registry and pushes them to AWS ECR (using `falcon-container-sensor-pull.sh`)
- Creates the `FalconContainerEcrPull` IAM policy and two IRSA roles (one for the falcon-injector SA, one for the falcon-kac SA), each with an OIDC trust policy scoped to the exact `system:serviceaccount:<ns>:<name>` that the operator will create
- Performs `sed`-based substitution of placeholders in `FalconDeploymentFargate.yaml` (account, region, ECR namespace, per-image tags, and the two IAM role names)

Specific to `eks_fargate_operator_install_exist_image.sh` only:
- Validates via `aws ecr describe-images` that each user-supplied image+tag (Container Sensor, KAC, IAR) is already present in ECR
- Creates the `FalconContainerEcrPull` IAM policy and the same two IRSA roles created by `eks_fargate_operator_install.sh`
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentFargate.yaml` using the user-supplied image names and tags from `eks_fargate_operator_inputs_exist_image.txt`

Specific to `eks_fargate_operator_install_autoupdate.sh` only:
- No ECR mirroring, no IAM policy / IRSA role creation, and no `sed` substitution: applies `FalconDeploymentFargateAutoUpdate.yaml` as-is
- Falcon Operator pulls Container Sensor / KAC / IAR images directly from `registry.crowdstrike.com` using a `dockerconfigjson` pull secret it generates from the Falcon API credentials
- Enables `advanced.autoUpdate: normal` so the Container Sensor sidecar is reconciled when new sensor versions are published in the `linux-prod` Sensor update policy

## What the Script Does

All three scripts share a common backbone (configuration loading, eksctl install, kubeconfig update, OIDC provider association, Falcon Operator install, secret creation, manifest apply, verification). The differences are concentrated in the image-handling, IAM, and manifest-processing steps.

### Common steps (all three scripts)

1. **Loads configuration** from the inputs file matched to the script:
   - `eks_fargate_operator_install.sh` -> `eks_fargate_operator_inputs.txt`
   - `eks_fargate_operator_install_exist_image.sh` -> `eks_fargate_operator_inputs_exist_image.txt`
   - `eks_fargate_operator_install_autoupdate.sh` -> `eks_fargate_operator_inputs_autoupdate.txt`
2. **Installs `eksctl`** automatically (with checksum verification) if not already present.
3. **Updates kubeconfig** for the target EKS cluster.
4. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`.
5. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is `Available`.
6. **Creates** the `falcon-secret` namespace and the `falcon-secrets` Kubernetes secret with your Falcon API credentials.
7. **Applies** the `FalconDeployment` manifest.
8. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments, component pods, and webhook configurations.

### Variant-specific image-handling and IAM steps

Steps below replace the generic "image handling and IAM" portion of the run, between configuration load (step 1) and the kubeconfig update (step 3).

#### `eks_fargate_operator_install.sh` (CrowdStrike -> ECR mirror, IRSA)

A. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo.

B. **Logs into AWS ECR** using the AWS CLI and Docker.

C. **Retrieves image tags** for `falcon-container`, `falcon-kac`, and `falcon-imageanalyzer` from the CrowdStrike registry.

D. **Pulls and pushes** those images to your ECR namespace.

E. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`.

F. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent).

G. **Creates two IAM roles** with OIDC trust policies (one per Falcon SA), and attaches the ECR-pull policy to each:
   - `${FALCON_INJECTOR_ROLE_NAME}` -> trusted by `system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME}`
   - `${FALCON_ADMISSION_ROLE_NAME}` -> trusted by `system:serviceaccount:${FALCON_ADMISSION_NAMESPACE}:${FALCON_ADMISSION_SA_NAME}`

H. **Processes `FalconDeploymentFargate.yaml`** with `sed` - substituting AWS account ID, region, ECR namespace, per-image tags, and the two IAM role names.

I. The operator creates the two ServiceAccounts annotated with `eks.amazonaws.com/role-arn`. Fargate pods assume the IAM role via OIDC and pull images from ECR.

#### `eks_fargate_operator_install_exist_image.sh` (images already in ECR, IRSA)

A. **Validates via `aws ecr describe-images`** that each user-supplied image name and tag (Container Sensor, KAC, IAR) is already present in ECR. The script aborts with an error if any is missing.

B. *No download from CrowdStrike, no docker push.*

C. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`.

D. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent).

E. **Creates the same two IAM roles** as `eks_fargate_operator_install.sh`, with OIDC trust policies scoped per Falcon SA, and attaches the ECR-pull policy to each.

F. **Processes `FalconDeploymentFargate.yaml`** with `sed` - substituting AWS account ID, region, ECR namespace, the two IAM role names, and the user-supplied image names + tags from `eks_fargate_operator_inputs_exist_image.txt`.

G. The operator creates the two ServiceAccounts annotated with `eks.amazonaws.com/role-arn`. Fargate pods assume the IAM role via OIDC and pull the existing images from ECR.

#### `eks_fargate_operator_install_autoupdate.sh` (direct from CrowdStrike, auto-update)

A. *No download of `falcon-container-sensor-pull.sh`.*

B. *No ECR login, no docker pull, no docker push.*

C. *No `FalconContainerEcrPull` IAM policy, no IRSA roles created.*

D. *No `sed` template processing.* `FalconDeploymentFargateAutoUpdate.yaml` is applied as-is because all image fields are intentionally unpinned (a hard requirement for the operator's auto-update logic to engage).

E. The Falcon Operator generates a `dockerconfigjson` pull secret from the Falcon API credentials in the `falcon-secrets` k8s secret, and Fargate pods use that pull secret to pull images directly from `registry.crowdstrike.com`. This works on Fargate because authentication occurs at the Kubernetes layer rather than at the underlying-node IAM layer.

F. The operator polls the CrowdStrike API on a schedule (default 24h) and reconciles the FalconContainerSensor whenever a new sensor version is published in the `linux-prod` Sensor update policy.

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write) - required for `eks_fargate_operator_install.sh` (ECR mirroring); not required for the exist-image or auto-update variants
- **Falcon Container Image** (Read/Write) - required for `eks_fargate_operator_install.sh` (ECR mirroring); not required for the exist-image or auto-update variants
- **Sensor Update Policies** (Read) - required only when using `FalconDeploymentFargateAutoUpdate.yaml` (advanced `autoUpdate` enabled), so the Container Sensor sidecar can resolve the `linux-prod` update policy

### EKS Cluster Requirements

- An existing **EKS Fargate cluster** (Fargate-only or mixed Fargate/EC2)
- **Fargate profiles** must exist that select the Falcon component namespaces. By default both scripts require Fargate profile coverage for:
  - `falcon-operator`
  - `falcon-secret`
  - `falcon-system` (FalconContainerSensor injector)
  - `falcon-kac` (FalconAdmission)
  - `falcon-image-analyzer` (FalconImageAnalyzer)
- **Fargate profiles must also cover the workload namespaces** you want protected (so workload pods scheduled on Fargate can be intercepted and sidecar-injected by the mutating webhook)
- Fargate pods need outbound network reachability to the registry serving the Falcon images:
  - For `eks_fargate_operator_install.sh` and `eks_fargate_operator_install_exist_image.sh`: ECR (or whatever private registry holds the mirrored Falcon images) - via IRSA-backed credentials
  - For `eks_fargate_operator_install_autoupdate.sh`: `registry.crowdstrike.com` (no ECR access required, since auto-update precludes mirroring; no IRSA required since pull secret is Kubernetes-level)
- The cluster should have an IAM OIDC provider associated. Both scripts will associate one for you - if you prefer to do this manually first:
  ```bash
  eksctl utils associate-iam-oidc-provider \
    --region "<YOUR_AWS_REGION>" \
    --cluster "<YOUR_EKS_CLUSTER_NAME>" \
    --approve
  ```
- The Falcon components need outbound Internet access to send telemetry to the CrowdStrike cloud

### System Requirements

- AWS CLI configured with permissions appropriate to the chosen script:
  - `eks_fargate_operator_install.sh`: ECR (push), EKS (describe/update), IAM (create policies/roles, attach role policies, manage OIDC providers)
  - `eks_fargate_operator_install_exist_image.sh`: ECR (read/describe-images only - no push), EKS (describe/update), IAM (create policies/roles, attach role policies, manage OIDC providers)
  - `eks_fargate_operator_install_autoupdate.sh`: EKS (describe/update), IAM (manage OIDC provider). **No ECR or IAM role-creation permissions required.**
- Linux/Unix environment with the following tools installed:
  - `bash`
  - `curl`
  - `aws-cli`
  - `sed`
  - `docker` *(only for `eks_fargate_operator_install.sh`)*
  - `kubectl`
  - `eksctl` (auto-installed if missing)

> Tip: You can use AWS CloudShell where most tools are pre-installed.

### AWS ECR Repositories

> [!NOTE]
> ECR repositories are required for `eks_fargate_operator_install.sh` and `eks_fargate_operator_install_exist_image.sh`, where Falcon images are mirrored to ECR (or already mirrored) and Fargate pods pull from ECR via IRSA.
>
> If you are using `eks_fargate_operator_install_autoupdate.sh`, **skip this section** - images are pulled directly from `registry.crowdstrike.com` and no ECR repositories are needed.

For the non-auto-update flows, the following ECR repositories must exist in your AWS account ahead of time:

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
   - `eks_fargate_operator_install.sh` **or** `eks_fargate_operator_install_exist_image.sh` **or** `eks_fargate_operator_install_autoupdate.sh`
   - `FalconDeploymentFargate.yaml` (for the first two scripts) **or** `FalconDeploymentFargateAutoUpdate.yaml` (for the auto-update script)
   - `eks_fargate_operator_inputs.txt` **or** `eks_fargate_operator_inputs_exist_image.txt` **or** `eks_fargate_operator_inputs_autoupdate.txt`

3. **Configure Variables**: Edit the appropriate inputs file for the script you are running.

   **`eks_fargate_operator_inputs.txt`** (used by `eks_fargate_operator_install.sh`):

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

   **`eks_fargate_operator_inputs_exist_image.txt`** (used by `eks_fargate_operator_install_exist_image.sh`) - same shape as `eks_fargate_operator_inputs.txt` (all the same AWS / IRSA variables) plus the existing image names and tags already in ECR:

   | Variable | Description |
   |----------|-------------|
   | `CONTAINER_IMAGE_NAME` | ECR repo name for the Falcon Container Sensor (e.g. `falcon-container`) |
   | `CONTAINER_IMAGE_TAG` | Existing tag of the Falcon Container Sensor image in ECR |
   | `KAC_IMAGE_NAME` | ECR repo name for the Falcon KAC (e.g. `falcon-kac`) |
   | `KAC_IMAGE_TAG` | Existing tag of the Falcon KAC image in ECR |
   | `IAR_IMAGE_NAME` | ECR repo name for the Falcon Image Analyzer (e.g. `falcon-imageanalyzer`) |
   | `IAR_IMAGE_TAG` | Existing tag of the Falcon Image Analyzer image in ECR |

   **`eks_fargate_operator_inputs_autoupdate.txt`** (used by `eks_fargate_operator_install_autoupdate.sh`) - reduced set, since no ECR mirroring and no IRSA is performed:

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS Fargate cluster |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `CLUSTER_NAME` | Name of the target EKS Fargate cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |

   Note that `AWS_ACCOUNT_ID`, `IMAGE_REPO_NAMESPACE`, and all `FALCON_INJECTOR_*` / `FALCON_ADMISSION_*` IAM/SA variables are intentionally **not** required for the auto-update variant, because images are pulled directly from `registry.crowdstrike.com` via a Kubernetes-level pull secret instead of from ECR via IRSA.

4. **Review Customization** (Optional): Check the [Falcon Operator repo](https://github.com/crowdstrike/falcon-operator) for additional `FalconDeployment` configuration options.

### Step 2: Execute Installation

If pulling and pushing images from the CrowdStrike registry to ECR (with IRSA-backed pulls):

```bash
# Make the script executable
chmod +x eks_fargate_operator_install.sh

# Run the installation
./eks_fargate_operator_install.sh
```

If the Container Sensor, KAC and IAR images already exist in your ECR (with IRSA-backed pulls):

```bash
# Make the script executable
chmod +x eks_fargate_operator_install_exist_image.sh

# Run the installation (uses eks_fargate_operator_inputs_exist_image.txt)
./eks_fargate_operator_install_exist_image.sh
```

If you want sensor auto-update (images pulled directly from CrowdStrike, no ECR mirroring, no IRSA roles):

```bash
# Make the script executable
chmod +x eks_fargate_operator_install_autoupdate.sh

# Run the installation (uses eks_fargate_operator_inputs_autoupdate.txt and FalconDeploymentFargateAutoUpdate.yaml)
./eks_fargate_operator_install_autoupdate.sh
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
├── README_eks_node_operator.md                   # EKS node-pools (EC2) deployment doc
├── README_eks_fargate_operator.md                # This documentation (EKS Fargate)
├── eks_node_operator_install.sh                  # EKS node-pools installer
├── eks_node_operator_install_exist_image.sh      # EKS node-pools installer (existing ECR images)
├── eks_node_operator_install_autoupdate.sh       # EKS node-pools installer (auto-update, direct from CrowdStrike)
├── eks_fargate_operator_install.sh               # EKS Fargate installer (mirrors images CrowdStrike -> ECR + IRSA)
├── eks_fargate_operator_install_exist_image.sh   # EKS Fargate installer (existing ECR images + IRSA)
├── eks_fargate_operator_install_autoupdate.sh    # EKS Fargate installer (auto-update, direct from CrowdStrike, no IRSA)
├── eks_node_operator_inputs.txt                  # Config for eks_node_operator_install.sh
├── eks_node_operator_inputs_exist_image.txt      # Config for eks_node_operator_install_exist_image.sh
├── eks_node_operator_inputs_autoupdate.txt       # Config for eks_node_operator_install_autoupdate.sh
├── eks_fargate_operator_inputs.txt               # Config for eks_fargate_operator_install.sh
├── eks_fargate_operator_inputs_exist_image.txt   # Config for eks_fargate_operator_install_exist_image.sh
├── eks_fargate_operator_inputs_autoupdate.txt    # Config for eks_fargate_operator_install_autoupdate.sh
├── FalconDeploymentNode.yaml                     # Node manifest (private registry, no auto-update)
├── FalconDeploymentNodeAutoUpdate.yaml           # Node manifest with falcon_api + auto-update enabled
├── FalconDeploymentFargate.yaml                  # Fargate manifest (private registry + IRSA, no auto-update)
└── FalconDeploymentFargateAutoUpdate.yaml        # Fargate manifest with falcon_api + auto-update enabled (no IRSA)
```

## Template Processing

> The auto-update flow (`eks_fargate_operator_install_autoupdate.sh` + `FalconDeploymentFargateAutoUpdate.yaml`) does **not** perform any `sed` substitution. The manifest is applied as-is because all image fields are unpinned and no IRSA role names are referenced.

`eks_fargate_operator_install.sh` and `eks_fargate_operator_install_exist_image.sh` use `sed` to substitute the following placeholders in `FalconDeploymentFargate.yaml`:

| Placeholder | Replaced with |
|-------------|---------------|
| `<YOUR_AWS_ACCOUNT_ID>` | `AWS_ACCOUNT_ID` from inputs |
| `<AWS_REGIONS>` | `AWS_REGION` from inputs |
| `<YOUR_NAMESPACE>` | `IMAGE_REPO_NAMESPACE` from inputs |
| `<TAG>` (falcon-container line) | `eks_fargate_operator_install.sh`: latest `falcon-container` tag pulled from CrowdStrike registry. `eks_fargate_operator_install_exist_image.sh`: `CONTAINER_IMAGE_TAG` from inputs (and the image name is rewritten from `falcon-container` to `CONTAINER_IMAGE_NAME` if customized) |
| `<TAG>` (falcon-kac line) | `eks_fargate_operator_install.sh`: latest `falcon-kac` tag pulled from CrowdStrike registry. `eks_fargate_operator_install_exist_image.sh`: `KAC_IMAGE_TAG` from inputs |
| `<TAG>` (falcon-imageanalyzer line) | `eks_fargate_operator_install.sh`: latest `falcon-imageanalyzer` tag pulled from CrowdStrike registry. `eks_fargate_operator_install_exist_image.sh`: `IAR_IMAGE_TAG` from inputs |
| `<FALCON_CONTAINER_INJECTOR_ROLE>` | `FALCON_INJECTOR_ROLE_NAME` from inputs |
| `<FALCON_ADMISSION_ROLE>` | `FALCON_ADMISSION_ROLE_NAME` from inputs |

The processed manifest is written to `/tmp/FalconDeploymentFargate_processed.yaml`, applied with `kubectl apply`, and then removed at the end of the script.

## IAM / IRSA Architecture

> The auto-update flow does **not** require any IAM roles or IRSA. Skip this section if you are using `eks_fargate_operator_install_autoupdate.sh`. Image pulls happen at the Kubernetes layer via a `dockerconfigjson` pull secret created by the Falcon Operator from the Falcon API credentials, which works on Fargate without any node-level or IAM-level credentials.

For `eks_fargate_operator_install.sh` and `eks_fargate_operator_install_exist_image.sh`, Fargate pods cannot use the underlying node's IAM credentials, so ECR pulls and any AWS API calls must use IRSA (IAM Roles for Service Accounts). Both scripts provision:

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

How you update Container Sensor (sidecar), KAC and IAR versions depends on which install path you used:

### Auto-update (images pulled directly from CrowdStrike)

If you deployed via `eks_fargate_operator_install_autoupdate.sh` with `FalconDeploymentFargateAutoUpdate.yaml`:
- The Container Sensor sidecar auto-updates on its own (the operator polls the CrowdStrike API every 24h by default; configurable via `--sensor-auto-update-interval` on the operator) and follows the `linux-prod` Sensor update policy.
- KAC and IAR images, since they are unpinned in the manifest, are also re-resolved by the operator on reconcile.
- No manual action is required to pick up new versions.
- New sidecars are injected at pod creation time, so existing workload pods continue running the previously injected sensor version until they are recreated. To roll forward immediately, restart the workloads (e.g. `kubectl rollout restart deployment/<name>`).

### Private registry (manual / GitOps update)

If you deployed via `eks_fargate_operator_install.sh` or `eks_fargate_operator_install_exist_image.sh`, Fargate pods are pulling images from your ECR via IRSA and the operator's auto-update logic is disabled (auto-update is incompatible with pinned images / private registries). Update versions by:

1. Mirroring the new Container Sensor / KAC / IAR images from `registry.crowdstrike.com` into your ECR (e.g. by re-running `eks_fargate_operator_install.sh`).
2. Editing the `FalconDeployment` resource to point at the new image tags / digests:
   ```bash
   kubectl get falcondeployments
   kubectl edit falcondeployment falcon-deployment
   ```
   or by updating the manifest file and re-applying it with `kubectl apply -f`.

For larger fleets, automate this with **GitOps**: keep `FalconDeploymentFargate.yaml` in Git as the source of truth, have a CI pipeline mirror new CrowdStrike images to ECR and bump tags via PR, and have **[ArgoCD](https://argo-cd.readthedocs.io/)** or **[Flux](https://fluxcd.io/)** continuously reconcile the cluster against Git.

## Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm permissions appropriate to the chosen script (ECR push + IAM for the non-auto-update flow; only EKS for the auto-update flow)
3. **Inspect Operator logs**:
   ```bash
   kubectl logs -n falcon-operator deploy/falcon-operator-controller-manager
   ```
4. **Inspect Component logs**: Use `kubectl logs` against pods in the component namespaces (`falcon-system`, `falcon-kac`, `falcon-image-analyzer`)
5. **Verify Secret**: Confirm the `falcon-secrets` secret exists in the `falcon-secret` namespace:
   ```bash
   kubectl get secret falcon-secrets -n falcon-secret
   ```
6. **Auto-update: `update-policy linux-prod not found` error in operator logs**:
   - The Falcon `Sensor update policies` API uses an exact, **case-sensitive** match on the policy name. `linux_prod` (underscore) does not match `linux-prod` (hyphen). Confirm the exact stored name in the Falcon UI under **Host setup and management > Sensor update policies > Linux**.
   - Confirm the API client used by `falcon-secrets` has the `Sensor Update Policies: Read` scope.
   - Confirm the policy is enabled and has a sensor version assigned for the platform/architecture in use (Fargate is typically `amd64`).
7. **IRSA / ECR pull failures (non-auto-update flow only)**: If pods stay in `ImagePullBackOff`, check:
   - The SA actually has the `eks.amazonaws.com/role-arn` annotation
   - The OIDC trust policy `sub` matches `system:serviceaccount:<ns>:<sa-name>` exactly
   - The IAM role has `FalconContainerEcrPull` attached
   - The pod logs show the role being assumed (look for `AssumeRoleWithWebIdentity` events in CloudTrail)
8. **CrowdStrike registry pull failures (auto-update flow only)**: If pods stay in `ImagePullBackOff`, check:
   - The Falcon API credentials in the `falcon-secrets` secret are correct and have `Falcon Images Download: Read` and `Sensor Download: Read` scopes
   - The Fargate pods can reach `registry.crowdstrike.com` (egress / VPC endpoints / firewall rules)
   - The operator created the `dockerconfigjson` pull secret in the install namespace (`kubectl get secret -n falcon-system | grep -i pull`)
9. **Fargate scheduling issues**: If pods are stuck in `Pending`, verify a Fargate profile selects the namespace
10. **Validate Configuration**: Ensure all variables in the inputs file are correct
11. **Review manifest** (non-auto-update flow only): Inspect `/tmp/FalconDeploymentFargate_processed.yaml` during a run to confirm substitutions

## Cleanup

```bash
# Delete the FalconDeployment (operator will tear down components)
kubectl delete falcondeployment falcon-deployment

# Uninstall the Falcon Operator
kubectl delete -f "https://github.com/crowdstrike/falcon-operator/releases/download/${FALCON_OPERATOR_VERSION}/falcon-operator.yaml"

# Delete remaining namespaces if needed
kubectl delete namespace falcon-secret falcon-system falcon-kac falcon-image-analyzer
```

If you used `eks_fargate_operator_install.sh` or `eks_fargate_operator_install_exist_image.sh` (non-auto-update flow), also delete the IAM artifacts:

```bash
aws iam detach-role-policy --role-name "${FALCON_INJECTOR_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam detach-role-policy --role-name "${FALCON_ADMISSION_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam delete-role --role-name "${FALCON_INJECTOR_ROLE_NAME}"
aws iam delete-role --role-name "${FALCON_ADMISSION_ROLE_NAME}"
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
```

> The auto-update flow creates no IAM policies or roles, so no IAM cleanup is required for `eks_fargate_operator_install_autoupdate.sh`.

## Additional Resources

- [Falcon Operator (GitHub)](https://github.com/crowdstrike/falcon-operator)
- [Falcon Operator FalconDeployment sample (Fargate sidecar)](https://github.com/CrowdStrike/falcon-operator/tree/main/config/samples)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)
- [AWS EKS Fargate documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Plan Your Deployment](https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0)

## Important Note

> [!IMPORTANT]
> **Auto-update flow only - sidecar pull-secret propagation to namespaces created after install**
>
> For the **auto-update** sensor-version flow (`eks_fargate_operator_install_autoupdate.sh` + `FalconDeploymentFargateAutoUpdate.yaml`), where the Falcon Container Sensor sidecar is pulled directly from `registry.crowdstrike.com`, the Falcon Operator currently does **not** automatically inject the `crowdstrike-falcon-pull-secret` dockerconfigjson secret into namespaces that are created **after** the Falcon Operator install.
>
> This pull secret is required so that pods in those namespaces can authenticate to the CrowdStrike registry and pull the injected Container Sensor sidecar image. Because the secret is missing, Fargate-scheduled pods created in any post-install namespace will fail to start with an `ImagePullBackOff` / `403 Forbidden` on the `falcon-container` image.
>
> **Quick workaround**: restart the Falcon Operator to force a full reconcile, which iterates all namespaces and creates the pull secret in each:
>
> ```bash
> kubectl -n falcon-operator rollout restart deploy/falcon-operator-controller-manager
> ```
>
> After the operator pod becomes ready again, recreate the failing workload pods (e.g. `kubectl rollout restart deployment/<name>` in the affected namespace).
>
> An upstream issue tracking a permanent fix (a namespace watch on the `FalconContainer` controller so newly created namespaces trigger a reconcile automatically) has been opened at [crowdstrike/falcon-operator#823](https://github.com/CrowdStrike/falcon-operator/issues/823).
>
> The non-auto-update flow (`eks_fargate_operator_install.sh` and `eks_fargate_operator_install_exist_image.sh`) is **not** affected, because images are pulled from ECR via IRSA - no per-namespace Kubernetes pull secret is involved.
