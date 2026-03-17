# FCS CLI Local Image Scanning

## Overview

FCS CLI can be installed locally on a machine, and configured to scan images and upload results to Falcon Cloud. The instructions are available at the [official documentation](https://docs.crowdstrike.com/r/h84b14a4).

## Prerequisites

- Docker or equivalent container runtime should be installed on the machine with FCS CLI
- API client ID and secret needs to be created in Falcon portal with the appropriate scopes

## Example Usage

The following command will upload the results of the image scan to Falcon portal, where the source will be shown as from CLI:

```bash
fcs scan image quay.io/crowdstrike/vulnapp --client-id=<CLIENT_ID> --client-secret=<CLIENT_SECRET> --upload
```