# Falcon Operator Installation on GKE Autopilot

## GCloud CSPM Onboarding

Auto-generated client ID and secret:
- Client ID: `<FALCON_CLIENT_ID>`
- Client Secret: `<FALCON_CLIENT_SECRET>`

```bash
curl -L https://raw.githubusercontent.com/CrowdStrike/terraform-google-cloud-registration/main/scripts/service-account-setup.sh -o service-account-setup.sh

chmod +x service-account-setup.sh

./service-account-setup.sh --name crowdstrike-sa --project-ids "<PROJECT_ID_1>,<PROJECT_ID_2>" --infra-project-id <INFRA_PROJECT_ID> --wif-project-id <WIF_PROJECT_ID> --enable-rtvd --location us-central1

export SERVICE_ACCOUNT_ID="projects/<INFRA_PROJECT_ID>/serviceAccounts/crowdstrike-sa@<INFRA_PROJECT_ID>.iam.gserviceaccount.com"

export TF_VAR_falcon_client_secret=<FALCON_CLIENT_SECRET>

echo -n "$TF_VAR_falcon_client_secret" | gcloud secrets create "falcon-client-secret-<REGISTRATION_ID>" --project="<INFRA_PROJECT_ID>" --data-file=- 2>/dev/null || \
  echo -n "$TF_VAR_falcon_client_secret" | gcloud secrets versions add "falcon-client-secret-<REGISTRATION_ID>" --project="<INFRA_PROJECT_ID>" --data-file=-

```bash
cat > terraform.tfvars <<EOF
falcon_client_id              = "<FALCON_CLIENT_ID>"
falcon_client_secret_name     = "falcon-client-secret-<REGISTRATION_ID>"
registration_id               = "<REGISTRATION_ID>"
registration_name             = "<REGISTRATION_NAME>"
registration_type             = "project"
deployment_method             = "infrastructure-manager"
infrastructure_manager_region = "asia-southeast1"
project_ids                   = ["<PROJECT_ID_1>","<PROJECT_ID_2>"]
infra_project_id              = "<INFRA_PROJECT_ID>"
wif_project_id                = "<WIF_PROJECT_ID>"
role_arn                      = "arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/CrowdStrikeCSPMConnector"
enable_realtime_visibility    = true
resource_prefix               = ""
resource_suffix               = ""
labels = {
  cstag-department = "<DEPARTMENT>"
  cstag-owner = "<OWNER>"
  cstag-purpose = "<PURPOSE>"
  cstag-user = "<USER>"
  cstag-accounting = "<ACCOUNTING>"
  cstag-business = "<BUSINESS>"
}
EOF

gcloud infra-manager deployments apply cs-<REGISTRATION_ID> \
  --project="<INFRA_PROJECT_ID>" \
  --location=asia-southeast1 \
  --service-account="${SERVICE_ACCOUNT_ID}" \
  --git-source-repo="https://github.com/CrowdStrike/terraform-google-cloud-registration" \
  --git-source-directory="examples/infrastructure-manager" \
  --inputs-file="terraform.tfvars"

rm -f terraform.tfvars
```

## GCloud CLI Basics

```bash
gcloud auth login

gcloud auth list

gcloud config set project <PROJECT_NAME>

gcloud container clusters get-credentials CLUSTER_NAME \
    --location=CONTROL_PLANE_LOCATION
```


## Falcon Operator Installation Using CrowdStrike Image Registry

This approach assumes pulling directly from the CrowdStrike registry and using GKE Autopilot mode.

### Step 1: Install Falcon Operator

```bash
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/v1.11.0/falcon-operator.yaml
```

### Step 2: Create AllowlistSynchronizer

Create `allowlist-synchronizer.yaml` to allow sensor daemonset to run as privileged containers:

```yaml
apiVersion: auto.gke.io/v1
kind: AllowlistSynchronizer
metadata:
  name: crowdstrike-synchronizer
spec:
  allowlistPaths:
  - CrowdStrike/falcon-sensor/*
```

### Step 3: Deploy Falcon Components

```bash
kubectl create -f https://raw.githubusercontent.com/crowdstrike/falcon-operator/refs/tags/v1.11.0/config/samples/falcon_v1alpha1_falcondeployment-node-sensor.yaml --edit=true
```

You can also use the following deployment YAML manifest:

```bash
kubectl create -f <filename.yaml>
```

Sample YAML deployment file for GKE Autopilot:

```yaml
apiVersion: falcon.crowdstrike.com/v1alpha1
kind: FalconDeployment
metadata:
  labels:
    crowdstrike.com/component: sample
    crowdstrike.com/created-by: falcon-operator
    crowdstrike.com/instance: falcondeployment-sample
    crowdstrike.com/managed-by: kustomize
    crowdstrike.com/name: falcon-deployment
    crowdstrike.com/part-of: Falcon
    crowdstrike.com/provider: crowdstrike
  name: falcon-deployment
spec:
  falcon_api:
    client_id: <FALCON_CLIENT_ID>
    client_secret: <FALCON_CLIENT_SECRET>
    cloud_region: autodiscover
  deployAdmissionController: true
  deployNodeSensor: true
  deployImageAnalyzer: true
  deployContainerSensor: false
  falconNodeSensor:
    node:
      backend: bpf
      gke:
        autopilot: true
      tolerations:
        - effect: NoSchedule
          operator: Equal
          key: kubernetes.io/arch
          value: amd64
```

### References

- [Quickstart: Falcon Operator Deployment](https://falcon.crowdstrike.com/documentation/page/p60ce227/quickstart-falcon-operator-deployment#i3b9f0a8)
- [Platform-Specific Configuration Options](https://falcon.crowdstrike.com/documentation/page/vaed8b6d/platform-specific-configuration-options#oa491d1f)

## Falcon Operator Installation Using Private Image Registry

**UPDATE:** There seems to be an issue using private image registry with GKE Autopilot. See [Slack thread](https://crowdstrike.slack.com/archives/C062FGXL7QR/p1749448966977329) for details.

### Authenticate to Google Image Registry

From Cloud Shell, authenticate to the Google image registry:

```bash
gcloud auth configure-docker <REGION>-docker.pkg.dev
```

### Pull Images from CrowdStrike Registry to Google Image Registry

You may want to check the latest versions of the node sensor, container sensor, KAC, and IAR before copying.

**For Falcon Node Sensor:**

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  --get-image-path

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  --version 7.33.0-18606-1 \
  -c "<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>"
```

**For Falcon KAC:**

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  --get-image-path

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  --version 7.33.0-3105 \
  -c "<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>"
```

**For Falcon IAR:**

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  --get-image-path

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  --version 1.0.23 \
  -c "<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>"
```

**For Falcon Container Sensor:**

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  --get-image-path

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  --version 7.33.0-7205 \
  -c "<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>"
```

### Deploy Using Custom Images

Use the following YAML file as a sample:

```bash
kubectl create -f https://raw.githubusercontent.com/crowdstrike/falcon-operator/refs/tags/v1.11.0/config/samples/falcon_v1alpha1_falcondeployment-node-sensor.yaml --edit=true
```

Or save the manifest below and apply it:

```bash
kubectl create -f <deployment.yaml>
```

Sample `deployment.yaml`:

```yaml
apiVersion: falcon.crowdstrike.com/v1alpha1
kind: FalconDeployment
metadata:
  labels:
    crowdstrike.com/component: sample
    crowdstrike.com/created-by: falcon-operator
    crowdstrike.com/instance: falcondeployment-sample
    crowdstrike.com/managed-by: kustomize
    crowdstrike.com/name: falcon-deployment
    crowdstrike.com/part-of: Falcon
    crowdstrike.com/provider: crowdstrike
  name: falcon-deployment
spec:
  falcon_api:
    client_id: <FALCON_CLIENT_ID>
    client_secret: <FALCON_CLIENT_SECRET>
    cloud_region: autodiscover
  deployAdmissionController: true
  deployNodeSensor: true
  deployImageAnalyzer: true
  deployContainerSensor: false
  falconNodeSensor:
    node:
      image: <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-sensor:7.33.0-18606-1
      imagePullPolicy: IfNotPresent
      backend: bpf
      gke:
        autopilot: true
      tolerations:
        - effect: NoSchedule
          operator: Equal
          key: kubernetes.io/arch
          value: amd64
  falconImageAnalyzer:
    image: <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-imageanalyzer:1.0.23
  falconAdmission:
    image: <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-kac:7.33.0-3105
```

## Important Notes

- [Google Container Registry Documentation](https://docs.cloud.google.com/artifact-registry/docs/docker/store-docker-container-images?authuser=1)
- Make sure you create AllowlistSynchronizer first, otherwise the sensor daemonset will not deploy

### Known Issues

The sensor may fail to deploy due to GKE Warden constraints. Common error messages include:

```
registry.crowdstrike.com/falcon-sensor/us-1/release/falcon-sensor:7.33.0-18606-1
Failed to create new DaemonSet: admission webhook "warden-validating.common-webhooks.networking.gke.io" denied the request: GKE Warden rejected the request because it violates one or more constraints.

Violation details:
- Linux capability 'SYS_ADMIN,DAC_READ_SEARCH,BPF,PERFMON,SYS_RESOURCE,NET_ADMIN' on container 'falcon-node-sensor' not allowed
- Autopilot only allows specific capabilities: 'AUDIT_WRITE,CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,MKNOD,NET_BIND_SERVICE,NET_RAW,SETFCAP,SETGID,SETPCAP,SETUID,SYS_CHROOT,SYS_PTRACE'
- Enabling hostIPC, hostNetwork, and hostPID is not allowed in Autopilot
- Privileged containers are not allowed in Autopilot
- HostPath volumes in write mode are disallowed in Autopilot
```