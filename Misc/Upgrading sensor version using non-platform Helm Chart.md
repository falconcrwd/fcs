# Upgrading Falcon Sensor Version Using Helm Charts

This guide demonstrates how to upgrade Falcon Sensor deployments using the standalone sensor Helm chart, as well as managing Helm chart upgrades for legacy installations.

## Overview

**Target Deployments:** Installations using the legacy [Falcon Sensor Helm chart](https://github.com/CrowdStrike/falcon-helm/tree/falcon-sensor-1.35.0/helm-charts/falcon-sensor)

**Upgrade Types:**
- **Sensor Image Only:** Update container image version while maintaining Helm chart version
- **Helm Chart:** Upgrade chart version with optional image updates
- **Combined:** Both chart and image updates

---

## Prerequisites

**Requirements:**
- New sensor image available in private container registry (e.g., ECR)
- Helm CLI configured with cluster access
- CrowdStrike Helm repository added

**Add CrowdStrike Helm Repository:**
```bash
helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm
helm repo update
```

---

## Current Installation Assessment

### Step 1: Identify Current Installation

Check existing Helm deployments:

```bash
helm list -A
```

**Expected Output:**
```
NAME         	NAMESPACE    	REVISION	UPDATED                            	STATUS  	CHART               	APP VERSION
falcon-sensor	falcon-system	2       	2026-03-16 16:36:54.24867 +0800 +08	deployed	falcon-sensor-1.35.0	7.35
```

### Step 2: Review Available Charts

List all available CrowdStrike Helm charts:

```bash
helm search repo crowdstrike
```

**Available Charts:**
```
NAME                                              	CHART VERSION	APP VERSION	DESCRIPTION
crowdstrike/aspmrelay                             	1.1.0        	0.40.0     	ASPM Relay Helm Chart
crowdstrike/cs-k8s-protection-agent               	1.0.3        	1.0.1      	A Helm chart for Crowdstrike Kubernetes Protect...
crowdstrike/falcon-image-analyzer                 	1.1.20       	1.0.24     	A Helm chart for Falcon Image Analyzer
crowdstrike/falcon-integration-gateway            	0.5.1        	3.2.0      	Falcon Integration Gateway for cloud
crowdstrike/falcon-kac                            	1.6.0        	1.6.0      	A Helm chart to deploy CrowdStrike Falcon Kuber...
crowdstrike/falcon-platform                       	1.3.0        	           	A comprehensive Helm umbrella chart to deploy t...
crowdstrike/falcon-self-hosted-registry-assessment	1.6.0        	1.6.0      	CrowdStrike Self-hosted Registry Assessment
crowdstrike/falcon-sensor                         	1.35.0       	7.35       	A Helm chart to deploy CrowdStrike Falcon senso...
crowdstrike/registry-scanner                      	0.1.0        	0.1.0      	CrowdStrike Self-hosted Registry Assessment
```

---

## Sensor Image Upgrade (Chart Version Unchanged)

### Basic Image Update

Update only the sensor container image:

**General Syntax:**
```bash
helm upgrade --install <INSTALLATION_NAME> <CHART_NAME> \
    -n <NAMESPACE> --create-namespace \
    --set falcon.cid=<FALCON_CID> \
    --set node.image.tag="<NEW_IMAGE_TAG>" \
    --set node.image.repository="<REGISTRY_URL>/<REPOSITORY_NAME>"
```

**Specific Example:**
```bash
helm upgrade --install falcon-sensor crowdstrike/falcon-sensor \
    -n falcon-system --create-namespace \
    --set falcon.cid=<FALCON_CID> \
    --set node.image.tag="<NEW_SENSOR_VERSION>" \
    --set node.image.repository="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<ECR_NAMESPACE>/falcon-sensor"
```

---

## Helm Chart Upgrade Management

### Check Available Chart Versions

Review all available versions of the falcon-sensor chart:

```bash
helm search repo crowdstrike/falcon-sensor --versions
```

**Available Versions:**
```
NAME                     	CHART VERSION	APP VERSION	DESCRIPTION
crowdstrike/falcon-sensor	1.35.0       	7.35       	A Helm chart to deploy CrowdStrike Falcon senso...
crowdstrike/falcon-sensor	1.34.2       	1.34.2     	A Helm chart to deploy CrowdStrike Falcon senso...
crowdstrike/falcon-sensor	1.34.1       	1.34.1     	A Helm chart to deploy CrowdStrike Falcon senso...
crowdstrike/falcon-sensor	1.34.0       	1.34.0     	A Helm chart to deploy CrowdStrike Falcon senso...
```

### Chart Upgrade Operations

**Upgrade Chart While Reusing Values:**
```bash
helm upgrade falcon-sensor crowdstrike/falcon-sensor \
  --version <NEW_CHART_VERSION> \
  --namespace falcon-system \
  --reuse-values
```

**Optional: Download and Examine Chart:**
```bash
# Pull chart locally
helm pull crowdstrike/falcon-sensor --version <VERSION> --untar

# Show chart details
helm show chart crowdstrike/falcon-sensor --version <VERSION>
```

> **Reference:** [Maintain and Manage Falcon Platform Documentation](https://falcon.crowdstrike.com/documentation/page/g7h8j9k0l/maintain-and-manage-falcon-platform#n5m6q7w8e)

---

## Complete Upgrade Example: Chart + Container Sensor

### Step 1: Install Legacy Version

Install using older chart and sensor versions for demonstration:

```bash
helm upgrade --install falcon-helm crowdstrike/falcon-sensor \
    --version 1.34.0 \
    -n falcon-system \
    --create-namespace \
    --set node.enabled=false \
    --set container.enabled=true \
    --set falcon.cid=$FALCON_CID \
    --set container.image.repository="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<ECR_NAMESPACE>/falcon-container" \
    --set container.image.tag="<OLD_CONTAINER_VERSION>"
```

### Step 2: Verify Injector Pods

Check that container injector pods are running:

```bash
kubectl get pods -A -w
```

**Expected Output:**
```
NAMESPACE       NAME                                     READY   STATUS    RESTARTS   AGE
falcon-system   falcon-sensor-injector-9c8b58dc9-m82z2   1/1     Running   0          3m10s
falcon-system   falcon-sensor-injector-9c8b58dc9-vl2f5   1/1     Running   0          3m10s
```

### Step 3: Trigger Sidecar Injection

Restart application deployments to inject sidecars:

```bash
kubectl rollout restart -n default deployment nginx

# Verify sidecar injection
kubectl describe pod <POD_NAME>
```

### Step 4: Upgrade Helm Chart

Upgrade to newer chart version while reusing values:

```bash
helm upgrade --install falcon-helm crowdstrike/falcon-sensor \
    --version 1.35.0 \
    -n falcon-system \
    --reuse-values
```

### Step 5: Upgrade Sensor Image

Update to newer container sensor version:

```bash
helm upgrade --install falcon-helm crowdstrike/falcon-sensor \
    --version 1.35.0 \
    -n falcon-system \
    --create-namespace \
    --set node.enabled=false \
    --set container.enabled=true \
    --set falcon.cid=$FALCON_CID \
    --set container.image.repository="<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<ECR_NAMESPACE>/falcon-container" \
    --set container.image.tag="<NEW_CONTAINER_VERSION>"
```

### Step 6: Restart Application Pods

Restart applications to use the new sidecar version:

```bash
kubectl get deployments
kubectl rollout restart -n default deployment nginx
```

> **Important:** Application pods must be restarted to use the new sidecar version.

---

## Falcon Platform Chart Component Upgrade

For installations using the unified `falcon-platform` chart, upgrade individual components:

```bash
helm upgrade --install falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --reuse-values \
  --set falcon-sensor.container.image.tag=<NEW_IMAGE_TAG>
```

---

## Useful Helm Management Commands

### Check Installation Status

```bash
# List installations
helm list -A

# Check specific installation status
helm status falcon-sensor -n falcon-system

# View installation history
helm history falcon-sensor -n falcon-system
```

**Example Status Output:**
```
NAME: falcon-sensor
LAST DEPLOYED: Mon Mar 16 16:36:54 2026
NAMESPACE: falcon-system
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
RESOURCES:
==> v1/DaemonSet
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
falcon-sensor   2         2         2       2            2           kubernetes.io/os=linux   28m
```

### Repository Management

```bash
# List configured repositories
helm repo list

# Update repository cache
helm repo update

# Search for specific charts
helm search repo crowdstrike
```

---

## Troubleshooting

**Common Issues:**

1. **Image Pull Failures:**
   - Verify new image exists in registry
   - Check registry authentication
   - Confirm image tag accuracy

2. **Sidecar Not Updated:**
   - Restart application pods after sensor upgrade
   - Verify injector pods are running
   - Check mutating webhook configuration

3. **Chart Upgrade Failures:**
   - Use `--reuse-values` to maintain custom settings
   - Check for breaking changes between chart versions
   - Verify CRDs are compatible

### Recovery Commands

```bash
# Rollback to previous version
helm rollback falcon-sensor <REVISION_NUMBER> -n falcon-system

# Force reinstallation
helm upgrade --install falcon-sensor crowdstrike/falcon-sensor --force
```

---

## Best Practices

1. **Pre-Upgrade Validation:**
   - Test upgrades in development environments
   - Backup current configurations
   - Review chart changelog for breaking changes

2. **Staged Rollouts:**
   - Upgrade non-production environments first
   - Monitor sensor telemetry after upgrades
   - Implement gradual rollout strategies

3. **Configuration Management:**
   - Use values files for complex configurations
   - Document custom settings and overrides
   - Version control Helm values

---

## Configuration Placeholders

Replace these placeholders with your specific values:
- `<FALCON_CID>`: Your Falcon Customer ID with checksum
- `<NEW_IMAGE_TAG>`, `<NEW_SENSOR_VERSION>`: Updated image version tags
- `<AWS_ACCOUNT_ID>`: Your AWS account ID
- `<AWS_REGION>`: Your AWS region
- `<ECR_NAMESPACE>`: Your ECR repository namespace
- `<INSTALLATION_NAME>`: Your Helm installation name
- `<NAMESPACE>`: Target Kubernetes namespace