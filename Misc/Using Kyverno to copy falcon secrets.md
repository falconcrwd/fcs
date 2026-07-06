# Using Kyverno to Copy Falcon Secrets Across Namespaces

This documentation details how to configure Kyverno to automatically copy and synchronize Falcon secrets (such as image pull secrets or API credentials) across Kubernetes namespaces. It covers the required `ClusterPolicy`, RBAC verification techniques, and steps to update your Helm-installed Kyverno deployment to resolve admission webhook blockages.



## When do you need Kyverno to help to copy secrets?
- When you are pulling falcon images directly from CRWD registry in the case of falcon-injector pods injecting sensor sidecar, then you need Kyverno to help copy the secret that contains client_id, client_secret to each namespace. This is because secrets are needed to pull images from CRWD registry and secrets are scoped to namespaces
- For a daemonset install that also fetches images directly from CRWD registry, this is not required because you do not need to pull falcon-sensor image each time an application pod spins up. The falcon-sensor image is only pulled during daemonset install and the secret is already in the namespace for the daemonset sensor
- If you are pulling falcon images from your own ECR, then your AmazonEKSFargatePodExecutionRole role should already have the required permissions to do it


---

## 1. Kyverno ClusterPolicy Manifest

The following policy triggers whenever a new `Namespace` is created or when an existing one is evaluated. It instructs Kyverno to automatically clone a Falcon secret (e.g., `crowdstrike-falcon-pull-secret`) from a central namespace (e.g., `default`) into target namespaces.

Create a file named `sync-falcon-secrets-policy.yaml` and apply it using `kubectl`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-secrets
  annotations:
    policies.kyverno.io/title: Sync Secrets
    policies.kyverno.io/category: Sample
    policies.kyverno.io/subject: Secret
    policies.kyverno.io/minversion: 1.6.0
    policies.kyverno.io/description: "copy crowdstrike-falcon-pull-secret from default to all newly created namespaces"
spec:
  rules:
    - name: sync-image-pull-secret
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-system
                - kube-public
                - kube-node-lease
                - default
      generate:
        apiVersion: v1
        kind: Secret
        name: crowdstrike-falcon-pull-secret
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: default
          name: crowdstrike-falcon-pull-secret
```

### Advanced: Cloning Multiple Falcon Resources Together

If you need to copy multiple matching Falcon components (such as a `Secret` and a global configuration `ConfigMap`), swap the `clone` block for a `cloneList`:

```yaml
generate:
  namespace: "{{request.object.metadata.name}}"
  synchronize: true
  cloneList:
    namespace: falcon-system
    kinds:
      - v1/Secret
      - v1/ConfigMap
    selector:
      matchLabels:
        asset-type: "falcon-core"
```

---

## 2. Diagnosing and Verifying RBAC Permissions

Because Kyverno reads secrets globally and writes them across namespaces, its automated controllers require explicit cluster-wide permissions.

### Simulating Kyverno Actions via `kubectl`

To quickly verify whether Kyverno's service accounts have the necessary authorization to perform cloning operations, run the following commands:

```bash
# Check if the Background Controller can read secrets globally
kubectl auth can-i get secrets \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  --all-namespaces

# Check if the Background Controller can write secrets globally
kubectl auth can-i create secrets \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  --all-namespaces
```

> **Note:** For older versions of Kyverno (pre-v1.10), use `--as=system:serviceaccount:kyverno:kyverno` instead.

### Auditing the Manifest Directly

You can review the raw permission parameters attached to your active controller:

```bash
kubectl get clusterrole kyverno:background-controller -o yaml
```

Ensure the configuration contains explicit authorization for secret manipulation:

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
```

---

## 3. Resolving Webhook Validation Failures

### The Error

When deploying a policy that mutates or generates assets dynamically, you may hit a validation error from the admission controller webhook:

```text
Error from server: error when creating "kyverno.yaml": admission webhook "validate-policy.kyverno.svc" denied the request: path: spec.rules[0].generate..: system:serviceaccount:kyverno:kyverno-admission-controller requires permissions list,get for resource v1/Secret in namespace {{request.object.metadata.name}}
```

### Why This Happens

Kyverno uses **two separate components** that require distinct sets of access rights:

1. **The Admission Controller** — Intercepts the policy manifest upon creation. It requires read access (`get`, `list`, `watch`) to validate that the requested schema changes are safe.
2. **The Background Controller** — Operates behind the scenes. It requires write access (`create`, `update`, `delete`) to physically build, sync, and repair downstream secrets.

---

## 4. Modifying Helm Settings Post-Installation

If you initially installed Kyverno using the standard remote defaults (`helm install kyverno kyverno/kyverno -n kyverno`), use one of the variations below to update both controller permission sets simultaneously.

### Option A: Inline Helm Upgrade (Fastest)

Apply the mandatory RBAC permissions directly to your live environment without configuring local file directories:

```bash
helm upgrade kyverno kyverno/kyverno \
  --namespace kyverno \
  --reuse-values \
  --set "backgroundController.rbac.clusterRole.extraResources.apiGroups={""}" \
  --set "backgroundController.rbac.clusterRole.extraResources.resources={secrets}" \
  --set "backgroundController.rbac.clusterRole.extraResources.verbs={get,list,watch,create,update,delete}" \
  --set "admissionController.rbac.clusterRole.extraResources.apiGroups={""}" \
  --set "admissionController.rbac.clusterRole.extraResources.resources={secrets}" \
  --set "admissionController.rbac.clusterRole.extraResources.verbs={get,list,watch}"
```

### Option B: Using a Dedicated Values File (Recommended for GitOps)

1. Document your configuration choices in a custom file named `my-values.yaml`:

   ```yaml
   backgroundController:
     rbac:
       clusterRole:
         extraResources:
           - apiGroups: [""]
             resources: ["secrets"]
             verbs: ["get", "list", "watch", "create", "update", "delete"]

   admissionController:
     rbac:
       clusterRole:
         extraResources:
           - apiGroups: [""]
             resources: ["secrets"]
             verbs: ["get", "list", "watch"]
   ```

2. Execute the cluster upgrade using your custom specifications:

   ```bash
   helm upgrade kyverno kyverno/kyverno \
     -n kyverno \
     -f my-values.yaml \
     --reuse-values
   ```

### Option C: Manual Unpacking and Expansion

If your organizational policy requires local auditing of the structural chart code prior to upgrades:

```bash
# Fetch and unpack the chart archive locally
helm pull kyverno/kyverno --untar

# Edit fields manually under the backgroundController and admissionController
# blocks within ./kyverno/values.yaml

# Sync your modified directory assets to the cluster
helm upgrade kyverno ./kyverno -n kyverno
```
