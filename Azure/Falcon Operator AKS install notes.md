# Azure AKS Deployment Scenario

- Normal AKS cluster with user-configured node pools
- Pull images direct from CRWD registry Option 1
- Pull images from ACR option 2

## Option 1 - AKS cluster with sensor daemonset, KAC, IAR and pull images direct from CRWD registry

### Step 1 - Install Falcon Operator
The version used in the command below is v1.11.0 please check the latest version of Falcon Operator at https://github.com/CrowdStrike/falcon-operator and update accordingly
```bash
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/v1.11.0/falcon-operator.yaml
```

### Step 2 - Edit the deployment manifest and deploy

```bash
kubectl create -f https://raw.githubusercontent.com/crowdstrike/falcon-operator/refs/tags/v1.11.0/config/samples/falcon_v1alpha1_falcondeployment-node-sensor.yaml --edit=true
```

You can also use the below deployment yaml manifest and run the below command. It will deploy sensor daemonset, KAC and IAR using default settings:

```bash
kubectl create -f <filename.yaml>
```

Sample yaml deployment file for AKS using CRWD registry - sensor daemonset, KAC and IAR:

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
```

## Option 2 - AKS cluster with sensor daemonset, KAC, IAR and pull CRWD images from ACR

- Assumes AKS has been created with ACR registry at the same time

### Step 1 - Get CRWD images into ACR

Authenticate to ACR via cloud shell, then push images to it

1. Ensure role has ACR push permissions

2. Enable admin access on ACR - Settings > Access Keys

3. Run the following:

```bash
docker login <myregistry.azurecr.io> -u <username> -p <password>
```

For instructions on how to copy images from CRWD registry to ACR on Azure cloud shell - check out this article "Log into ACR on Cloudshell and copy images.md"

4. Get image version, then copy to registry

**For Falcon node sensor**

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
  -c <REGISTRY_NAME>.azurecr.io
```

**For Falcon KAC**

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
  -c <REGISTRY_NAME>.azurecr.io
```

**For Falcon IAR**

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
  -c <REGISTRY_NAME>.azurecr.io
```

**For Falcon Container Sensor**

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
  -c <REGISTRY_NAME>.azurecr.io
```

### Step 2 - Install Falcon Operator

```bash
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/v1.11.0/falcon-operator.yaml
```

### Step 3 - Deploy

```bash
kubectl create -f <mysample.yaml>
```

Sample yaml deployment file for AKS using ACR registry - sensor daemonset, KAC and IAR:

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
      image: <REGISTRY_NAME>.azurecr.io/falcon-sensor:7.33.0-18606-1
      imagePullPolicy: IfNotPresent
  falconImageAnalyzer:
    image: <REGISTRY_NAME>.azurecr.io/falcon-imageanalyzer:1.0.23
  falconAdmission:
    image: <REGISTRY_NAME>.azurecr.io/falcon-kac:7.33.0-3105
```

## Upgrade the image versions

To upgrade the image versions, you first need to ensure that the new container images are already present in your registry

Then you edit the CRD for FalconDeployment directly, changing the image tags that you see in the manifest to the right ones

```bash
kubectl get FalconDeployment -A
NAME                OPERATOR VERSION   FALCON SENSOR
falcon-deployment   1.11.0
```

```bash
kubectl edit FalconDeployment falcon-deployment
falcondeployment.falcon.crowdstrike.com/falcon-deployment edited
```