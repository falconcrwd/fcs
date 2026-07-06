# Patching an ECS Container Image Directly with `falconutil`

This runbook covers using CrowdStrike's `falconutil patch-image` to pre-bake the Falcon Container Sensor into an application image (instead of the sidecar/init-container injection pattern), then push a multi-arch manifest to ECR.

> **Placeholders used in this document:**
> - `<AWS_ACCOUNT_ID>` — replace with your 12-digit AWS account ID (e.g. `123456789012`).
> - `<YOUR_FALCON_CID>` — replace with your Falcon Customer ID, including the cloud-suffix (e.g. `AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-XX`). You can find it in the Falcon console under **Host setup and management → Sensor downloads**.
> - The AWS profile name shown as `AdministratorAccess-<AWS_ACCOUNT_ID>` should be replaced with whatever profile you have configured locally for that account.

---

## Assumptions / Prerequisites

- You are already authenticated to AWS locally (e.g. via `aws sso login`) and have a valid, unexpired session for the AWS profile **`AdministratorAccess-<AWS_ACCOUNT_ID>`**. All `aws` CLI commands below use `--profile AdministratorAccess-<AWS_ACCOUNT_ID>`; adjust if your profile name differs.
- Docker Desktop is installed and running.
- You have `read`/`write` (`ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:PutImage`, etc.) permissions to the target ECR registry `<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com`.
- The **unpatched application image** (in this runbook, `pulse/nginx-alpine:1.0`) has already been built and pushed to ECR. `falconutil patch-image` pulls the source image from ECR — it does not build it for you.
- The `falcon-container` image tag used below (`7.38.0-7703`) is already pulled or pullable from ECR.

> **ECR token lifetime:** The bearer token returned by `aws ecr get-login-password` (and therefore the base64 `AWS:<token>` value pasted into `~/.docker/config.json`) is **valid for 12 hours by default**. If your session outlasts 12 hours you must regenerate the base64 credential and update `~/.docker/config.json` again.

---

## Table of Contents

1. [macOS Prerequisites — Docker Credentials](#macos-prerequisites--docker-credentials)
2. [Set the Falcon Container Repo Variable](#set-the-falcon-container-repo-variable)
3. [Get Base64-Encoded ECR Login Credentials](#get-base64-encoded-ecr-login-credentials)
4. [Update `~/.docker/config.json`](#update-dockerconfigjson)
5. [Run `falconutil patch-image` (single-arch)](#run-falconutil-patch-image-single-arch)
6. [Verify Local Images](#verify-local-images)
7. [Inspect Source & Falcon Image Manifests](#inspect-source--falcon-image-manifests)
8. [Multi-Arch: Patch `amd64`](#multi-arch-patch-amd64)
9. [Multi-Arch: Patch `arm64`](#multi-arch-patch-arm64)
10. [Verify Local Images After Multi-Arch Patching](#verify-local-images-after-multi-arch-patching)
11. [Assemble & Push the Multi-Arch Manifest List](#assemble--push-the-multi-arch-manifest-list)

---

## macOS Prerequisites — Docker Credentials

> **Applies only to macOS.**

By default, Docker Desktop on macOS stores ECR login credentials in the macOS keychain (`osxkeychain`). The commands below require a **base64-encoded** credential value in `~/.docker/config.json`, so the keychain integration must be bypassed for this workflow.

You'll typically see this in `~/.docker/config.json`:

```json
{
    "auths": {
        "<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com": {}
    },
    "credsStore": "osxkeychain"
}
```

Because `osxkeychain` is not usable directly by the commands below, you must temporarily rewrite `~/.docker/config.json` with an inline `auth` value after generating the base64 registry credential.

> **Security note:** The base64 `auth` value is an ECR bearer credential (`AWS:<token>`). It is short-lived (12h) but should never be committed to git. Rotate any that may have leaked.

---

## Set the Falcon Container Repo Variable

```bash
MY_REPO=<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container
```

---

## Get Base64-Encoded ECR Login Credentials

The format is `AWS:<bearer_token>`, and the entire string must be base64-encoded. The generated bearer token is valid for **12 hours by default** — after that, re-run this command and update `~/.docker/config.json` again:

```bash
echo "AWS:$(aws ecr get-login-password --region us-west-2 --profile AdministratorAccess-<AWS_ACCOUNT_ID>)" | base64
```

---

## Update `~/.docker/config.json`

Paste the base64 value produced above into the `auth` field (only the first few characters shown here for brevity — paste the full string in your actual file):

```json
{
    "auths": {
        "<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com": {
            "auth": "QVdTO...<rest of base64 string here>..."
        }
    }
}
```

> ⚠️ Do not commit this file. The `auth` value is a live ECR credential. Regenerate every ~12h via the command in the previous section.

---

## Run `falconutil patch-image` (single-arch)

Uses the local Docker daemon (`docker.sock`) to pull the source image, inject the sensor, tag, and push the patched image.

> **Architecture note:** With **no `--platform` flag**, the patched image will inherit the architecture of the **machine running the command**. On an Apple Silicon Mac (M1/M2/M3/M4), that means the output image will be **`arm64`**; on an Intel Mac or standard x86_64 Linux workstation it will be **`amd64`**. If your ECS tasks target a different architecture than your workstation, use the multi-arch flow further down instead of this single-arch command.

```bash
docker run --user 0:0 \
  -v ${HOME}/.docker/config.json:/root/.docker/config.json \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --rm $MY_REPO:7.38.0-7703 \
  falconutil patch-image \
  --source-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine:1.0 \
  --target-image-uri  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0 \
  --falcon-image-uri  $MY_REPO:7.38.0-7703 \
  --cid               <YOUR_FALCON_CID> \
  --image-pull-policy Always \
  --cloud-service     ECS_FARGATE
```

---

## Verify Local Images

```bash
docker images
```

Example output (only images relevant to this workflow shown):

```text
IMAGE                                                                            ID             DISK USAGE   CONTENT SIZE
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container:7.38.0-7703   ff9adb74b2de   232MB        54.3MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0      48e4898f6cb4   321MB        81.6MB
```

You should see:

- The **Falcon container image** (`crwd/falcon-container:7.38.0-7703`) — the sensor image used to run `falconutil`.
- The **patched application image** (`pulse/nginx-alpine-patched:1.0`) — the output of the `falconutil patch-image` command.

---

## Inspect Source & Falcon Image Manifests

### Why we need the per-arch digests

Both the **source application image** (`pulse/nginx-alpine:1.0`) and the **Falcon container image** (`crwd/falcon-container:7.38.0-7703`) are published as **multi-arch manifest lists** (a.k.a. "fat manifests" / OCI image index). A manifest list is not itself an image — it's an index that points at one real image per platform (`amd64`, `arm64`, etc.).

`falconutil patch-image` operates on a **single, concrete image**, not on a manifest list. If you point it at the top-level tag of a multi-arch manifest, it will either:

- Pick whichever arch happens to match the host running `falconutil` (usually `amd64`), silently producing only one arch and dropping the others; or
- Error out because it cannot patch an index.

To produce a patched image that works for **every architecture your ECS tasks may run on** (Fargate offers both `X86_64` and `ARM64`), you must:

1. `docker manifest inspect` both the source app image and the Falcon container image to extract the per-arch **digests** (`sha256:...`).
2. Run `falconutil patch-image` **once per architecture**, pinning both `--source-image-uri` and `--falcon-image-uri` by digest so the arches match (amd64 source ↔ amd64 falcon, arm64 source ↔ arm64 falcon).
3. Push each single-arch patched image with an arch-suffixed tag (`...-amd64`, `...-arm64`).
4. Reassemble a new multi-arch manifest list at the final tag (`...:1.0`) that references those single-arch patched images ([see the last section](#assemble--push-the-multi-arch-manifest-list)).

Skipping step 1 (pinning by digest) is the most common cause of ECS tasks failing with `exec format error` — the manifest list resolves to the wrong arch at runtime.

### Falcon container image (arch/manifest list)

```bash
docker manifest inspect <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container:7.38.0-7703
```

```json
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
    "manifests": [
        {
            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
            "size": 952,
            "digest": "sha256:caae39f6f6ebb994ad8dfdd970033708192aa4d2d9c96745732838d6d7135ab3",
            "platform": { "architecture": "amd64", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
            "size": 1158,
            "digest": "sha256:5ed74f2b62450525f1e1f573301583cb65730a7c1ff30b4eba56798ee9a1dac1",
            "platform": { "architecture": "arm64", "os": "linux" }
        }
    ]
}
```

### Source image (multi-arch OCI index)

```bash
docker manifest inspect <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine:1.0
```

Relevant per-arch digests (used later in the patch commands):

| Architecture   | Digest                                                                    |
| -------------- | ------------------------------------------------------------------------- |
| `amd64`        | `sha256:35cd77497979abe70dc8d26f5ae60811eea233a2eb5dc03c2ee30972caeb303e` |
| `arm/v6`       | `sha256:92c2048513fefba3277a597e0a27bea5641da51cc76e48aae92a8e65a5a1449b` |
| `arm/v7`       | `sha256:d4055a6df86f699d7265bebbb8ff50c41abc6df6deda0b77a1c5e27940723387` |
| `arm64/v8`     | `sha256:1ff5c7ff41c619b521f7a3bcfb52ff93354bb65a0141d7cdc0bf9702b12f8f82` |
| `386`          | `sha256:74906ffe0dd0c77014b1b9a4ffd263f4eda8dfb00ec752f871ee882883868658` |
| `ppc64le`      | `sha256:683fe2383cfea51cd89d12e38a531e63f7a012dffce4fa23117069adea47e759` |
| `riscv64`      | `sha256:37bf23d6a176f591d8f8903ec2b8418feb9e10408705b959472a17967cb20a26` |
| `s390x`        | `sha256:116aab8b90d3bd0df2c75de54f9c20198a81ae2c866ac3a132b33380a8a47174` |

<details>
<summary>Full <code>docker manifest inspect</code> JSON</summary>

```json
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2495,
            "digest": "sha256:35cd77497979abe70dc8d26f5ae60811eea233a2eb5dc03c2ee30972caeb303e",
            "platform": { "architecture": "amd64", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:0804539df4b4fda0036cc8ac46900ad5b52eb1d1921238dfd81116c1d22ebeed",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2497,
            "digest": "sha256:92c2048513fefba3277a597e0a27bea5641da51cc76e48aae92a8e65a5a1449b",
            "platform": { "architecture": "arm", "os": "linux", "variant": "v6" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 567,
            "digest": "sha256:7a404bb20e2e89f6211ff2a8c397e4d415899b362c334b162786a28c80c39ece",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2497,
            "digest": "sha256:d4055a6df86f699d7265bebbb8ff50c41abc6df6deda0b77a1c5e27940723387",
            "platform": { "architecture": "arm", "os": "linux", "variant": "v7" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:04abffa783271e21621f3c52e13c64626dfd64e132b377fb6ecbfe36ebd32e81",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2497,
            "digest": "sha256:1ff5c7ff41c619b521f7a3bcfb52ff93354bb65a0141d7cdc0bf9702b12f8f82",
            "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:44c3bc7ec85045003abe5898896271372c5660efc4d6f17f6d8003351a84b122",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2494,
            "digest": "sha256:74906ffe0dd0c77014b1b9a4ffd263f4eda8dfb00ec752f871ee882883868658",
            "platform": { "architecture": "386", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:1e4f184e5b27be5ddc71b0f8d098ca92d9e692b55e1ea83cd779afe2ea00ee3f",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2497,
            "digest": "sha256:683fe2383cfea51cd89d12e38a531e63f7a012dffce4fa23117069adea47e759",
            "platform": { "architecture": "ppc64le", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:edad0dd4c28b1126e0eddbc53c580f653b7a9573aa408d17a5a72a7a7b6f22b3",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2497,
            "digest": "sha256:37bf23d6a176f591d8f8903ec2b8418feb9e10408705b959472a17967cb20a26",
            "platform": { "architecture": "riscv64", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:9390aaf9766c76d4515eacf135294eb6a5c712c3db400aaeba584f038ea55f7c",
            "platform": { "architecture": "unknown", "os": "unknown" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 2495,
            "digest": "sha256:116aab8b90d3bd0df2c75de54f9c20198a81ae2c866ac3a132b33380a8a47174",
            "platform": { "architecture": "s390x", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "size": 840,
            "digest": "sha256:d5cf2fa41646d146405d8ea209429927a23a64fc662b0cdcceba4bbee32daef0",
            "platform": { "architecture": "unknown", "os": "unknown" }
        }
    ]
}
```

</details>

---

## Multi-Arch: Patch `amd64`

Here we use the **`amd64` variant of the `falcon-container` image** (pinned by its `amd64` digest `sha256:caae39...`) to patch the **`amd64` variant of the source application image** (pinned by its `amd64` digest `sha256:35cd77...`). Both sides of the patch operation must be the same architecture — mixing arches produces a broken image.

```bash
docker run --user 0:0 \
  --platform linux/amd64 \
  -v ${HOME}/.docker/config.json:/root/.docker/config.json \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --rm $MY_REPO:7.38.0-7703 \
  falconutil patch-image \
  --source-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine@sha256:35cd77497979abe70dc8d26f5ae60811eea233a2eb5dc03c2ee30972caeb303e \
  --target-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-amd64 \
  --falcon-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container@sha256:caae39f6f6ebb994ad8dfdd970033708192aa4d2d9c96745732838d6d7135ab3 \
  --cid <YOUR_FALCON_CID> \
  --image-pull-policy Always \
  --cloud-service ECS_FARGATE
```

Push the resulting `amd64` image:

```bash
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-amd64
```

---

## Multi-Arch: Patch `arm64`

Here we use the **`arm64` variant of the `falcon-container` image** (pinned by its `arm64` digest `sha256:5ed74f...`) to patch the **`arm64` variant of the source application image** (pinned by its `arm64/v8` digest `sha256:1ff5c7...`). Again — the `--source-image-uri` and `--falcon-image-uri` must both resolve to the same architecture.

```bash
docker run --user 0:0 \
  --platform linux/amd64 \
  -v ${HOME}/.docker/config.json:/root/.docker/config.json \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --rm $MY_REPO:7.38.0-7703 \
  falconutil patch-image \
  --source-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine@sha256:1ff5c7ff41c619b521f7a3bcfb52ff93354bb65a0141d7cdc0bf9702b12f8f82 \
  --target-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-arm64 \
  --falcon-image-uri <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container@sha256:5ed74f2b62450525f1e1f573301583cb65730a7c1ff30b4eba56798ee9a1dac1 \
  --cid <YOUR_FALCON_CID> \
  --image-pull-policy Always \
  --cloud-service ECS_FARGATE
```

Push the resulting `arm64` image:

```bash
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-arm64
```

> **Note:** `--platform linux/amd64` on the outer `docker run` refers to the container that *executes* `falconutil` (the amd64 build of the CLI runs fine under Rosetta / on x86 hosts). The architecture of the **patched output** is determined by the `--source-image-uri` / `--falcon-image-uri` digests, not by `--platform`.

---

## Verify Local Images After Multi-Arch Patching

After running both the `amd64` and `arm64` patch commands, `docker images` should show the following relevant entries (unrelated local images have been trimmed):

```text
IMAGE                                                                                                                          ID             DISK USAGE   CONTENT SIZE
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container:7.38.0-7703                                                 ff9adb74b2de   473MB        113MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container@sha256:caae39f6f6ebb994ad8dfdd970033708192aa4d2d9c96745732838d6d7135ab3   caae39f6f6eb   242MB        59MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/crwd/falcon-container@sha256:5ed74f2b62450525f1e1f573301583cb65730a7c1ff30b4eba56798ee9a1dac1   5ed74f2b6245   232MB        54.3MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine:1.0                                                            54f2a904c251   185MB        52.8MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine@sha256:35cd77497979abe70dc8d26f5ae60811eea233a2eb5dc03c2ee30972caeb303e     35cd77497979   92.4MB       26MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine@sha256:1ff5c7ff41c619b521f7a3bcfb52ff93354bb65a0141d7cdc0bf9702b12f8f82     1ff5c7ff41c6   91.7MB       25.9MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-amd64                                              9f3a2ad150fc   85.7MB       85.7MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-arm64                                              48e4898f6cb4   321MB        81.6MB
<AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0                                                    48e4898f6cb4   321MB        81.6MB
```

What each entry represents:

| Image | Role |
| --- | --- |
| `crwd/falcon-container:7.38.0-7703` | The Falcon container tag used to *run* `falconutil` (host arch). |
| `crwd/falcon-container@sha256:caae39...` | **amd64** variant of the Falcon container — used as `--falcon-image-uri` when patching amd64. |
| `crwd/falcon-container@sha256:5ed74f...` | **arm64** variant of the Falcon container — used as `--falcon-image-uri` when patching arm64. |
| `pulse/nginx-alpine:1.0` | Source (unpatched) app image, multi-arch tag. |
| `pulse/nginx-alpine@sha256:35cd77...` | **amd64** variant of the source app image — used as `--source-image-uri` when patching amd64. |
| `pulse/nginx-alpine@sha256:1ff5c7...` | **arm64** variant of the source app image — used as `--source-image-uri` when patching arm64. |
| `pulse/nginx-alpine-patched:1.0-amd64` | Output of the amd64 patch step. |
| `pulse/nginx-alpine-patched:1.0-arm64` | Output of the arm64 patch step. |
| `pulse/nginx-alpine-patched:1.0` | Output of the earlier **single-arch** patch step (host arch — may be dropped in a strict multi-arch flow). |

The two `@sha256:...` entries per repository are the by-digest pulls forced by `--image-pull-policy Always` combined with digest-pinned `--source-image-uri` / `--falcon-image-uri` — this is what guarantees the arches match up on each patch run.

---

## Assemble & Push the Multi-Arch Manifest List

### 1. Create the manifest list

```bash
docker manifest create \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0 \
  --amend <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-amd64 \
  --amend <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-arm64
```

### 2. Annotate each arch (optional but recommended)

```bash
docker manifest annotate \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0 \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-amd64 \
  --os linux --arch amd64

docker manifest annotate \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0 \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0-arm64 \
  --os linux --arch arm64
```

### 3. Push the manifest list

```bash
docker manifest push \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/pulse/nginx-alpine-patched:1.0
```

---

## Reminder: nginx-alpine and Falcon injection

The source image used above is `nginx-alpine`, which is a **musl (Alpine) libc** base. The sidecar/init-container injection pattern (`ld-linux-x86-64.so.2` + `entrypoint-ecs.sh`) requires **glibc**, so it will not work with Alpine. Pre-baking via `falconutil patch-image` is the supported approach when the target application must remain Alpine-based.
