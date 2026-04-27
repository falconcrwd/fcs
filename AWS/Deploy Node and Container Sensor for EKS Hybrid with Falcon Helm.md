# Deploy Node and Container Sensor for EKS Hybrid

This document provides instructions for deploying CrowdStrike Falcon sensors on Amazon EKS clusters with both managed nodes and Fargate, using Helm Charts.

## Prerequisites
- you have already downloaded the node-sensor, container-sensor, KAC and IAR images into ECR. If not follow the instructions [here](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- you have the required permissions and licenses

### AWS Authentication

```bash
# Configure AWS SSO
aws configure sso --use-device-code

# Verify identity
aws sts get-caller-identity --profile YOUR_PROFILE_NAME

# Update kubeconfig for EKS cluster
aws eks update-kubeconfig --profile YOUR_PROFILE_NAME --region YOUR_REGION --name YOUR_CLUSTER_NAME
```

### Test Namespace Setup
```bash
# Create namespace that is must be matched by Fargate profile
kubectl create ns project1
kubectl create deployment httpd-deploy --image=httpd:latest --replicas=2 -n project1
```

### ECR Authentication

```bash
# Login to ECR
aws ecr get-login-password --profile YOUR_PROFILE_NAME --region YOUR_REGION | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com

# For macOS - encode Docker config:
export ENCODED_DOCKER_CONFIG=$(base64 -i ~/.docker/config.json)

# For Linux:
export ENCODED_DOCKER_CONFIG=$(base64 -w 0 ~/.docker/config.json)
```

## Environment Variables

Set the following environment variables with your specific values:

```bash
# CrowdStrike Configuration
export FALCON_CID="YOUR_CID_HERE"
export FALCON_CLIENT_ID="YOUR_CLIENT_ID_HERE"
export FALCON_CLIENT_SECRET="YOUR_CLIENT_SECRET_HERE"
export FALCON_SECRET_NAME=falcon-secrets

# Image versions and registries replace the tags with right values
export SENSOR_IMAGE_TAG="7.35.0-18803-1"
export SENSOR_REGISTRY="YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/crwd/falcon-sensor"

export CONTAINER_SENSOR_IMAGE_TAG="7.36.0-7502"
export CONTAINER_SENSOR_REGISTRY="YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/crwd/falcon-container"

export KAC_IMAGE_TAG="7.36.0-3401"
export KAC_REGISTRY="YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/crwd/falcon-kac"

export IAR_IMAGE_TAG="1.0.24"
export IAR_REGISTRY="YOUR_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/crwd/falcon-imageanalyzer"

export CLUSTER_NAME="YOUR_CLUSTER_NAME"
```

## Create Namespaces

```bash
kubectl create namespace falcon-system
kubectl create namespace falcon-kac
kubectl create namespace falcon-image-analyzer
```

## Create Secrets

```bash
kubectl create secret generic $FALCON_SECRET_NAME -n falcon-system --from-literal=FALCONCTL_OPT_CID=$FALCON_CID
kubectl create secret generic $FALCON_SECRET_NAME -n falcon-kac --from-literal=FALCONCTL_OPT_CID=$FALCON_CID
kubectl create secret generic $FALCON_SECRET_NAME -n falcon-image-analyzer --from-literal=AGENT_CLIENT_ID=$FALCON_CLIENT_ID --from-literal=AGENT_CLIENT_SECRET=$FALCON_CLIENT_SECRET
```

## Install Falcon Platform Components

Install IAR, KAC and Node Sensor using platform helm chart for the regular node pools including the system node pool with taint toleration

```bash
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --create-namespace \
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

## Fargate Configuration

### Enable Pod Injection

Label the namespace that requires pod injection, this has to be repeated for each namespace in Fargate profile that needs pod injection:

```bash
kubectl label namespace project1 sensor.falcon-system.crowdstrike.com/injection=enabled
```

### ECR Permissions for Fargate (KAC and IAR)

> **Note:** If KAC and injector pod are running on Fargate, follow the instructions at [Platform-specific Configuration Options](https://falcon.crowdstrike.com/documentation/page/vaed8b6d/platform-specific-configuration-options#u01c0b5c) to give KAC and injector pod the required permissions in a ServiceAccount to pull images from private registry. When running on managed nodes (EC2), they will use the EC2 role automatically.

The EKS cluster using KAC and injector pod on Fargate must have an IAM OIDC provider installed. The OIDC provider creates a trust relationship between your EKS cluster and AWS IAM, allowing Kubernetes service accounts to assume IAM roles.

#### Associate IAM OIDC Provider

```bash
export AWS_REGION="YOUR_REGION"

eksctl utils associate-iam-oidc-provider \
  --profile YOUR_PROFILE_NAME \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER_NAME" \
  --approve
```

#### Create IAM Policy for ECR Access

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile YOUR_PROFILE_NAME --query Account --output text)
iam_policy_name="FalconContainerEcrPull"
iam_policy_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${iam_policy_name}"

cat <<__END__ > policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowImagePull",
            "Effect": "Allow",
            "Action": [
                "ecr:BatchGetImage",
                "ecr:DescribeImages",
                "ecr:GetDownloadUrlForLayer",
                "ecr:ListImages"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowECRSetup",
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken"
            ],
            "Resource": "*"
        }
    ]
}
__END__

# Create IAM policy with ECR permissions
aws iam create-policy \
  --profile YOUR_PROFILE_NAME \
  --region "$AWS_REGION" \
  --policy-name ${iam_policy_name} \
  --policy-document 'file://policy.json' \
  --description "Policy to enable Falcon Container Injector or KAC to pull container image from ECR"
```

#### Create IAM Service Account

```bash
# Create IAM role with the policy containing ECR permissions
eksctl create iamserviceaccount \
  --profile YOUR_PROFILE_NAME \
  --name crowdstrike-falcon-sa \
  --namespace falcon-sidecar \
  --region "$AWS_REGION" \
  --cluster "${CLUSTER_NAME}" \
  --attach-policy-arn "${iam_policy_arn}" \
  --approve \
  --override-existing-serviceaccounts
```

### Install Container Sensor Injector

Install the injector pod into `falcon-sidecar` namespace that must be matched by Fargate profile. Set the ServiceAccount to use the IAM role created for ECR permissions.

> **Note:** You will need the ARN of the IAM role created in the previous step to pass in serviceAccount annotations.

```bash
helm upgrade --install falcon-helm crowdstrike/falcon-sensor \
  -n falcon-sidecar --create-namespace \
  --set node.enabled=false \
  --set container.enabled=true \
  --set falcon.cid="YOUR_CID_HERE" \
  --set container.image.repository=$CONTAINER_SENSOR_REGISTRY \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::YOUR_ACCOUNT_ID:role/YOUR_IAM_ROLE_NAME" \
  --set container.image.tag="7.36.0-7502"
```

## Verification

### Verify Sidecar Injection

```bash
# Get pod name first
kubectl get pods -n project1

# Verify that sidecar is injected (replace pod name with actual pod name)
kubectl exec YOUR_POD_NAME \
  -c crowdstrike-falcon-container \
  -n project1 \
  -- falconctl -g --aid --cid
```

## Security Notes

- Replace all placeholder values (`YOUR_*`) with your actual configuration
- Store sensitive values (CID, Client ID/Secret) securely using secrets management
- Regularly rotate API credentials
- Follow least privilege principles for IAM roles and policies