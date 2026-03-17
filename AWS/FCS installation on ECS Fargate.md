# Installing Falcon Sensor on ECS backed by Fargate
This is an example of patching the task definition. You can also patch the application image.

The below commands can all be run from a host:
- With AWS CLI, Skopeo, Docker Daemon and client installed. Skopeo cannot be installed in AWS cloudshell.
- Access to AWS
- Follow instructions at [here](https://falcon.crowdstrike.com/documentation/page/a5c297cc/deploy-falcon-container-sensor-for-linux-on-ecs-fargate)
- Image copy instructions are [here](https://falcon.crowdstrike.com/documentation/page/vc320402/retrieve-falcon-cloud-security-product-images-from-the-crowdstrike-registry)
- It should not be necessary to add the below to the task definition, it should auto-detect:

```json
"runtimePlatform": {
   "cpuArchitecture": "X86_64",
   "operatingSystemFamily": "LINUX"
}
```

## Set Falcon environment variables

The Falcon client ID needs to be created with at least the following permissions:
- Falcon Images Download: Read
- Sensor Download: Read

```bash
#!/bin/bash
export FALCON_CLIENT_ID="<FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<FALCON_CLIENT_SECRET>"
export FALCON_CID="<CUSTOMER_ID>"
```

## Sign into AWS on CLI

Use SSO method to avoid having credentials in ~/.aws/config

```bash
aws configure sso
```

Note down your profile name, in this case it is **<PROFILE_NAME>**
When you run any commands in aws cli, add the profile name

```bash
aws sts get-caller-identity --profile <PROFILE_NAME>
```

## Log into ECR

```bash
aws ecr get-login-password --region us-west-2 --profile <PROFILE_NAME> | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com
```

## Get pull script

```bash
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"
chmod +x falcon-container-sensor-pull.sh
```

## Copy latest images to ECR

This assumes the registry <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE> is already setup. You actually only need falcon-container image

```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  --copy <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE>

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  --copy <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE>

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  --copy <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE>

./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  --copy <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE>
```

## Copy your application image to ECR if not done so

In this case, skopeo is used to copy the application image assuming it is a multi-arch image from public repo

```bash
skopeo copy --all \
  docker://docker.io/library/nginx:latest \
  docker://<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/<NAMESPACE>/nginx:latest \
  --dest-creds AWS:$(aws ecr get-login-password --region us-west-2 --profile <PROFILE_NAME>)
```

## Set additional environment variables

```bash
IMAGE_PULL_TOKEN=$(echo "{\"auths\":{\"<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com\":{\"auth\":\"$(echo AWS:$(aws ecr get-login-password --profile <PROFILE_NAME>)|base64 -w 0)\"}}}" | base64 -w 0)

export AWS_REPO=$(aws ecr describe-repositories --repository-name <NAMESPACE>/falcon-container --profile <PROFILE_NAME> | jq -r  '.repositories[].repositoryUri' | tail -1) && echo $AWS_REPO
```

## Run the patching utility

If you run this from an ARM host, the changes will be for aarch64 whereas if you run this from x86_64 then the changes will be for x86_64. To control which architecture, set the --platform accordingly

### For arm64

```bash
docker run --platform linux/arm64 -v /Users/user/Downloads:/var/run/spec \
  --rm "$AWS_REPO":7.34.0-7306 \
  -cid $FALCON_CID \
  -image "$AWS_REPO":7.34.0-7306 \
  -pulltoken $IMAGE_PULL_TOKEN \
  -ecs-spec-file /var/run/spec/nginx-task-ecs-fargate-unpatched.json >nginx-task-ecs-fargate-patched2.json
```

### For x86_64

```bash
docker run --platform linux/amd64 -v /Users/user/Downloads:/var/run/spec \
  --rm "$AWS_REPO":7.34.0-7306 \
  -cid $FALCON_CID \
  -image "$AWS_REPO":7.34.0-7306 \
  -pulltoken $IMAGE_PULL_TOKEN \
  -ecs-spec-file /var/run/spec/nginx-task-ecs-fargate-unpatched.json >nginx-task-ecs-fargate-patched1.json
```