# CrowdStrike Falcon Operator EKS Node Installation

These scripts automate the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS cluster with node pools (EC2 worker nodes).

## Overview

The `eks_node_operator_install.sh`, `eks_node_operator_install_exist_image.sh` and `eks_node_operator_install_autoupdate.sh` scripts deploy the Falcon Operator and a `FalconDeployment` manifest to install the following security components via custom resources managed by the operator:

- **Falcon Node Sensor** (`deployNodeSensor: true`) - DaemonSet providing endpoint protection on every EKS node
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning
- **Container Sensor disabled** (`deployContainerSensor: false`) - Not needed on EC2 node pools since Node Sensor covers workloads

### Choosing an installation script

Three installation scripts are provided. Pick the one that matches your registry strategy and update strategy:

| Script | When to use | Inputs file | Manifest |
|--------|-------------|-------------|----------|
| `eks_node_operator_install.sh` | The Falcon Sensor, KAC and IAR images are **not** yet in ECR. The script pulls them from the CrowdStrike registry and pushes them to your ECR. EKS nodes pull from ECR. | `eks_node_operator_inputs.txt` | `FalconDeploymentNode.yaml` |
| `eks_node_operator_install_exist_image.sh` | The Falcon Sensor, KAC and IAR images **already exist** in your ECR (for example, mirrored by a separate process or previous run). The script skips the CrowdStrike pull / ECR push and references the existing images directly. EKS nodes pull from ECR. | `eks_node_operator_inputs_exist_image.txt` | `FalconDeploymentNode.yaml` |
| `eks_node_operator_install_autoupdate.sh` | You want the **Falcon Node Sensor to auto-upgrade** via a Falcon sensor update policy. EKS nodes pull images **directly from `registry.crowdstrike.com`** using credentials managed by the Falcon Operator. **No ECR mirroring is performed**. | `eks_node_operator_inputs_autoupdate.txt` | `FalconDeploymentNodeAutoUpdate.yaml` |

The "exist image" variant additionally validates that each referenced image+tag is actually present in ECR (via `aws ecr describe-images`) before proceeding, and uses the user-supplied image names and tags when substituting into the `FalconDeploymentNode.yaml` manifest.

### Falcon Node Sensor Auto-Update

`eks_node_operator_install_autoupdate.sh` together with `eks_node_operator_inputs_autoupdate.txt` and `FalconDeploymentNodeAutoUpdate.yaml` enables sensor auto-update. The manifest declares the following under `spec.falconNodeSensor.node`:

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
  ...
  falconNodeSensor:
    node:
      tolerations: [...]
      advanced:
        autoUpdate: normal
        updatePolicy: linux-prod
  falconImageAnalyzer: {}
  falconAdmission: {}
```

With this configuration:
- `autoUpdate: normal` enables automatic sensor version updates for the Node Sensor DaemonSet (the operator polls the CrowdStrike API every 24h by default)
- `updatePolicy: linux-prod` binds the sensor to a named Falcon **Sensor update policy** in the Falcon console
- `falcon_api: { cloud_region: autodiscover }` makes `Spec.FalconAPI` non-nil, which is a hard requirement enforced by the operator (`shouldTrackSensorVersions` in `falconnodesensor_controller.go` returns `false` if `Spec.FalconAPI == nil`, even if `autoUpdate: normal` is set)
- Unpinned `image:` fields let the operator resolve image paths/digests from CrowdStrike on every reconcile

> [!IMPORTANT]
> **AutoUpdate only works when the Falcon images are pulled directly from `registry.crowdstrike.com`.** It will *not* work when images are mirrored into a private registry such as ECR, because:
> - The operator would have no authority to push new images into your private registry, so newly-discovered sensor versions would simply not exist there.
> - The Falcon Operator's auto-update logic is also skipped whenever a specific image (or version) is pinned on the CR (per the operator docs: *"This has no effect if a specific image or version has been requested."*).
>
> If you need EKS to pull images from a private registry (ECR or otherwise), use `eks_node_operator_install.sh` or `eks_node_operator_install_exist_image.sh` instead, and update sensor versions manually as described in [Manual updates with a private registry](#manual-updates-with-a-private-registry).

#### Manual updates with a private registry

When organizational policy requires mirroring CrowdStrike images into a private registry (ECR or otherwise) and having EKS pull from there, sensor / KAC / IAR updates become a manual two-step process:

1. **Mirror the new image versions** from `registry.crowdstrike.com` into your private registry (for example, by re-running `eks_node_operator_install.sh`, which uses `falcon-container-sensor-pull.sh` to pull and push to ECR).
2. **Update the deployment manifest** (`FalconDeploymentNode.yaml`) to reference the new image tags / digests, and re-apply with `kubectl apply -f`.

This workflow can be **automated at scale using a GitOps approach**:
- Store `FalconDeploymentNode.yaml` (and any per-environment overlays) in Git as the **source of truth**.
- Use a CI pipeline to mirror new CrowdStrike images to the private registry and to bump the image tags in the manifest via pull request.
- Use a GitOps controller such as **[ArgoCD](https://argo-cd.readthedocs.io/)** or **[Flux](https://fluxcd.io/)** to continuously reconcile the cluster's `FalconDeployment` resource against the version checked into Git.

This pattern preserves the private-registry constraint while still giving you a controlled, auditable update mechanism for sensor, KAC and IAR versions.

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying `FalconDeploymentNodeAutoUpdate.yaml`, and it must be configured to target the node architecture in use on the EKS worker nodes (either `amd64` or `arm64`). If a mismatch exists between the policy's architecture and the nodes, the sensor will not receive updates.

To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux** and ensure a policy called `linux-prod` exists with the correct host group membership / architecture.

#### Using the auto-update script

```bash
chmod +x eks_node_operator_install_autoupdate.sh
./eks_node_operator_install_autoupdate.sh
```

The script does **not** download `falcon-container-sensor-pull.sh`, log into ECR, or push images, because images are pulled directly from CrowdStrike at pod scheduling time using a `dockerconfigjson` pull secret created by the Falcon Operator from your Falcon API credentials.

### Key Features

Common to all three scripts:
- Installs a pinned version of the Falcon Operator from the official GitHub release
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Auto-installs `eksctl` (with checksum verification) if not already present, and associates an IAM OIDC provider with the EKS cluster
- Comprehensive logging and error handling

Specific to `eks_node_operator_install.sh` only:
- Automatically downloads Falcon container images from the CrowdStrike registry and pushes them to AWS ECR (using `falcon-container-sensor-pull.sh`)
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentNode.yaml` (`<YOUR_AWS_ACCOUNT_ID>`, `<AWS_REGIONS>`, `<YOUR_NAMESPACE>`, `<TAG>`)

Specific to `eks_node_operator_install_exist_image.sh` only:
- Validates via `aws ecr describe-images` that each user-supplied image+tag is already present in ECR
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentNode.yaml` using the user-supplied image names and tags

Specific to `eks_node_operator_install_autoupdate.sh` only:
- No ECR mirroring and no `sed` substitution: applies `FalconDeploymentNodeAutoUpdate.yaml` as-is
- Falcon Operator pulls Sensor / KAC / IAR images directly from `registry.crowdstrike.com` using a `dockerconfigjson` pull secret it generates from the Falcon API credentials
- Enables `advanced.autoUpdate: normal` so the Node Sensor is reconciled when new sensor versions are released

## What the Script Does

All three scripts share a common backbone (configuration loading, eksctl install, kubeconfig update, OIDC provider association, Falcon Operator install, secret creation, manifest apply, verification). The differences are concentrated in the image-handling and manifest-processing steps.

### Common steps (all three scripts)

1. **Loads configuration** from the inputs file matched to the script:
   - `eks_node_operator_install.sh` -> `eks_node_operator_inputs.txt`
   - `eks_node_operator_install_exist_image.sh` -> `eks_node_operator_inputs_exist_image.txt`
   - `eks_node_operator_install_autoupdate.sh` -> `eks_node_operator_inputs_autoupdate.txt`
2. **Installs `eksctl`** automatically (with checksum verification) if not already present.
3. **Updates kubeconfig** for the target EKS cluster.
4. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`.
5. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is `Available`.
6. **Creates** the `falcon-secret` namespace and the `falcon-secrets` Kubernetes secret with your Falcon API credentials.
7. **Applies** the `FalconDeployment` manifest.
8. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments and component pods.

### Variant-specific image-handling steps

Steps below replace the generic "image handling" portion of the run, between configuration load (step 1) and the kubeconfig update (step 3).

#### `eks_node_operator_install.sh` (CrowdStrike -> ECR mirror)

A. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo.

B. **Logs into AWS ECR** using the AWS CLI and Docker.

C. **Retrieves image tags** for `falcon-sensor`, `falcon-kac`, and `falcon-imageanalyzer` from the CrowdStrike registry.

D. **Pulls and pushes** those images to your ECR namespace.

E. **Processes `FalconDeploymentNode.yaml`** with `sed` - substituting the AWS account ID, region, ECR namespace and the per-image tags pulled in step C.

F. EKS nodes pull from your ECR.

#### `eks_node_operator_install_exist_image.sh` (images already in ECR)

A. **Validates via `aws ecr describe-images`** that each user-supplied image name and tag (Sensor, KAC, IAR) is already present in ECR. The script aborts with an error if any is missing.

B. *No download from CrowdStrike, no docker push.*

C. **Processes `FalconDeploymentNode.yaml`** with `sed` - substituting the AWS account ID, region, ECR namespace and the user-supplied image names + tags from `eks_node_operator_inputs_exist_image.txt`.

D. EKS nodes pull from your ECR.

#### `eks_node_operator_install_autoupdate.sh` (direct from CrowdStrike, auto-update)

A. *No download of `falcon-container-sensor-pull.sh`.*

B. *No ECR login, no docker pull, no docker push.*

C. *No `sed` template processing.* `FalconDeploymentNodeAutoUpdate.yaml` is applied as-is because all image fields are intentionally unpinned (a hard requirement for the operator's auto-update logic to engage).

D. The Falcon Operator generates a `dockerconfigjson` pull secret from the Falcon API credentials in the `falcon-secrets` k8s secret, and EKS nodes use that pull secret to pull images directly from `registry.crowdstrike.com`.

E. The operator polls the CrowdStrike API on a schedule (default 24h) and reconciles the Node Sensor DaemonSet whenever a new sensor version is published.

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write) - required for `eks_node_operator_install.sh` (ECR mirroring); not required for the auto-update variant
- **Falcon Container Image** (Read/Write) - required for `eks_node_operator_install.sh` (ECR mirroring); not required for the auto-update variant
- **Sensor Update Policies** (Read) - required only when using `FalconDeploymentNodeAutoUpdate.yaml` (advanced `autoUpdate` enabled), so the Node Sensor can resolve the `linux-prod` update policy

### EKS Cluster Requirements

- An existing **EKS cluster with EC2 node pools** (not Fargate-only)
- Node pools must have outbound network reachability to the registry serving the Falcon images:
  - For `eks_node_operator_install.sh` and `eks_node_operator_install_exist_image.sh`: ECR (or whatever private registry holds the mirrored Falcon images)
  - For `eks_node_operator_install_autoupdate.sh`: `registry.crowdstrike.com` (no ECR access required, since auto-update precludes mirroring)
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

> [!NOTE]
> ECR repositories are required **only** for the non-auto-update flows (`eks_node_operator_install.sh` and `eks_node_operator_install_exist_image.sh`), where Falcon images are mirrored to ECR and EKS nodes pull from ECR.
>
> If you are using `eks_node_operator_install_autoupdate.sh`, **skip this section** - images are pulled directly from `registry.crowdstrike.com` and no ECR repositories are needed.

For the non-auto-update flows, create the following ECR repositories in your AWS account ahead of time:

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
   - `eks_node_operator_install.sh` **or** `eks_node_operator_install_exist_image.sh` **or** `eks_node_operator_install_autoupdate.sh`
   - `FalconDeploymentNode.yaml` (for the first two scripts) **or** `FalconDeploymentNodeAutoUpdate.yaml` (for the auto-update script)
   - `eks_node_operator_inputs.txt` **or** `eks_node_operator_inputs_exist_image.txt` **or** `eks_node_operator_inputs_autoupdate.txt`

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

   **`eks_node_operator_inputs_autoupdate.txt`** (used by `eks_node_operator_install_autoupdate.sh`) - reduced set, since no ECR mirroring is performed:

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS cluster |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `CLUSTER_NAME` | Name of the target EKS cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |

   Note that `AWS_ACCOUNT_ID` and `IMAGE_REPO_NAMESPACE` are intentionally **not** required for the auto-update variant, because images are pulled directly from `registry.crowdstrike.com` instead of ECR.

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

If you want sensor auto-update (images pulled directly from CrowdStrike, no ECR mirroring):

```bash
# Make the script executable
chmod +x eks_node_operator_install_autoupdate.sh

# Run the installation (uses eks_node_operator_inputs_autoupdate.txt and FalconDeploymentNodeAutoUpdate.yaml)
./eks_node_operator_install_autoupdate.sh
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
├── README_eks_node_operator.md                   # This documentation
├── eks_node_operator_install.sh                  # Installer (mirrors images CrowdStrike -> ECR, EKS pulls from ECR)
├── eks_node_operator_install_exist_image.sh      # Installer for images already present in ECR
├── eks_node_operator_install_autoupdate.sh       # Installer for auto-update (EKS pulls directly from CrowdStrike, no ECR mirror)
├── FalconDeploymentNode.yaml                     # FalconDeployment manifest template (private registry, no auto-update)
├── FalconDeploymentNodeAutoUpdate.yaml           # FalconDeployment manifest with falcon_api + auto-update enabled (no pinned images)
├── eks_node_operator_inputs.txt                  # Configuration variables for eks_node_operator_install.sh
├── eks_node_operator_inputs_exist_image.txt      # Configuration variables for eks_node_operator_install_exist_image.sh
├── eks_node_operator_inputs_autoupdate.txt       # Configuration variables for eks_node_operator_install_autoupdate.sh
└── operator.md                                   # Step-by-step manual operator reference
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

How you update sensor, KAC and IAR versions depends on which install path you used:

### Auto-update (images pulled directly from CrowdStrike)

If you deployed via `eks_node_operator_install_autoupdate.sh` with `FalconDeploymentNodeAutoUpdate.yaml`:
- The Node Sensor auto-updates on its own (the operator polls the CrowdStrike API every 24h by default; configurable via `--sensor-auto-update-interval` on the operator).
- KAC and IAR images, since they are unpinned in the manifest, are also re-resolved by the operator on reconcile.
- No manual action is required to pick up new versions.

### Private registry (manual / GitOps update)

If you deployed via `eks_node_operator_install.sh` or `eks_node_operator_install_exist_image.sh`, EKS is pulling images from your private registry and the operator's auto-update logic is disabled (auto-update is incompatible with pinned images / private registries). Update versions by:

1. Mirroring the new sensor / KAC / IAR images from `registry.crowdstrike.com` into your private registry (e.g. by re-running `eks_node_operator_install.sh`).
2. Editing the `FalconDeployment` resource to point at the new image tags / digests:
   ```bash
   kubectl get falcondeployments
   kubectl edit falcondeployment falcon-deployment
   ```
   or by updating the manifest file and re-applying it with `kubectl apply -f`.

For larger fleets, automate this with **GitOps**: keep `FalconDeploymentNode.yaml` in Git as the source of truth, have a CI pipeline mirror new CrowdStrike images and bump tags via PR, and have **ArgoCD** or **Flux** continuously reconcile the cluster against Git.

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
