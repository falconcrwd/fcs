## Pre-requisites:
- existing EKS cluster that has access to ECR or private registry that stores CRWD container images
- The EKS cluster that runs Falcon Operator needs to have the IAM OIDC provider installed - see [here](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html). To install IAM OIDC on the cluster if it is not already installed, run this command after logging in via AWS CLI
```bash
eksctl utils associate-iam-oidc-provider --region "<YOUR_AWS_REGION>" --cluster "<YOUR_EKS_CLUSTER_NAME>" --approve
```

- CRWD components installed on EKS cluster (sensor, KAC, IAR) need to access Internet to send metrics to CRWD cloud
- Falcon Administrator on Falcon portal
- Linux host with access to EKS cluster and Internet, with **jq**, **curl** and **Docker** installed

## Step 1 - Create API client key and secret

On portal, go to:
Support and resources > Resources and tools > API clients and keys and create an API client key and secret with the below scopes:
- Falcon Images Download (read)
- Sensor Download (read)
- Falcon Container Image (Read/Write)
- Falcon Container CLI (Read/Write)

Export the client id and secret into environment
```bash
export FALCON_CLIENT_ID="<YOUR_FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<YOUR_FALCON_CLIENT_SECRET>"
```

## Step 2 - Get your Falcon CID with checksum

On the portal, go to Host setup and management > Deploy > Sensor downloads and copy your CID with checksum

Export to environment variable
```bash
export FALCON_CID="<YOUR_FALCON_CID_CHECKSUM>"
```


## Step 3 - Download Falcon pull script and copy container images from CRWD registry to ECR

Here it is assume that AWS ECR is used. For other private registries, please authenticate to the registry using its supported authentication method

Download pull script and change its permissions to be executable
```bash
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"

chmod +x falcon-container-sensor-pull.sh
```

Authenticate to ECR, assumes that you have logged into AWS CLI already via **aws configure** 
```bash
aws ecr get-login-password --region <YOUR_REGION> | docker login --username AWS --password-stdin <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com
```

In your ECR, create the respective namespaces for the images, for example - falcon-sensor, falcon-kac and falcon-imageanalzyer before proceeding to the next step

**Copy Falcon sensor**
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  -c <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-sensor
```

**Copy Falcon KAC**
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  -c <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-kac
```

**Copy Falcon Image Assessment Runtime**
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  -c <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-imageanalyzer
```

Verify that the images are successfully copied to ECR


## Step 4 - install the Falcon Operator

Installing v1.12.0 of the Falcon Operator which is latest as of 12 March 2026
```bash
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/v1.12.0/falcon-operator.yaml
```

## Step 5 - Edit the deployment manifest

You can update the example deployment manifest below, which deploys the FalconAdmission, FalconImageAnalyzer, and the FalconNodeSensor using their default component configurations and pulls images from ECR

The default deployment manifest for Node sensor from [here](https://github.com/CrowdStrike/falcon-operator/blob/main/config/samples/falcon_v1alpha1_falcondeployment-node-sensor.yaml)

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
      image: <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-sensor/falcon-sensor:<TAG>
      tolerations:
        - effect: NoSchedule
          operator: Equal
          key: CriticalAddonsOnly
          value: NoSchedule      
  falconImageAnalyzer:
    image: <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-imageanalyzer/falcon-imageanalyzer:<TAG>
  falconAdmission:
    image: <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_REGION>.amazonaws.com/falcon-kac/falcon-kac:<TAG>		
```

## Step 6 - deploy the manifest and verify the deployment

Deploy the manifest
```bash
kubectl create -f <YOUR_MANIFEST_NAME.yaml>
```

Verify the deployment
```bash
kubectl get deployments -n falcon-operator
kubectl get pods -n falcon-operator
kubectl get pods -n falcon-operator | grep falconadmission
kubectl get pods -n falcon-operator | grep falconnodesensor
kubectl get pods -n falcon-operator | grep falconimageanalyzer
```

## Step 7 - Verify on Falcon Platform

Go to Cloud Security > Assets > Kubernetes and container inventory and you should see the EKS cluster with **KAC sensor ID** assigned, **KAC agent status** and **Cluster status** as active and **Management** status as Managed





## Relevant documentation:
- https://falcon.us-2.crowdstrike.com/documentation/page/a0cf9976/deploy-image-assessment-at-runtime-with-a-helm-chart
- https://falcon.us-2.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry#zccd8f5c
- https://falcon.us-2.crowdstrike.com/documentation/page/g1b34bd0/plan-your-deployment-0
- https://github.com/CrowdStrike/falcon-helm
- https://github.com/crowdstrike/falcon-operator
