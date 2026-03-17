# Falcon Container Sensor Installation for Google Cloud Run

This guide demonstrates how to install the Falcon Container Sensor on Google Cloud Run using the Falcon patching utility.

## Overview

**Reference Documentation:** [CrowdStrike Google Cloud Run Integration](https://docs.crowdstrike.com/r/p6af9353)

**Environment:** Linux jump host in GKE with Docker daemon and client installed

---

## Prerequisites

**Infrastructure Requirements:**
- Linux host with Docker daemon and client
- Access to Google Cloud Artifact Registry or compatible registry
- Appropriate GCP permissions for service account impersonation
- Falcon Container Sensor image available in registry

---

## Step 1: Configure Artifact Registry Authentication

### Set Active Account

Configure the active account for service account impersonation:

```bash
# List available accounts
gcloud auth list

# Set active account
gcloud config set account <USER_EMAIL>
```

**Expected Account Structure:**
```
                  Credentialed Accounts
ACTIVE  ACCOUNT
*       <SERVICE_ACCOUNT_EMAIL>
        <USER_EMAIL>
```

### Generate Registry Credentials

Generate base64 encoded credentials (valid for 60 minutes):

```bash
gcloud auth print-access-token \
    --impersonate-service-account <SERVICE_ACCOUNT_EMAIL> | docker login \
    -u oauth2accesstoken \
    --password-stdin https://<REGION>-docker.pkg.dev
```

**Expected Output:**
```
WARNING: This command is using service account impersonation. All API calls will be executed as [<SERVICE_ACCOUNT_EMAIL>].

WARNING! Your credentials are stored unencrypted in '/home/user/.docker/config.json'.
Configure a credential helper to remove this warning. See
https://docs.docker.com/go/credential-store/

Login Succeeded
```

> **Reference:** See [Step 4 of CrowdStrike GCP documentation](https://docs.crowdstrike.com/r/oc845066) for detailed registry credential generation.

---

## Step 2: Extract and Use Falcon Utility

### Extract Falcon Utility Binary

Run the Falcon container locally and extract the `falconutil` binary:

```bash
#!/bin/bash

export MY_REPO=<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-container:<FALCON_VERSION>

# Create container instance
id=$(docker create $MY_REPO)

# Copy falconutil binary to local filesystem
docker cp $id:/usr/bin/falconutil /tmp

# Clean up container
docker rm -v $id
```

### Patch Application Image

Use the extracted utility to patch your application image:

```bash
/tmp/falconutil patch-image \
  --source-image-uri docker.io/library/httpd:latest \
  --target-image-uri <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0 \
  --falcon-image-uri $MY_REPO \
  --cid <FALCON_CUSTOMER_ID> \
  --container httpd-falcon \
  --cloud-service CLOUDRUN
```

### Expected Patching Output

```
⇒ [internal] load remote build context
⇒ [internal] load metadata for <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-container:<FALCON_VERSION>
⇒ [internal] load metadata for docker.io/library/httpd:latest
⇒ [stage-1 1/2] FROM docker.io/library/httpd:latest@sha256:<DIGEST>
⇒ [build 1/7] FROM <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-container:<FALCON_VERSION>@sha256:<DIGEST>
⇒ [build 2/7] RUN mkdir -p /tmp/CrowdStrike/rootfs/usr/bin && cp -R /usr/bin/falcon* /usr/bin/injector /tmp/CrowdStrike/rootfs/usr/bin
⇒ [build 3/7] RUN cp -R /usr/lib64 /tmp/CrowdStrike/rootfs/usr/
⇒ [build 4/7] RUN mkdir -p /tmp/CrowdStrike/rootfs/usr/lib && cp -R /usr/lib/locale /tmp/CrowdStrike/rootfs/usr/lib
⇒ [build 5/7] RUN cd /tmp/CrowdStrike/rootfs && ln -s usr/bin bin && ln -s usr/lib64 lib64 && ln -s usr/lib lib
⇒ [build 6/7] RUN mkdir -p /tmp/CrowdStrike/rootfs/etc/ssl/certs && cp /etc/ssl/certs/ca-bundle* /tmp/CrowdStrike/rootfs/etc/ssl/certs
⇒ [build 7/7] RUN chmod -R a=rX /tmp/CrowdStrike
⇒ [stage-1 2/2] COPY --from=build /tmp/CrowdStrike /opt/CrowdStrike
⇒ exporting layers
⇒ naming to <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0
⇒ Successfully built image ID: sha256:<IMAGE_DIGEST>
```

---

## Step 3: Push Image to Artifact Registry

### Verify Local Images

Check that the patched image was created locally:

```bash
docker images
```

**Expected Output:**
```
IMAGE                                                                     ID             DISK USAGE   CONTENT SIZE
<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/falcon-container:<FALCON_VERSION>   <IMAGE_ID>     228MB        54.5MB
<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0   <IMAGE_ID>     398MB        100MB
httpd:latest                                                              <IMAGE_ID>     177MB        47.6MB
```

### Push Patched Image

Upload the patched image to Google Artifact Registry:

```bash
docker push <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0
```

**Expected Output:**
```
The push refers to repository [<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon]
<LAYER_ID>: Layer already exists
<LAYER_ID>: Pushed
<LAYER_ID>: Pushed
<LAYER_ID>: Pushed
<LAYER_ID>: Pushed
<LAYER_ID>: Pushed
<LAYER_ID>: Pushed
1.0: digest: sha256:<DIGEST> size: 1681
```

---

## Step 4: Deploy to Google Cloud Run

### Create Cloud Run Service

Use the patched image to create a Cloud Run service:

```bash
gcloud run deploy httpd-falcon \
  --image <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0 \
  --region <REGION> \
  --platform managed \
  --allow-unauthenticated
```

### Alternative: Deploy via Console

1. Navigate to Google Cloud Run in the GCP Console
2. Click "Create Service"
3. Select "Deploy one revision from an existing container image"
4. Enter the patched image URL: `<REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_NAME>/httpd-falcon:1.0`
5. Configure service settings as needed
6. Deploy the service

---

## Step 5: Verification

### Check Service Status

```bash
# List Cloud Run services
gcloud run services list

# Get service details
gcloud run services describe httpd-falcon --region <REGION>
```

### Verify Falcon Agent

**Container Logs:**
```bash
gcloud run services logs read httpd-falcon --region <REGION>
```

Look for Falcon sensor initialization messages in the logs.

**Falcon Console:**
1. Navigate to Falcon Console
2. Go to **Cloud Security** > **Container Inventory** > **Cloud Run**
3. Verify the service appears with active sensor status
4. Check for Agent ID (AID) assignment

---

## Command Parameters Explained

**Key falconutil Parameters:**
- `--source-image-uri`: Original application container image
- `--target-image-uri`: Output patched image location
- `--falcon-image-uri`: Falcon container sensor image path
- `--cid`: Falcon Customer ID with checksum
- `--container`: Container name for identification
- `--cloud-service CLOUDRUN`: Specifies Google Cloud Run deployment

---

## Security Considerations

### Authentication Best Practices

1. **Service Account Permissions:**
   - Use least-privilege principle for service accounts
   - Regularly rotate service account keys
   - Monitor service account usage

2. **Registry Security:**
   - Enable vulnerability scanning on Artifact Registry
   - Implement image signing and verification
   - Use private registries for sensitive workloads

3. **Network Security:**
   - Configure VPC connectors for private network access
   - Implement proper egress controls
   - Monitor network traffic patterns

---

## Troubleshooting

**Common Issues:**

1. **Authentication Failures:**
   - Verify service account impersonation permissions
   - Check Artifact Registry access permissions
   - Ensure gcloud CLI is properly configured

2. **Image Build Failures:**
   - Verify Falcon container image accessibility
   - Check Docker daemon status and permissions
   - Ensure sufficient disk space for image operations

3. **Cloud Run Deployment Issues:**
   - Verify image exists in Artifact Registry
   - Check Cloud Run service configuration
   - Monitor service logs for startup errors

---

## Performance Optimization

1. **Image Size:**
   - Use minimal base images where possible
   - Implement multi-stage builds to reduce image size
   - Regularly clean up unused layers

2. **Cold Start Reduction:**
   - Configure appropriate CPU and memory limits
   - Implement service warming strategies
   - Use Cloud Run minimum instances setting

---

## Configuration Placeholders

Replace these placeholders with your specific values:
- `<USER_EMAIL>`: Your GCP user account email
- `<SERVICE_ACCOUNT_EMAIL>`: GCP service account for impersonation
- `<PROJECT_ID>`: Your Google Cloud project ID
- `<REGISTRY_NAME>`: Your Artifact Registry repository name
- `<REGION>`: Your Google Cloud region (e.g., `asia-southeast1`)
- `<FALCON_VERSION>`: Falcon container sensor version
- `<FALCON_CUSTOMER_ID>`: Your Falcon Customer ID (CID) with checksum