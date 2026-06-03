# CrowdStrike Falcon Operator EKS Mixed (Node + Fargate) Installation

These scripts automate the deployment of the **CrowdStrike Falcon Operator** and a `FalconDeployment` custom resource on an existing AWS EKS cluster that runs **both EC2 node pools and Fargate** in the same cluster.

## Overview

The `eks_mixed_operator_install.sh`, `eks_mixed_operator_install_exist_image.sh` and `eks_mixed_operator_install_autoupdate.sh` scripts deploy the Falcon Operator and a `FalconDeployment` manifest to install the following security components:

- **Falcon Node Sensor** (`deployNodeSensor: true`) - DaemonSet that runs on every EC2 node, providing endpoint protection for workloads scheduled on EC2
- **Falcon Container Sensor / Sidecar Injector** (`deployContainerSensor: true`) - Mutating webhook (deployed in the **`falcon-injector`** namespace) that injects the sensor as a sidecar into pods scheduled on **Fargate**
- **Kubernetes Admission Controller / KAC** (`deployAdmissionController: true`) - Runtime admission enforcement, deployed onto **EC2 nodes**
- **Image Assessment at Runtime / IAR** (`deployImageAnalyzer: true`) - Container image vulnerability scanning, deployed onto **EC2 nodes**

### Choosing an installation script

Three installation scripts are provided. Pick the one that matches your registry strategy and update strategy:

| Script | When to use | Inputs file | Manifest |
|--------|-------------|-------------|----------|
| `eks_mixed_operator_install.sh` | Falcon Sensor, Container Sensor, KAC and IAR images are mirrored from `registry.crowdstrike.com` to your ECR. EC2 pods pull from ECR via the node IAM role; Fargate pods pull from ECR via IRSA. | `eks_mixed_operator_inputs.txt` | `FalconDeploymentMixed.yaml` or `FalconDeploymentMixedAutoUpdate.yaml` (selected via `DEPLOYMENT_MANIFEST_NAME` in the inputs file) |
| `eks_mixed_operator_install_exist_image.sh` | Falcon Sensor, Container Sensor, KAC and IAR images **already exist** in your ECR (for example, mirrored by a separate process or previous run). The script skips the CrowdStrike pull / ECR push and references the existing images directly. EC2 pods pull from ECR via the node IAM role; Fargate pods pull from ECR via IRSA. | `eks_mixed_operator_inputs_exist_image.txt` | `FalconDeploymentMixed.yaml` |
| `eks_mixed_operator_install_autoupdate.sh` | You want the **Node Sensor (DaemonSet)** and **Container Sensor (sidecar)** to auto-upgrade via a Falcon sensor update policy. All four images are pulled **directly from `registry.crowdstrike.com`** by both EC2 and Fargate pods using a `dockerconfigjson` pull secret managed by the Falcon Operator. **No ECR mirroring is performed** and **no IRSA role is required** for the injector. | `eks_mixed_operator_inputs_autoupdate.txt` | `FalconDeploymentMixedAutoUpdate.yaml` |

The "exist image" variant additionally validates that each referenced image+tag is actually present in ECR (via `aws ecr describe-images`) before proceeding, and uses the user-supplied image names and tags when substituting into the `FalconDeploymentMixed.yaml` manifest.

### Component placement

| Component | Where it runs | How it pulls images (non-auto-update flow) | How it pulls images (auto-update flow) |
|-----------|---------------|--------------------------------------------|----------------------------------------|
| FalconNodeSensor (DaemonSet) | EC2 nodes only (DaemonSets cannot land on Fargate) | Node IAM role | Operator-managed pull secret -> `registry.crowdstrike.com` |
| FalconContainerSensor injector | **Fargate** (namespace `falcon-injector`) | **IRSA** (one IAM role) | Operator-managed pull secret -> `registry.crowdstrike.com` (no IRSA) |
| FalconAdmission (KAC) | EC2 nodes | Node IAM role | Operator-managed pull secret -> `registry.crowdstrike.com` |
| FalconImageAnalyzer (IAR) | EC2 nodes | Node IAM role | Operator-managed pull secret -> `registry.crowdstrike.com` |

This is enforced by which namespaces are covered by Fargate profiles:
- A Fargate profile **must** cover `falcon-injector` (and any workload namespaces you want sidecar-injected on Fargate)
- Fargate profiles **must NOT** cover `falcon-kac`, `falcon-image-analyzer`, or `falcon-system` so those pods schedule on EC2 nodes
- `falcon-operator` and `falcon-secret` do **not** need Fargate profile coverage in a mixed cluster: the operator's controller-manager Deployment will schedule onto EC2 nodes, and `falcon-secret` only holds a Kubernetes Secret object (no pods)

### Sensor Auto-Update (Node Sensor + Container Sensor)

`eks_mixed_operator_install_autoupdate.sh` together with `eks_mixed_operator_inputs_autoupdate.txt` and `FalconDeploymentMixedAutoUpdate.yaml` enables sensor auto-update for **both** the Node Sensor DaemonSet (EC2) and the Container Sensor sidecar (Fargate). The manifest declares the following `advanced` block on each:

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
  deployNodeSensor: true
  deployContainerSensor: true
  deployAdmissionController: true
  deployImageAnalyzer: true
  falconNodeSensor:
    node:
      tolerations: [...]
      advanced:
        autoUpdate: normal
        updatePolicy: linux-prod
  falconContainerSensor:
    installNamespace: falcon-injector
    advanced:
      autoUpdate: normal
      updatePolicy: linux-prod
  falconImageAnalyzer: {}
  falconAdmission: {}
```

With this configuration:
- `autoUpdate: normal` enables automatic sensor version updates (the operator polls the CrowdStrike API every 24h by default)
- `updatePolicy: linux-prod` binds both sensors to a named Falcon **Sensor update policy** in the Falcon console
- `falcon_api: { cloud_region: autodiscover }` makes `Spec.FalconAPI` non-nil, which is a hard requirement enforced by the operator: `shouldTrackSensorVersions` in `falconnodesensor_controller.go` and `falconcontainer_controller.go` returns `false` if `Spec.FalconAPI == nil`, even if `autoUpdate: normal` is set
- Unpinned `image:` fields let the operator resolve image paths/digests from CrowdStrike on every reconcile
- **No IRSA `eks.amazonaws.com/role-arn` annotation is needed** on the injector ServiceAccount, because the pull happens at the Kubernetes layer using a `dockerconfigjson` pull secret created by the operator from the Falcon API credentials. Fargate scheduling and pull behavior are unaffected.
- **The EC2 node IAM role does NOT need ECR pull permissions for the Falcon repos**, because Node Sensor / KAC / IAR pods also use the operator-managed pull secret to pull from `registry.crowdstrike.com`.

> [!IMPORTANT]
> **AutoUpdate only works when the Falcon images are pulled directly from `registry.crowdstrike.com`.** It will *not* work when images are mirrored into a private registry such as ECR, because:
> - The operator has no authority to push new images into your private registry, so newly-discovered sensor versions would simply not exist there.
> - The Falcon Operator's auto-update logic is also skipped whenever a specific image (or version) is pinned on the CR (per the operator docs: *"This has no effect if a specific image or version has been requested."*).
>
> If you need EC2 / Fargate pods to pull images from a private registry (ECR or otherwise), use `eks_mixed_operator_install.sh` instead, and update sensor versions manually as described in [Manual updates with a private registry](#manual-updates-with-a-private-registry).

#### Manual updates with a private registry

When organizational policy requires mirroring CrowdStrike images into a private registry (ECR or otherwise) and having EC2 / Fargate pods pull from there, sensor / KAC / IAR updates become a manual two-step process:

1. **Mirror the new image versions** from `registry.crowdstrike.com` into your private registry (for example, by re-running `eks_mixed_operator_install.sh`, which uses `falcon-container-sensor-pull.sh` to pull and push to ECR).
2. **Update the deployment manifest** (`FalconDeploymentMixed.yaml`) to reference the new image tags / digests, and re-apply with `kubectl apply -f`.

This workflow can be **automated at scale using a GitOps approach**:
- Store `FalconDeploymentMixed.yaml` (and any per-environment overlays) in Git as the **source of truth**.
- Use a CI pipeline to mirror new CrowdStrike images to the private registry and to bump the image tags in the manifest via pull request.
- Use a GitOps controller such as **[ArgoCD](https://argo-cd.readthedocs.io/)** or **[Flux](https://fluxcd.io/)** to continuously reconcile the cluster's `FalconDeployment` resource against the version checked into Git.

This pattern preserves the private-registry constraint while still giving you a controlled, auditable update mechanism for sensor, Container Sensor, KAC and IAR versions.

#### Prerequisite for auto-update

A Falcon **sensor update policy named `linux-prod`** must already exist in the Falcon platform **before** applying `FalconDeploymentMixedAutoUpdate.yaml`, configured to target the architecture(s) in use (`amd64` and/or `arm64`). To create/manage the policy in Falcon: **Host setup and management > Sensor update policies > Linux**.

The name match is **case-sensitive and exact** (`linux_prod` will *not* match `linux-prod`). Failure to find the policy will cause the operator to log `update-policy linux-prod not found` and silently skip creating the corresponding component (DaemonSet or injector Deployment).

#### Switching manifests with the non-auto-update script

`eks_mixed_operator_install.sh` also supports the auto-update manifest via the `DEPLOYMENT_MANIFEST_NAME` variable in `eks_mixed_operator_inputs.txt`. However, the resulting deployment will *not* actually auto-update because images are pinned to ECR tags after `sed` substitution. Prefer `eks_mixed_operator_install_autoupdate.sh` for true auto-update behavior.

### Key Features

Common to all three scripts:
- Installs a pinned version of the Falcon Operator from the official GitHub release
- Auto-installs `eksctl` (with checksum verification) if not already present, and associates an IAM OIDC provider with the EKS cluster
- Creates the `falcon-secret` namespace and the `falcon-secrets` secret referenced by the `FalconDeployment`
- Comprehensive logging and error handling

Specific to `eks_mixed_operator_install.sh` only:
- Pulls and pushes all four Falcon container images (`falcon-sensor`, `falcon-container`, `falcon-kac`, `falcon-imageanalyzer`) from `registry.crowdstrike.com` to AWS ECR (using `falcon-container-sensor-pull.sh`)
- Creates the `FalconContainerEcrPull` IAM policy and a single IRSA role for the injector ServiceAccount on Fargate
- Performs `sed`-based substitution of placeholders in the chosen mixed manifest (account, region, ECR namespace, per-image tags, and the injector IAM role name)

Specific to `eks_mixed_operator_install_exist_image.sh` only:
- Validates via `aws ecr describe-images` that each user-supplied image+tag (Sensor, Container Sensor, KAC, IAR) is already present in ECR
- Creates the `FalconContainerEcrPull` IAM policy and the same single IRSA role for the injector ServiceAccount on Fargate as `eks_mixed_operator_install.sh`
- Performs `sed`-based substitution of the placeholders in `FalconDeploymentMixed.yaml` using the user-supplied image names and tags from `eks_mixed_operator_inputs_exist_image.txt`
- Always uses the non-auto-update manifest (`FalconDeploymentMixed.yaml`); auto-update is incompatible with private/ECR registries

Specific to `eks_mixed_operator_install_autoupdate.sh` only:
- No ECR mirroring, no IAM policy / IRSA role creation, and no `sed` substitution: applies `FalconDeploymentMixedAutoUpdate.yaml` as-is
- Falcon Operator pulls Node Sensor / Container Sensor / KAC / IAR images directly from `registry.crowdstrike.com` using a `dockerconfigjson` pull secret it generates from the Falcon API credentials (works for both EC2 and Fargate pods)
- Enables `advanced.autoUpdate: normal` on both the Node Sensor and Container Sensor so each is reconciled when new sensor versions are published in the `linux-prod` Sensor update policy

## What the Script Does

All three scripts share a common backbone (configuration loading, eksctl install, kubeconfig update, OIDC provider association, Falcon Operator install, secret creation, manifest apply, verification). The differences are concentrated in the image-handling, IAM, and manifest-processing steps.

### Common steps (all three scripts)

1. **Loads configuration** from the inputs file matched to the script:
   - `eks_mixed_operator_install.sh` -> `eks_mixed_operator_inputs.txt`
   - `eks_mixed_operator_install_exist_image.sh` -> `eks_mixed_operator_inputs_exist_image.txt`
   - `eks_mixed_operator_install_autoupdate.sh` -> `eks_mixed_operator_inputs_autoupdate.txt`
2. **Installs `eksctl`** automatically (with checksum verification) if not already present.
3. **Updates kubeconfig** for the target EKS cluster.
4. **Associates the cluster with an IAM OIDC provider** using `eksctl utils associate-iam-oidc-provider --approve`.
5. **Installs the Falcon Operator** at the version specified in the inputs file and waits until the operator is `Available`.
6. **Creates** the `falcon-secret` namespace and the `falcon-secrets` Kubernetes secret with your Falcon API credentials.
7. **Applies** the `FalconDeployment` manifest.
8. **Verifies** the installation by listing the `falcondeployments` resource, operator deployments, component pods (Node Sensor DaemonSet on EC2, injector on Fargate, KAC and IAR on EC2), and webhook configurations.

### Variant-specific image-handling and IAM steps

Steps below replace the generic "image handling and IAM" portion of the run, between configuration load (step 1) and the kubeconfig update (step 3).

#### `eks_mixed_operator_install.sh` (CrowdStrike -> ECR mirror, IRSA for injector)

A. **Downloads** `falcon-container-sensor-pull.sh` from the official CrowdStrike scripts repo.

B. **Logs into AWS ECR** using the AWS CLI and Docker.

C. **Retrieves image tags** for `falcon-sensor`, `falcon-container`, `falcon-kac`, and `falcon-imageanalyzer` from the CrowdStrike registry.

D. **Pulls and pushes** all four images to your ECR namespace.

E. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`.

F. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent).

G. **Creates one IAM role** with an OIDC trust policy bound to `system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME}` and attaches the ECR-pull policy. KAC and IAR rely on the EC2 node IAM role for ECR access in this topology.

H. **Processes the chosen mixed manifest** with `sed` - substituting AWS account ID, region, ECR namespace, per-image tags, and the injector IAM role name.

I. The operator creates the `crowdstrike-falcon-sa` ServiceAccount in `falcon-injector` annotated with `eks.amazonaws.com/role-arn`. Fargate-scheduled injector pods pull from ECR via IRSA. EC2-scheduled Node Sensor / KAC / IAR pods pull from ECR via the node IAM role.

#### `eks_mixed_operator_install_exist_image.sh` (images already in ECR, IRSA for injector)

A. **Validates via `aws ecr describe-images`** that each user-supplied image name and tag (Sensor, Container Sensor, KAC, IAR) is already present in ECR. The script aborts with an error if any is missing.

B. *No download from CrowdStrike, no docker push.*

C. **Retrieves the cluster OIDC issuer URL** from `aws eks describe-cluster`.

D. **Creates the `FalconContainerEcrPull` IAM policy** (idempotent).

E. **Creates the same single IAM role** as `eks_mixed_operator_install.sh`, with an OIDC trust policy bound to `system:serviceaccount:${FALCON_INJECTOR_NAMESPACE}:${FALCON_INJECTOR_SA_NAME}`, and attaches the ECR-pull policy.

F. **Processes `FalconDeploymentMixed.yaml`** with `sed` - substituting AWS account ID, region, ECR namespace, the injector IAM role name, and the user-supplied image names + tags from `eks_mixed_operator_inputs_exist_image.txt`.

G. The operator creates the `crowdstrike-falcon-sa` ServiceAccount in `falcon-injector` annotated with `eks.amazonaws.com/role-arn`. Fargate-scheduled injector pods pull the existing image from ECR via IRSA; EC2-scheduled pods pull from ECR via the node IAM role.

#### `eks_mixed_operator_install_autoupdate.sh` (direct from CrowdStrike, auto-update, no IRSA)

A. *No download of `falcon-container-sensor-pull.sh`.*

B. *No ECR login, no docker pull, no docker push.*

C. *No `FalconContainerEcrPull` IAM policy, no IRSA role created.*

D. *No `sed` template processing.* `FalconDeploymentMixedAutoUpdate.yaml` is applied as-is because all image fields are intentionally unpinned (a hard requirement for the operator's auto-update logic to engage).

E. The Falcon Operator generates a `dockerconfigjson` pull secret from the Falcon API credentials in the `falcon-secrets` k8s secret. Both EC2-scheduled pods (Node Sensor / KAC / IAR) and Fargate-scheduled pods (Container Sensor injector) use that pull secret to pull images directly from `registry.crowdstrike.com`. On Fargate this works without IRSA because authentication occurs at the Kubernetes layer.

F. The operator polls the CrowdStrike API on a schedule (default 24h) and reconciles the FalconNodeSensor and the FalconContainerSensor whenever a new sensor version is published in the `linux-prod` Sensor update policy.

## Prerequisites

### Required Falcon API Scopes

Create a Falcon API client with the following scopes ([documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c)):

- **Falcon Images Download** (read)
- **Sensor Download** (read)
- **Falcon Container CLI** (Read/Write) - required for `eks_mixed_operator_install.sh` (ECR mirroring); not required for the exist-image or auto-update variants
- **Falcon Container Image** (Read/Write) - required for `eks_mixed_operator_install.sh` (ECR mirroring); not required for the exist-image or auto-update variants
- **Sensor Update Policies** (Read) - required when using `FalconDeploymentMixedAutoUpdate.yaml` (advanced `autoUpdate` enabled), so the Node Sensor and Container Sensor can resolve the `linux-prod` update policy

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
- The EKS cluster should have an **IAM OIDC provider** associated with it. Both scripts associate one automatically (and install `eksctl` first if needed). To do it manually:
  ```bash
  eksctl utils associate-iam-oidc-provider \
    --region "<YOUR_AWS_REGION>" \
    --cluster "<YOUR_EKS_CLUSTER_NAME>" \
    --approve
  ```
- Pods need outbound network reachability to the registry serving the Falcon images:
  - For `eks_mixed_operator_install.sh` and `eks_mixed_operator_install_exist_image.sh`: ECR (or whatever private registry holds the mirrored Falcon images) - via the EC2 node IAM role for EC2-scheduled pods, and via IRSA for the Fargate-scheduled injector. **EC2 node IAM role must have ECR pull permissions on the Falcon repos.**
  - For `eks_mixed_operator_install_autoupdate.sh`: `registry.crowdstrike.com` (no ECR access required, since auto-update precludes mirroring). **No IRSA required for the injector, and no ECR permissions required on the EC2 node IAM role for the Falcon repos.**
- The Falcon components need outbound Internet access to send telemetry to the CrowdStrike cloud

### System Requirements

- AWS CLI configured with permissions appropriate to the chosen script:
  - `eks_mixed_operator_install.sh`: ECR (push), EKS (describe/update), IAM (create policies/roles, attach role policies, manage OIDC providers)
  - `eks_mixed_operator_install_exist_image.sh`: ECR (read/describe-images only - no push), EKS (describe/update), IAM (create policies/roles, attach role policies, manage OIDC providers)
  - `eks_mixed_operator_install_autoupdate.sh`: EKS (describe/update), IAM (manage OIDC provider). **No ECR or IAM role-creation permissions required.**
- Linux/Unix environment with the following tools installed:
  - `bash`
  - `curl`
  - `aws-cli`
  - `sed`
  - `docker` *(only for `eks_mixed_operator_install.sh`)*
  - `kubectl`
  - `eksctl` (auto-installed if missing)

> Tip: You can use AWS CloudShell where most tools are pre-installed.

### AWS ECR Repositories

> [!NOTE]
> ECR repositories are required for `eks_mixed_operator_install.sh` and `eks_mixed_operator_install_exist_image.sh`, where Falcon images are mirrored to ECR (or already mirrored) and pulled by EC2 (via node IAM role) and Fargate (via IRSA) pods.
>
> If you are using `eks_mixed_operator_install_autoupdate.sh`, **skip this section** - images are pulled directly from `registry.crowdstrike.com` and no ECR repositories are needed.

For the non-auto-update flows, the following ECR repositories must exist in your AWS account ahead of time:

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
   - `eks_mixed_operator_install.sh` **or** `eks_mixed_operator_install_exist_image.sh` **or** `eks_mixed_operator_install_autoupdate.sh`
   - `FalconDeploymentMixed.yaml` and/or `FalconDeploymentMixedAutoUpdate.yaml`
   - `eks_mixed_operator_inputs.txt` **or** `eks_mixed_operator_inputs_exist_image.txt` **or** `eks_mixed_operator_inputs_autoupdate.txt`

3. **Configure Variables**: Edit the appropriate inputs file for the script you are running.

   **`eks_mixed_operator_inputs.txt`** (used by `eks_mixed_operator_install.sh`):

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

   **`eks_mixed_operator_inputs_exist_image.txt`** (used by `eks_mixed_operator_install_exist_image.sh`) - same shape as `eks_mixed_operator_inputs.txt` (all the same AWS / IRSA variables, except `DEPLOYMENT_MANIFEST_NAME` is hardcoded to `FalconDeploymentMixed.yaml`) plus the existing image names and tags already in ECR:

   | Variable | Description |
   |----------|-------------|
   | `SENSOR_IMAGE_NAME` | ECR repo name for the Falcon Node Sensor (e.g. `falcon-sensor`) |
   | `SENSOR_IMAGE_TAG` | Existing tag of the Falcon Node Sensor image in ECR |
   | `CONTAINER_IMAGE_NAME` | ECR repo name for the Falcon Container Sensor (e.g. `falcon-container`) |
   | `CONTAINER_IMAGE_TAG` | Existing tag of the Falcon Container Sensor image in ECR |
   | `KAC_IMAGE_NAME` | ECR repo name for the Falcon KAC (e.g. `falcon-kac`) |
   | `KAC_IMAGE_TAG` | Existing tag of the Falcon KAC image in ECR |
   | `IAR_IMAGE_NAME` | ECR repo name for the Falcon Image Analyzer (e.g. `falcon-imageanalyzer`) |
   | `IAR_IMAGE_TAG` | Existing tag of the Falcon Image Analyzer image in ECR |

   **`eks_mixed_operator_inputs_autoupdate.txt`** (used by `eks_mixed_operator_install_autoupdate.sh`) - reduced set, since no ECR mirroring and no IRSA is performed:

   | Variable | Description |
   |----------|-------------|
   | `FALCON_CLIENT_ID` | Your Falcon API client ID |
   | `FALCON_CLIENT_SECRET` | Your Falcon API client secret |
   | `AWS_REGION` | AWS region of the EKS mixed cluster |
   | `AWS_PROFILE` | AWS CLI profile to use |
   | `CLUSTER_NAME` | Name of the target mixed EKS cluster |
   | `FALCON_OPERATOR_VERSION` | Falcon Operator release tag (e.g. `v1.12.1`) |

   Note that `AWS_ACCOUNT_ID`, `IMAGE_REPO_NAMESPACE`, `DEPLOYMENT_MANIFEST_NAME`, and all `FALCON_INJECTOR_*` IAM/SA variables are intentionally **not** required for the auto-update variant, because images are pulled directly from `registry.crowdstrike.com` via a Kubernetes-level pull secret instead of from ECR via the node IAM role / IRSA.

4. **Review Customization** (Optional): Check the [Falcon Operator repo](https://github.com/crowdstrike/falcon-operator) for additional `FalconDeployment` configuration options, including node selectors, resource limits and tolerations.

### Step 2: Execute Installation

If pulling and pushing images from the CrowdStrike registry to ECR (with IRSA-backed pulls for the injector and node-IAM-role-backed pulls for EC2 components):

```bash
chmod +x eks_mixed_operator_install.sh
./eks_mixed_operator_install.sh
```

If the Sensor, Container Sensor, KAC and IAR images already exist in your ECR (with IRSA-backed pulls for the injector and node-IAM-role-backed pulls for EC2 components):

```bash
chmod +x eks_mixed_operator_install_exist_image.sh
./eks_mixed_operator_install_exist_image.sh
```

If you want sensor auto-update for both Node Sensor (EC2) and Container Sensor (Fargate), with images pulled directly from CrowdStrike (no ECR mirroring, no IRSA, no node IAM role ECR permissions for the Falcon repos):

```bash
chmod +x eks_mixed_operator_install_autoupdate.sh
./eks_mixed_operator_install_autoupdate.sh
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
├── README_eks_node_operator.md                  # EKS node-pools (EC2) deployment doc
├── README_eks_fargate_operator.md               # EKS Fargate-only deployment doc
├── README_eks_mixed_operator.md                 # This documentation (EKS mixed)
├── eks_node_operator_install.sh                 # EKS node-pools installer (CrowdStrike -> ECR mirror)
├── eks_node_operator_install_exist_image.sh     # EKS node-pools installer (existing ECR images)
├── eks_node_operator_install_autoupdate.sh      # EKS node-pools installer (auto-update, direct from CrowdStrike)
├── eks_fargate_operator_install.sh              # EKS Fargate installer (CrowdStrike -> ECR mirror, IRSA)
├── eks_fargate_operator_install_exist_image.sh  # EKS Fargate installer (existing ECR images + IRSA)
├── eks_fargate_operator_install_autoupdate.sh   # EKS Fargate installer (auto-update, direct from CrowdStrike, no IRSA)
├── eks_mixed_operator_install.sh                # EKS mixed installer (CrowdStrike -> ECR mirror, IRSA for injector)
├── eks_mixed_operator_install_exist_image.sh    # EKS mixed installer (existing ECR images + IRSA for injector)
├── eks_mixed_operator_install_autoupdate.sh     # EKS mixed installer (auto-update, direct from CrowdStrike, no IRSA)
├── eks_node_operator_inputs.txt                 # Config for eks_node_operator_install.sh
├── eks_node_operator_inputs_exist_image.txt     # Config for eks_node_operator_install_exist_image.sh
├── eks_node_operator_inputs_autoupdate.txt      # Config for eks_node_operator_install_autoupdate.sh
├── eks_fargate_operator_inputs.txt              # Config for eks_fargate_operator_install.sh
├── eks_fargate_operator_inputs_exist_image.txt  # Config for eks_fargate_operator_install_exist_image.sh
├── eks_fargate_operator_inputs_autoupdate.txt   # Config for eks_fargate_operator_install_autoupdate.sh
├── eks_mixed_operator_inputs.txt                # Config for eks_mixed_operator_install.sh
├── eks_mixed_operator_inputs_exist_image.txt    # Config for eks_mixed_operator_install_exist_image.sh
├── eks_mixed_operator_inputs_autoupdate.txt     # Config for eks_mixed_operator_install_autoupdate.sh
├── FalconDeploymentNode.yaml                    # Node manifest (private registry, no auto-update)
├── FalconDeploymentNodeAutoUpdate.yaml          # Node manifest with falcon_api + auto-update enabled
├── FalconDeploymentFargate.yaml                 # Fargate manifest (private registry + IRSA, no auto-update)
├── FalconDeploymentFargateAutoUpdate.yaml       # Fargate manifest with falcon_api + auto-update enabled (no IRSA)
├── FalconDeploymentMixed.yaml                   # Mixed manifest (private registry + IRSA for injector, no auto-update)
└── FalconDeploymentMixedAutoUpdate.yaml         # Mixed manifest with falcon_api + auto-update on Node + Container Sensor (no IRSA)
```

## Template Processing

> The auto-update flow (`eks_mixed_operator_install_autoupdate.sh` + `FalconDeploymentMixedAutoUpdate.yaml`) does **not** perform any `sed` substitution. The manifest is applied as-is because all image fields are unpinned and no IRSA role names are referenced.

`eks_mixed_operator_install.sh` and `eks_mixed_operator_install_exist_image.sh` use `sed` to substitute the following placeholders in the chosen mixed manifest:

| Placeholder | Replaced with |
|-------------|---------------|
| `<YOUR_AWS_ACCOUNT_ID>` | `AWS_ACCOUNT_ID` from inputs |
| `<AWS_REGIONS>` | `AWS_REGION` from inputs |
| `<YOUR_NAMESPACE>` | `IMAGE_REPO_NAMESPACE` from inputs |
| `<TAG>` (falcon-sensor line) | `eks_mixed_operator_install.sh`: latest `falcon-sensor` tag pulled from CrowdStrike registry. `eks_mixed_operator_install_exist_image.sh`: `SENSOR_IMAGE_TAG` from inputs (and the image name is rewritten from `falcon-sensor` to `SENSOR_IMAGE_NAME` if customized) |
| `<TAG>` (falcon-container line) | `eks_mixed_operator_install.sh`: latest `falcon-container` tag pulled from CrowdStrike registry. `eks_mixed_operator_install_exist_image.sh`: `CONTAINER_IMAGE_TAG` from inputs |
| `<TAG>` (falcon-kac line) | `eks_mixed_operator_install.sh`: latest `falcon-kac` tag pulled from CrowdStrike registry. `eks_mixed_operator_install_exist_image.sh`: `KAC_IMAGE_TAG` from inputs |
| `<TAG>` (falcon-imageanalyzer line) | `eks_mixed_operator_install.sh`: latest `falcon-imageanalyzer` tag pulled from CrowdStrike registry. `eks_mixed_operator_install_exist_image.sh`: `IAR_IMAGE_TAG` from inputs |
| `<FALCON_CONTAINER_INJECTOR_ROLE>` | `FALCON_INJECTOR_ROLE_NAME` from inputs |

The processed manifest is written to `/tmp/<manifest-name>_processed.yaml`, applied with `kubectl apply`, and then removed at the end of the script.

## IAM / IRSA Architecture (Mixed Cluster)

> The auto-update flow does **not** require any IAM roles or IRSA. Skip this section if you are using `eks_mixed_operator_install_autoupdate.sh`. Image pulls happen at the Kubernetes layer via a `dockerconfigjson` pull secret created by the Falcon Operator from the Falcon API credentials, which works on both EC2 and Fargate without any IAM role-arn annotations or node-IAM-role ECR permissions for the Falcon repos.

For `eks_mixed_operator_install.sh` and `eks_mixed_operator_install_exist_image.sh`, only the Falcon Container Sensor injector runs on Fargate, so only one IAM role is provisioned for IRSA. KAC and IAR run on EC2 nodes and use the node IAM role for ECR access.

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

How you update Node Sensor (DaemonSet), Container Sensor (sidecar), KAC and IAR versions depends on which install path you used:

### Auto-update (images pulled directly from CrowdStrike)

If you deployed via `eks_mixed_operator_install_autoupdate.sh` with `FalconDeploymentMixedAutoUpdate.yaml`:
- The **Node Sensor DaemonSet** auto-updates (the operator polls the CrowdStrike API every 24h by default; configurable via `--sensor-auto-update-interval` on the operator) and follows the `linux-prod` Sensor update policy.
- The **Container Sensor sidecar** auto-updates the same way and follows the same policy. New sidecars are injected at pod creation time, so existing Fargate workload pods continue running the previously injected sensor version until they are recreated. To roll forward immediately, restart the workloads (e.g. `kubectl rollout restart deployment/<name>`).
- KAC and IAR images, since they are unpinned in the manifest, are also re-resolved by the operator on reconcile.
- No manual action is required to pick up new versions.

### Private registry (manual / GitOps update)

If you deployed via `eks_mixed_operator_install.sh` or `eks_mixed_operator_install_exist_image.sh`, EC2 pods are pulling images from your ECR via the node IAM role and Fargate-scheduled injector pods are pulling via IRSA. The operator's auto-update logic is disabled (auto-update is incompatible with pinned images / private registries). Update versions by:

1. Mirroring the new Node Sensor / Container Sensor / KAC / IAR images from `registry.crowdstrike.com` into your ECR (e.g. by re-running `eks_mixed_operator_install.sh`).
2. Editing the `FalconDeployment` resource to point at the new image tags / digests:
   ```bash
   kubectl get falcondeployments
   kubectl edit falcondeployment falcon-deployment
   ```
   or by updating the manifest file and re-applying it with `kubectl apply -f`.

For larger fleets, automate this with **GitOps**: keep `FalconDeploymentMixed.yaml` in Git as the source of truth, have a CI pipeline mirror new CrowdStrike images to ECR and bump tags via PR, and have **[ArgoCD](https://argo-cd.readthedocs.io/)** or **[Flux](https://fluxcd.io/)** continuously reconcile the cluster against Git.

## Troubleshooting

If you encounter issues:

1. **Check Prerequisites**: Ensure all required tools are installed and configured
2. **Verify AWS Permissions**: Confirm permissions appropriate to the chosen script (ECR push + IAM for the non-auto-update flow; only EKS for the auto-update flow)
3. **Inspect Operator logs**:
   ```bash
   kubectl logs -n falcon-operator deploy/falcon-operator-controller-manager
   ```
4. **Inspect Component logs**: Use `kubectl logs` against pods in the component namespaces (`falcon-injector`, `falcon-kac`, `falcon-image-analyzer`, and the DaemonSet pods on each EC2 node)
5. **Verify Secret**: Confirm the `falcon-secrets` secret exists in the `falcon-secret` namespace:
   ```bash
   kubectl get secret falcon-secrets -n falcon-secret
   ```
6. **Auto-update: `update-policy linux-prod not found` error in operator logs**:
   - The Falcon `Sensor update policies` API uses an exact, **case-sensitive** match on the policy name. `linux_prod` (underscore) does not match `linux-prod` (hyphen). Confirm the exact stored name in the Falcon UI under **Host setup and management > Sensor update policies > Linux**.
   - Confirm the API client used by `falcon-secrets` has the `Sensor Update Policies: Read` scope.
   - Confirm the policy is enabled and has a sensor version assigned for the platform/architecture in use.
   - Affects BOTH the Node Sensor DaemonSet and the Container Sensor injector in this topology - both will fail to deploy if the policy is missing.
7. **IRSA / ECR pull failures (injector on Fargate, non-auto-update flow only)**: If `falcon-injector` pods stay in `ImagePullBackOff`, check:
   - The SA actually has the `eks.amazonaws.com/role-arn` annotation
   - The OIDC trust policy `sub` is `system:serviceaccount:falcon-injector:crowdstrike-falcon-sa`
   - The IAM role has `FalconContainerEcrPull` attached
   - CloudTrail shows `AssumeRoleWithWebIdentity` events
8. **ECR pull failures (KAC / IAR / Node Sensor on EC2, non-auto-update flow only)**: EC2-scheduled pods pull via the node IAM role. If they fail, verify the EC2 node IAM role has ECR pull permissions on your ECR repos
9. **CrowdStrike registry pull failures (auto-update flow only)**: If pods stay in `ImagePullBackOff`, check:
   - The Falcon API credentials in the `falcon-secrets` secret are correct and have `Falcon Images Download: Read` and `Sensor Download: Read` scopes
   - Both EC2 nodes and Fargate pods can reach `registry.crowdstrike.com` (egress / VPC endpoints / firewall rules)
   - The operator created the `dockerconfigjson` pull secret in the relevant install namespaces (`kubectl get secret -n falcon-system | grep -i pull`, `kubectl get secret -n falcon-injector | grep -i pull`)
10. **Pod scheduling issues**:
    - `falcon-injector` stuck in `Pending` -> verify a Fargate profile selects the `falcon-injector` namespace
    - `falcon-kac` / `falcon-image-analyzer` ending up on Fargate -> remove those namespaces from any Fargate profile selectors so they fall back to EC2
    - Node Sensor DaemonSet pods missing on a node -> check tolerations and the EC2 node's taints
11. **Sidecar not injected on Fargate workloads**:
    - Verify the workload namespace is covered by a Fargate profile
    - Verify the `MutatingWebhookConfiguration` is present and targets the namespace
    - The injector pod must be Running before the workload pod is created
12. **Validate Configuration**: Ensure all variables in the inputs file are correct
13. **Review manifest** (non-auto-update flow only): Inspect `/tmp/FalconDeploymentMixed*_processed.yaml` during a run to confirm substitutions

## Cleanup

```bash
# Delete the FalconDeployment (operator will tear down components)
kubectl delete falcondeployment falcon-deployment

# Uninstall the Falcon Operator
kubectl delete -f "https://github.com/crowdstrike/falcon-operator/releases/download/${FALCON_OPERATOR_VERSION}/falcon-operator.yaml"

# Delete remaining namespaces if needed
kubectl delete namespace falcon-secret falcon-injector falcon-kac falcon-image-analyzer
```

If you used `eks_mixed_operator_install.sh` or `eks_mixed_operator_install_exist_image.sh` (non-auto-update flow), also delete the IAM artifacts:

```bash
aws iam detach-role-policy --role-name "${FALCON_INJECTOR_ROLE_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
aws iam delete-role --role-name "${FALCON_INJECTOR_ROLE_NAME}"
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/FalconContainerEcrPull"
```

> The auto-update flow creates no IAM policies or roles, so no IAM cleanup is required for `eks_mixed_operator_install_autoupdate.sh`.

## Additional Resources

- [Falcon Operator (GitHub)](https://github.com/crowdstrike/falcon-operator)
- [Falcon Operator FalconDeployment samples](https://github.com/CrowdStrike/falcon-operator/tree/main/config/samples)
- [Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [Falcon Container Registry Documentation](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- [Image Assessment at Runtime Deployment Guide](https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart)
- [AWS EKS Fargate documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
- [IAM roles for service accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Plan Your Deployment](https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0)

## Important Note

> [!IMPORTANT]
> **Auto-update flow only - sidecar pull-secret propagation to namespaces created after install**
>
> For the **auto-update** sensor-version flow (`eks_mixed_operator_install_autoupdate.sh` + `FalconDeploymentMixedAutoUpdate.yaml`), where the Falcon Container Sensor sidecar is pulled directly from `registry.crowdstrike.com`, the Falcon Operator currently does **not** automatically inject the `crowdstrike-falcon-pull-secret` dockerconfigjson secret into namespaces that are created **after** the Falcon Operator install.
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
> The non-auto-update flow (`eks_mixed_operator_install.sh` and `eks_mixed_operator_install_exist_image.sh`) is **not** affected, because images are pulled from ECR via IRSA (Fargate injector) and the EC2 node IAM role (Node Sensor / KAC / IAR) - no per-namespace Kubernetes pull secret is involved.
