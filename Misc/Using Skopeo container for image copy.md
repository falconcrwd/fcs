# Using Skopeo Container for Multi-Architecture Image Copy

This guide demonstrates how to use Skopeo as a container to copy Falcon images directly from the CrowdStrike registry to AWS ECR, preserving multi-architecture support.

## Overview

**Use Case:** When Skopeo cannot be installed natively (Windows machines, Amazon Linux OS), running Skopeo as a container provides the same functionality.

**Key Benefits:**
- Preserves multi-architecture images during copy operations
- Avoids Docker's limitation of storing only one architecture per tag locally
- Prevents architecture mismatches between host and deployment environments

**Supported Environments:** Can be run in AWS CloudShell and other Docker-enabled environments.

---

## Prerequisites

**Required Tools:**
- Docker daemon
- `jq` (JSON processor)
- AWS CLI configured with appropriate permissions

**Optional:**
- Skopeo (native installation) - alternative to container approach

---

## Environment Setup

### Export Required Variables

```bash
export FALCON_CLIENT_ID="<FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<FALCON_CLIENT_SECRET>"
export FALCON_CID="<FALCON_CUSTOMER_ID>"

export AWS_ACCOUNT_ID="<AWS_ACCOUNT_ID>"
export AWS_REGION="<AWS_REGION>"
export ECR_PASSWORD=$(aws ecr get-login-password --region ${AWS_REGION} --profile <AWS_PROFILE_NAME>)
```

### Obtain API Bearer Token

```bash
export FALCON_CS_API_TOKEN=$(curl \
--data "client_id=${FALCON_CLIENT_ID}&client_secret=${FALCON_CLIENT_SECRET}" \
--request POST \
--silent \
https://api.crowdstrike.com/oauth2/token | jq -r '.access_token')
```

### Get CrowdStrike Registry Credentials

```bash
export FALCON_ART_USERNAME="fc-$(echo ${FALCON_CID} | awk '{ print tolower($0) }' | cut -d'-' -f1)"
```

```bash
export FALCON_ART_PASSWORD=$(curl -s -X GET -H "authorization: Bearer ${FALCON_CS_API_TOKEN}" \
https://api.crowdstrike.com/container-security/entities/image-registry-credentials/v1 | \
jq -r '.resources[].token')
```

---

## Native Skopeo Operations (Optional)

If Skopeo is installed locally, you can perform these verification steps:

### Verify Registry Access

```bash
skopeo login --username $FALCON_ART_USERNAME --password $FALCON_ART_PASSWORD registry.crowdstrike.com
```

### List Available Images

**Falcon Container Sensor:**
```bash
skopeo list-tags docker://registry.crowdstrike.com/falcon-container/release/falcon-container
```

**Falcon Node Sensor:**
```bash
skopeo list-tags docker://registry.crowdstrike.com/falcon-sensor/release/falcon-sensor
```

**Kubernetes Admission Controller (KAC):**
```bash
skopeo list-tags docker://registry.crowdstrike.com/falcon-kac/release/falcon-kac
```

**Image Assessment Runtime (IAR):**
```bash
skopeo list-tags docker://registry.crowdstrike.com/falcon-imageanalyzer/us-1/release/falcon-imageanalyzer
```

---

## Container-Based Image Copy Operations

### Copy Falcon Container Image

```bash
docker run --rm \
  quay.io/skopeo/stable copy --insecure-policy \
  --all \
  --src-creds "${FALCON_ART_USERNAME}:${FALCON_ART_PASSWORD}" \
  --dest-creds AWS:${ECR_PASSWORD} \
  docker://registry.crowdstrike.com/falcon-container/release/falcon-container:<VERSION> \
  docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<ECR_NAMESPACE>/falcon-container:<VERSION>
```

### Copy Public Images (Example: Nginx)

```bash
docker run --rm \
  quay.io/skopeo/stable copy --insecure-policy \
  --all \
  --dest-creds AWS:${ECR_PASSWORD} \
  docker://docker.io/library/nginx:latest \
  docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<ECR_NAMESPACE>/nginx
```

---

## Interactive Skopeo Container

For multiple operations or troubleshooting, run an interactive Skopeo container:

```bash
docker run -it --rm \
  -v $(pwd):/work \
  --name skopeo-container \
  --entrypoint sh \
  quay.io/skopeo/stable
```

**Inside the container, you can run:**
- `skopeo login` commands
- `skopeo list-tags` commands
- `skopeo copy` operations
- `skopeo inspect` for image details

---

## Copy All Falcon Components

### Falcon Node Sensor (DaemonSet)

```bash
docker run --rm \
  quay.io/skopeo/stable copy --insecure-policy \
  --all \
  --src-creds "${FALCON_ART_USERNAME}:${FALCON_ART_PASSWORD}" \
  --dest-creds AWS:${ECR_PASSWORD} \
  docker://registry.crowdstrike.com/falcon-sensor/release/falcon-sensor:<SENSOR_VERSION> \
  docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<ECR_NAMESPACE>/falcon-sensor:<SENSOR_VERSION>
```

### Kubernetes Admission Controller

```bash
docker run --rm \
  quay.io/skopeo/stable copy --insecure-policy \
  --all \
  --src-creds "${FALCON_ART_USERNAME}:${FALCON_ART_PASSWORD}" \
  --dest-creds AWS:${ECR_PASSWORD} \
  docker://registry.crowdstrike.com/falcon-kac/release/falcon-kac:<KAC_VERSION> \
  docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<ECR_NAMESPACE>/falcon-kac:<KAC_VERSION>
```

### Image Assessment Runtime

```bash
docker run --rm \
  quay.io/skopeo/stable copy --insecure-policy \
  --all \
  --src-creds "${FALCON_ART_USERNAME}:${FALCON_ART_PASSWORD}" \
  --dest-creds AWS:${ECR_PASSWORD} \
  docker://registry.crowdstrike.com/falcon-imageanalyzer/us-1/release/falcon-imageanalyzer:<IAR_VERSION> \
  docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<ECR_NAMESPACE>/falcon-imageanalyzer:<IAR_VERSION>
```

---

## Command Parameters Explained

**Key Skopeo Flags:**
- `--all`: Copy all architectures (preserves multi-arch manifests)
- `--insecure-policy`: Skip policy verification (for testing environments)
- `--src-creds`: Source registry credentials
- `--dest-creds`: Destination registry credentials

**Authentication Formats:**
- CrowdStrike Registry: `username:password`
- AWS ECR: `AWS:token` (where token is from `aws ecr get-login-password`)

---

## Troubleshooting

**Common Issues:**

1. **Authentication Failures:**
   - Verify Falcon API credentials and permissions
   - Check AWS CLI profile and ECR permissions
   - Ensure CID is correct and properly formatted

2. **Network Connectivity:**
   - Confirm access to `registry.crowdstrike.com`
   - Verify ECR endpoint accessibility
   - Check firewall and proxy settings

3. **Image Not Found:**
   - Use `skopeo list-tags` to verify available versions
   - Check image path formatting
   - Confirm image exists in the specified repository

---

## Best Practices

1. **Use `--all` Flag:** Preserves multi-architecture support
2. **Verify Images:** Use `skopeo inspect` to verify image integrity after copy
3. **Secure Credentials:** Avoid hardcoding credentials in scripts
4. **Tag Management:** Maintain consistent tagging between source and destination
5. **Clean Up:** Remove temporary credentials from environment after use

---

## Configuration Placeholders

Replace these placeholders with your specific values:
- `<FALCON_CLIENT_ID>` and `<FALCON_CLIENT_SECRET>`: Your Falcon API credentials
- `<FALCON_CUSTOMER_ID>`: Your Falcon Customer ID (CID)
- `<AWS_ACCOUNT_ID>`: Your AWS account ID
- `<AWS_REGION>`: Your AWS region (e.g., `us-west-2`)
- `<AWS_PROFILE_NAME>`: Your AWS CLI profile name
- `<ECR_NAMESPACE>`: Your ECR repository namespace
- `<VERSION>`, `<SENSOR_VERSION>`, etc.: Appropriate version tags for each component