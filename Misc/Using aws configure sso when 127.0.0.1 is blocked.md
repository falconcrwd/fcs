# Using AWS Configure SSO When 127.0.0.1 is Blocked

When the default localhost address is blocked in your environment, you can use the device code flow for AWS SSO authentication.

## Usage

```bash
aws configure sso --use-device-code
```

## Configuration Process

Follow the prompts and provide the required information:

```bash
[ec2-user@ip-<IP_ADDRESS> ~]$ aws configure sso --use-device-code
SSO session name (Recommended): <SESSION_NAME>
SSO start URL [None]: https://<SSO_URL>/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]:
Attempting to open your default browser.
If the browser does not open or you wish to use a different device to authorize this request, open the following URL:

https://<SSO_URL>/start/#/device

Then enter the code:

<DEVICE_CODE>
```

This method allows you to complete the SSO authentication process using a different device when localhost access is restricted.