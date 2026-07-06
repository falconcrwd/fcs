# Upgrade Image Versions in Falcon Helm

For Falcon Helm charts, the following are available:

- `crowdstrike/falcon-platform`
- `crowdstrike/falcon-sensor`
- `crowdstrike/falcon-kac`
- `crowdstrike/falcon-image-analyzer`

---

## 1. Check the Chart Name and Namespace

```bash
helm list -A
```

Example output:

```text
NAME            NAMESPACE       REVISION        UPDATED                                 STATUS          CHART                     APP VERSION
falcon-platform falcon-platform 1               2026-06-25 08:04:28.419414035 +0000 UTC deployed        falcon-platform-1.4.0
```

---

## 2. Upgrade a Specific Component

In this example, we upgrade the sensor version. Make sure the required image is already in your registry before running the command below. Refer to the [CrowdStrike documentation](https://docs.crowdstrike.com/access?ft:originId=r9t0y1u2i) for details.

```bash
helm upgrade falcon-platform crowdstrike/falcon-platform \
  --namespace falcon-platform \
  --reuse-values \
  --set falcon-sensor.node.image.tag=<NEW_IMAGE_TAG>
```

---

## 3. Restart Deployments for Sidecar (Container Sensor)

For the container sensor (sidecar), perform a rollout restart of the deployment so that the new sidecar image version is attached to the pods:

```bash
kubectl rollout restart deployment <deployment-name> -n <namespace>
```
