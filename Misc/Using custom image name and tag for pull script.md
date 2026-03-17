# Using Custom Image Name and Tag for Pull Script

## Overview

The registry namespace is mandatory and is not the same as the image name. In this example, the image name is **custom-sensor** and image tag is **v1.2.3-production**.

## Example Usage

```bash
./falcon-container-sensor-pull.sh \
  --client-id <FALCON_CLIENT_ID> \
  --client-secret <FALCON_CLIENT_SECRET> \
  --type falcon-sensor \
  --copy myregistry.com/mynamespace/custom-sensor \
  --copy-omit-image-name \
  --copy-custom-tag v1.2.3-production
```

This results in the image: `myregistry.com/mynamespace/custom-sensor:v1.2.3-production`

## References

- [Falcon Container Sensor Pull Script](https://github.com/CrowdStrike/falcon-scripts/tree/main/bash/containers/falcon-container-sensor-pull)