# Using falconpull script on Azure cloud shell to copy images from CRWD registry to Azure Container Registry
This example shows how to log into Azure Container Registry from cloud shell, then download and use falconpull script to copy images from CRWD registry to ACR

## Pre-requisites:
- you should have AcrPull and AcrPush permissions on the registry

## Step 1 - log into Azure from cloud shell
This step may not be required, just check that you are logged in already via **az account show** command first. 
```bash
az login
```

## Step 2 - log into ACR
Get the refreshToken to log into Azure Container Registry
```bash
az acr login -n <AZURE_CONTAINER_REGISTRY_NAME> --expose-token
Note: The token in both the accessToken and refreshToken fields is an ACR Refresh Token, not an ACR Access Token. This ACR Refresh Token cannot be used directly to authenticate with registry APIs such as pushing/pulling images and listing repositories/tags. This ACR Refresh Token must be subsequently exchanged for an ACR Access.Please see https://aka.ms/acr/auth/oauth
You can perform manual login using the provided refresh token below, for example: 'docker login loginServer -u 00000000-0000-0000-0000-000000000000 -p refreshToken'
{
  "accessToken": "ACCESS_TOKEN_VALUE",
  "loginServer": "ACRNAME-RANDOMSTRING.azurecr.io",
  "refreshToken": "REFRESH_TOKEN_VALUE",
  "username": "00000000-0000-0000-0000-000000000000"
}
```

```bash
export refreshToken="REFRESH_TOKEN_VALUE"
```

```bash
export loginServer="ACRNAME-RANDOMSTRING.azurecr.io"
```

```bash
docker login $loginServer -u 00000000-0000-0000-0000-000000000000 -p $refreshToken
```

## Step 3 - export Falcon API client and secret. Ensure the right API scopes are assigned
On portal, go to:
Support and resources > Resources and tools > API clients and keys and create an API client key and secret with the below scopes:
- Falcon Images Download (read)
- Sensor Download (read)
- Falcon Container Image (Read/Write)
- Falcon Container CLI (Read/Write)

Export the client id and secret into environment
```bash
export FALCON_CLIENT_ID="<YOUR_FALCON_CLIENT_ID>"
export FALCON_CLIENT_SECRET="<YOUR_FALCON_CLIENT_SECRET>"
```

## Step 4 - download and run the pull script
Download pull script and change its permissions to be executable
```bash
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"

chmod +x falcon-container-sensor-pull.sh
```

**Download Falcon Sensor and copy to ACR**
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-sensor \
  -c ACRNAME-RANDOMSTRING.azurecr.io
```

**Download Falcon KAC and copy to ACR**	
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-kac \
  -c ACRNAME-RANDOMSTRING.azurecr.io
```
**Download Falcon ImageAnalyzer and copy to ACR**
```bash	
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-imageanalyzer \
  -c ACRNAME-RANDOMSTRING.azurecr.io	
```	

**Download Falcon Container and copy to ACR**
```bash
./falcon-container-sensor-pull.sh \
  --client-id ${FALCON_CLIENT_ID} \
  --client-secret ${FALCON_CLIENT_SECRET} \
  --type falcon-container \
  -c ACRNAME-RANDOMSTRING.azurecr.io		
```  