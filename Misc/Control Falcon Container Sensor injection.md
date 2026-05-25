# Controlling Falcon container sensor injection on EKS Fargate

The falcon-injector is a **MutatingWebhookConfiguration** that watches pod CREATE events and mutates them to add the Falcon sensor sidecar. Injection scope is controlled at three levels: namespace, pod, and container.

## 1. Default mode: opt-out (permissive)

By default, every pod in every namespace is injected, with these exceptions baked into the webhook:

- `kube-system`, `kube-public`, `falcon-system`
- Any namespace carrying a `control-plane` label
- Anything explicitly labeled/annotated `disabled` (see below)

Webhook namespaceSelector logic: `GithubCRWD/falcon-operator/internal/controller/assets/mutatingwebhook.go:11-84` and Helm equivalent `GithubCRWD/falcon-helm/helm-charts/falcon-sensor/templates/container_deployment_webhook.yaml:256-271`.

## 2. CRD-level switches (FalconContainer)

`GithubCRWD/falcon-operator/api/falcon/v1alpha1/falconcontainer_types.go:78-140`

```yaml
spec:
  injector:
    disableDefaultNamespaceInjection: false  # true ⇒ namespace opt-IN
    disableDefaultPodInjection: false        # true ⇒ pod opt-IN
```

Helm equivalents: `container.disableNSInjection` and `container.disablePodInjection` in `falcon-sensor` values.yaml.

The operator flips the webhook's `matchExpressions` operator from `NotIn ["disabled"]` to `In ["enabled"]` when these are set (`falcon-operator/internal/controller/falcon_container/webhook.go:22-27`).

## 3. Per-namespace label

Label key: `sensor.falcon-system.crowdstrike.com/injection`

| Mode | Label needed |
|---|---|
| Opt-out (default) | `…/injection=disabled` to **exclude** a namespace |
| Opt-in (`disableDefaultNamespaceInjection: true`) | `…/injection=enabled` to **include** a namespace |

```sh
# exclude in default mode
kubectl label namespace my-ns sensor.falcon-system.crowdstrike.com/injection=disabled
```

## 4. Per-pod annotation

Same key, applied as a pod annotation (overrides namespace decision):

```yaml
metadata:
  annotations:
    sensor.falcon-system.crowdstrike.com/injection: "disabled"   # or "enabled"
```

Documented at `ProductDocs/src/sensor-deployment-and-maintenance/linux-kubernetes-and-cloud/falcon-container-sensor-for-linux/deploy-falcon-container-sensor-for-linux/configuration-options-for-falcon-container-sensor.md:399-455`.

## 5. Per-container annotation (skip specific sidecars in a pod)

```yaml
metadata:
  annotations:
    sensor.falcon-system.crowdstrike.com/disabled-containers: "container1,container2"
```

Reference: same docs file, line 461.

## Decision matrix

| Goal | `disableDefaultNSInjection` | `disableDefaultPodInjection` | Action |
|---|---|---|---|
| Inject everything (default) | false | false | nothing |
| Allowlist by namespace | **true** | false | label namespaces `injection=enabled` |
| Allowlist by pod | false | **true** | annotate pods `injection=enabled` |
| Strict double opt-in | **true** | **true** | both label + annotate |
| Block specific namespace in default mode | false | false | label that namespace `injection=disabled` |

## Fargate note

For EKS Fargate, deploy the operator/Helm release with `-target-platform fargate` (`ProductDocs/.../configuration-options-for-falcon-container-sensor.md:497-498`). The injection-control mechanisms above are identical to non-Fargate EKS — Fargate just changes how the sidecar is delivered, not how the webhook scopes it. Make sure the namespace running the falcon-injector itself is on a Fargate profile so it can admit pods scheduled to other Fargate profiles.
