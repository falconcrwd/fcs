# Falcon Platform Helm Install Notes

## Documentation links

- Retrieve images from CrowdStrike registry - https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry
- Deploy falcon platform - https://falcon.crowdstrike.com/documentation/page/t6y7u8i9o/deploy-the-falcon-platform

## General steps

### If you are running Helm from AWS cloudshell, first install helm
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```


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

You can also use a Fargate profile with a wildcard `*` to match any namespace to support the FCS components.

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

**Watcher mode** - IAR runs as a single pod via k8s deployment. Require image pull permissions. Recommended

**Socket mode** - IAR runs as a daemonset (hence not suitable for fargate which does not support daemonset), does not require image pull permissions

## Environment variables
Replace the image tag version below with the right ones that you plan to use. You can use this document [Using Skopeo container for image copy](../Misc/Using%20Skopeo%20container%20for%20image%20copy.md) to find the list of image tags available for each image.

```bash
#!/bin/bash
export FALCON_CLIENT_ID="<FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<FALCON_CLIENT_SECRET>"
export FALCON_CID="<CUSTOMER_ID_CHECKSUM>"

## for sensor as daemonset
export SENSOR_IMAGE_TAG="7.33.0-18606-1"
export SENSOR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<NAMESPACE>/falcon-sensor"

## for sensor as sidecar
export SENSOR_IMAGE_TAG="7.33.0-7205"
export SENSOR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<NAMESPACE>/falcon-container"

export KAC_IMAGE_TAG="7.33.0-3105"
export KAC_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<NAMESPACE>/falcon-kac"

export IAR_IMAGE_TAG="1.0.22"
export IAR_REGISTRY="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<NAMESPACE>/falcon-imageanalyzer"

export CLUSTER_NAME="<CLUSTER_NAME>"

export FALCON_SECRET_NAME=<your-falcon-secret-name>
```

## Authenticate to ECR and get config.json in docker directory as environment

```bash
aws ecr get-login-password --region <AWS_REGION> | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com

export ENCODED_DOCKER_CONFIG=$(base64 -w 0 ~/.docker/config.json)
```

## Copy from CrowdStrike registry and push to local ECR

The ECR needs to have the repositories created in the format `<namespace>/<registry-name>`

In the below, you need to pre-create the following repositories in ECR: `<namespace>/falcon-sensor`, `<namespace>/falcon-kac`, `<namespace>/falcon-imageanalyzer`, `<namespace>/falcon-container`

The below commands will copy the latest image for the various FCS components from CRWD registry to ECR. If you want to specify a specific version, use the `--version <VERSION>`flag

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<namespace>"

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  -c "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<namespace>"
```

## Get kubeconfig file of EKS cluster

```bash
aws eks update-kubeconfig --region <AWS_REGION> --name <CLUSTER_NAME>
```

## ONLY IF YOU USE K8S SECRETS FOR FALCON PARAMETERS - Here we assume you are going to create k8s secrets for the Helm deployment, therefore the namespaces need to be manually created
```bash
kubectl create namespace falcon-system
kubectl create namespace falcon-kac
kubectl create namespace falcon-image-analyzer
```

## ONLY IF YOU USE K8S SECRETS FOR FALCON PARAMETERS - create the required secrets for each component in the respective namespace
```bash
kubectl create secret generic $FALCON_SECRET_NAME -n falcon-system --from-literal=FALCONCTL_OPT_CID=$FALCON_CID

kubectl create secret generic $FALCON_SECRET_NAME -n falcon-kac --from-literal=FALCONCTL_OPT_CID=$FALCON_CID

kubectl create secret generic $FALCON_SECRET_NAME -n falcon-image-analyzer --from-literal=AGENT_CLIENT_ID=$FALCON_CLIENT_ID --from-literal=AGENT_CLIENT_SECRET=$FALCON_CLIENT_SECRET
```

## Deploy sensor in daemonset, KAC and IAR with K8S secrets for FALCON_CLIENT_ID, FALCON_CLIENT_SECRET, FALCON_CID and with tolerations for system node pool
**Be careful of trailing spaces after backslash, there should not be any**

The 3rd item in the array **falcon-sensor.node.daemonset.tolerations[3]** is what allows the sensor daemonset to tolerate the taint on system node and deploy onto it

```bash
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --set global.falconSecret.enabled=true \
  --set global.falconSecret.secretName=$FALCON_SECRET_NAME \
  --set global.containerRegistry.configJSON=$ENCODED_DOCKER_CONFIG \
  --set falcon-sensor.enabled=true \
  --set falcon-sensor.node.image.repository=$SENSOR_REGISTRY \
  --set falcon-sensor.node.image.tag=$SENSOR_IMAGE_TAG \
  --set "falcon-sensor.node.daemonset.tolerations[0].key=node-role.kubernetes.io/master" \
  --set "falcon-sensor.node.daemonset.tolerations[0].operator=Exists" \
  --set "falcon-sensor.node.daemonset.tolerations[0].effect=NoSchedule" \
  --set "falcon-sensor.node.daemonset.tolerations[1].key=node-role.kubernetes.io/control-plane" \
  --set "falcon-sensor.node.daemonset.tolerations[1].operator=Exists" \
  --set "falcon-sensor.node.daemonset.tolerations[1].effect=NoSchedule" \
  --set "falcon-sensor.node.daemonset.tolerations[2].key=kubernetes.azure.com/scalesetpriority" \
  --set "falcon-sensor.node.daemonset.tolerations[2].operator=Equal" \
  --set "falcon-sensor.node.daemonset.tolerations[2].value=spot" \
  --set "falcon-sensor.node.daemonset.tolerations[2].effect=NoSchedule" \
  --set "falcon-sensor.node.daemonset.tolerations[3].key=CriticalAddonsOnly" \
  --set "falcon-sensor.node.daemonset.tolerations[3].operator=Exists" \
  --set "falcon-sensor.node.daemonset.tolerations[3].effect=NoSchedule" \
  --set falcon-kac.enabled=true \
  --set falcon-kac.image.repository=$KAC_REGISTRY \
  --set falcon-kac.image.tag=$KAC_IMAGE_TAG \
  --set falcon-image-analyzer.enabled=true \
  --set falcon-image-analyzer.deployment.enabled=true \
  --set falcon-image-analyzer.image.repository=$IAR_REGISTRY \
  --set falcon-image-analyzer.image.tag=$IAR_IMAGE_TAG \
  --set falcon-image-analyzer.crowdstrikeConfig.clusterName=$CLUSTER_NAME \
  --set falcon-image-analyzer.crowdstrikeConfig.cid=$FALCON_CID
```



## Deploy sensor in daemonset, KAC and IAR with namespace creation - without k8s secrets for FALCON_CLIENT_ID, FALCON_CLIENT_SECRET, FALCON_CID

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

## Deploy sensor as sidecar, KAC and IAR with namespace creation - without k8s secrets for FALCON_CLIENT_ID, FALCON_CLIENT_SECRET, FALCON_CID

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
Uninstall the helm chart, and then remove the namespace
```bash
helm uninstall falcon-platform --namespace falcon-platform
kubectl delete ns falcon-platform
```

## Run detections container in k8s
If you want to simulate detections, you can run a CRWD provided detections container
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