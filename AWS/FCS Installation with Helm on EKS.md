# Falcon Platform Helm Install Notes

## Documentation links

- Retrieve images from CrowdStrike registry - https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry
- Deploy falcon platform - https://falcon.crowdstrike.com/documentation/page/t6y7u8i9o/deploy-the-falcon-platform

## General steps

### 1. Generate API client and secret with required permissions

Go to Support and resources > Resources and tools > API clients and keys

Required permissions for sensor, container, KAC and IAR are described at https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c

- Falcon Images Download (read)
- Sensor Download (read)
- Falcon Container CLI (Read/Write)
- Falcon Container Image (Read/Write)

The last 2 permissions above are needed for IAR - https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart#b592fe49

### 2. Get Falcon CID with Checksum

Get it either from portal Host setup and management > Deploy > Sensor downloads or via:

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  --get-cid
```

### 3. Prerequisites

- K8S should be running supported OS and kernel for both kernel and user mode
- Have Internet access for the sensors to call back to CRWD cloud

### 4. Check the support matrix

https://falcon.crowdstrike.com/documentation/page/aa4fccee/container-security#te0091b4

See table at section "Falcon sensor deployment options in container environments". Note there are 4 modes:

**DaemonSet Kernel mode**
The Falcon sensor for Linux deployed as a DaemonSet running in kernel mode, v6.35 and later.

**DaemonSet User mode**
The Falcon sensor for Linux running in user mode (eBPF), v6.49 and later.

**Container sensor**
The Falcon Container sensor for Linux, all versions.

**Standard**
The Falcon sensor for Linux installed directly on the host.

### 5. Check the linux supported kernels

- For kernel mode - see https://falcon.crowdstrike.com/documentation/page/cefbaf45/linux-supported-kernels
- For user mode - see https://falcon.crowdstrike.com/documentation/page/edd7717e/falcon-sensor-for-linux-system-requirements#nc904783

### 6. Private container image registry

Private container image registry to store the downloaded images from CRWD registry. K8S should have access to this private container registry

### 7. For EKS Fargate

Make sure you have a Fargate profile that matches the namespaces of the components to allow them to be created in Fargate compute, namely:

- falcon-system
- falcon-kac
- falcon-image-analyzer

Referring to https://docs.aws.amazon.com/eks/latest/userguide/fargate-getting-started.html#fargate-gs-coredns, you may want to have coredns pods running on fargate too, but this is normally the job of k8s admin

Restart the following deployments so that they end up in fargate:

```bash
kubectl rollout restart -n kube-system deployment coredns
kubectl rollout restart -n external-dns deployment external-dns
```

### 8. Sidecar sensor deployment

When you use sidecar sensor deployment, existing pods will not have the sidecar container auto-injected, only new pods. You have to redeploy existing pods for the sidecar container to be added

### 9. IAR modes

There are 2 modes for IAR - see https://falcon.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart#s397745a

**Watcher mode** - IAR runs as a single pod via k8s deployment. Require image pull permissions
**Socket mode** - IAR runs as a daemonset (hence not suitable for fargate which does not support daemonset), does not require image pull permissions

## Environment variables

```bash
#!/bin/bash
export FALCON_CLIENT_ID="<FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<FALCON_CLIENT_SECRET>"
export FALCON_CID="<CUSTOMER_ID>"
export FALCON_IMAGE_PULL_TOKEN="<FALCON_IMAGE_PULL_TOKEN>"

## for sensor as daemonset
export SENSOR_IMAGE_TAG="7.33.0-18606-1"
export SENSOR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<NAMESPACE>/falcon-sensor"

## for sensor as sidecar
export SENSOR_IMAGE_TAG="7.33.0-7205"
export SENSOR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<NAMESPACE>/falcon-container"

export KAC_IMAGE_TAG="7.33.0-3105"
export KAC_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<NAMESPACE>/falcon-kac"

export IAR_IMAGE_TAG="1.0.22"
export IAR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<NAMESPACE>/falcon-imageanalyzer"

export CLUSTER_NAME="<CLUSTER_NAME>"
```

## Authenticate to ECR and get config.json in docker directory as environment

```bash
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com

export ENCODED_DOCKER_CONFIG=$(base64 -w 0 ~/.docker/config.json)
```

## Copy from CrowdStrike registry and push to local ECR

The ECR needs to have the repositories created in the format `<namespace>/<registry-name>`

In the below, you need to pre-create the following repositories in ECR: `<namespace>/falcon-sensor`, `<namespace>/falcon-kac`, `<namespace>/falcon-imageanalyzer`, `<namespace>/falcon-container`

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/<namespace>"
```

## Get kubeconfig file of EKS cluster

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name <CLUSTER_NAME>
```

## Deploy sensor in daemonset, KAC and IAR with namespace creation

```bash
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --create-namespace \
  --set createComponentNamespaces=true \
  --set global.falcon.cid=$FALCON_CID \
  --set global.containerRegistry.configJSON=$ENCODED_DOCKER_CONFIG \
  --set falcon-sensor.enabled=true \
  --set falcon-sensor.node.image.repository=$SENSOR_REGISTRY \
  --set falcon-sensor.node.image.tag=$SENSOR_IMAGE_TAG \
  --set falcon-kac.enabled=true \
  --set falcon-kac.image.repository=$KAC_REGISTRY \
  --set falcon-kac.image.tag=$KAC_IMAGE_TAG \
  --set falcon-image-analyzer.enabled=true \
  --set falcon-image-analyzer.deployment.enabled=true \
  --set falcon-image-analyzer.image.repository=$IAR_REGISTRY \
  --set falcon-image-analyzer.image.tag=$IAR_IMAGE_TAG \
  --set falcon-image-analyzer.crowdstrikeConfig.clusterName=$CLUSTER_NAME \
  --set falcon-image-analyzer.crowdstrikeConfig.clientID=$FALCON_CLIENT_ID \
  --set falcon-image-analyzer.crowdstrikeConfig.clientSecret=$FALCON_CLIENT_SECRET
```

## Deploy sensor as sidecar, KAC and IAR with namespace creation

```bash
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --create-namespace \
  --set createComponentNamespaces=true \
  --set global.falcon.cid=$FALCON_CID \
  --set global.containerRegistry.configJSON=$ENCODED_DOCKER_CONFIG \
  --set falcon-sensor.enabled=true \
  --set falcon-sensor.node.enabled=false \
  --set falcon-sensor.container.enabled=true \
  --set falcon-sensor.container.image.repository=$SENSOR_REGISTRY \
  --set falcon-sensor.container.image.tag=$SENSOR_IMAGE_TAG \
  --set falcon-sensor.container.image.pullSecrets.enable=true \
  --set falcon-sensor.container.image.pullSecrets.allNamespaces=true \
  --set falcon-kac.enabled=true \
  --set falcon-kac.image.repository=$KAC_REGISTRY \
  --set falcon-kac.image.tag=$KAC_IMAGE_TAG \
  --set falcon-image-analyzer.enabled=true \
  --set falcon-image-analyzer.deployment.enabled=true \
  --set falcon-image-analyzer.image.repository=$IAR_REGISTRY \
  --set falcon-image-analyzer.image.tag=$IAR_IMAGE_TAG \
  --set falcon-image-analyzer.crowdstrikeConfig.clusterName=$CLUSTER_NAME \
  --set falcon-image-analyzer.crowdstrikeConfig.clientID=$FALCON_CLIENT_ID \
  --set falcon-image-analyzer.crowdstrikeConfig.clientSecret=$FALCON_CLIENT_SECRET
```

## To uninstall

```bash
helm uninstall falcon-platform --namespace falcon-platform
```

## Run detections container in k8s

```bash
kubectl create -f https://raw.githubusercontent.com/CrowdStrike/detection-container/main/detections.example.yaml
```

Then start a shell in the pod, and then go to `/home/menu/` and do `./run` to bring up the interactive menu

## Notes for IAR

- Container image must be Docker manifest version 2, schema version 2 or OCI image version 1+ to be supported by IAR

**Docker image manifest version 2, schema version 2:**
media type: `application/vnd.docker.distribution.manifest.v2+json`

**OCI image manifest:**
media type: `application/vnd.oci.image.manifest.v1+json`

- Run the following to check:

```bash
docker manifest inspect <image:tag>
```