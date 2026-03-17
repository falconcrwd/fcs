# Using Event Streams API

This guide demonstrates how to retrieve events using the CrowdStrike Event Streams API.

## Step 1 - Create API Client Credentials

Ensure client ID and secret have been created in Falcon Portal with the appropriate permissions and scopes.
See the [CrowdStrike OAuth2 API documentation](https://falcon.crowdstrike.com/documentation/page/a2a7fc0e/crowdstrike-oauth2-based-apis) for detailed instructions.

**Requirements:**
- API client must have **Read** access to **Event Streams**
- Ensure proper scope configuration for your use case

## Step 2 - Obtain OAuth2 Bearer Token

Sign into the Falcon portal and navigate to the appropriate swagger URL for your API cloud environment. See the [CrowdStrike OAuth2 API documentation](https://falcon.crowdstrike.com/documentation/page/a2a7fc0e/crowdstrike-oauth2-based-apis) for detailed instructions.

**Swagger URLs by Cloud:**
- **US-1:** https://assets.falcon.crowdstrike.com/support/api/swagger.html
- **US-2:** https://assets.falcon.us-2.crowdstrike.com/support/api/swagger-us2.html
- **EU-1:** https://assets.falcon.eu-1.crowdstrike.com/support/api/swagger-eu.html
- **US-GOV-1:** https://assets.falcon.laggar.gcw.crowdstrike.com/support/api/swagger-eagle.html
- **US-GOV-2:** https://assets.falcon.us-gov-2.crowdstrike.mil/support/api/swagger.html

**Process:**
1. Look for **/oauth2/token** with POST action
2. Click **Try it out**
3. Fill in your **client_id** and **client_secret**
4. Click Execute

You will receive a bearer token valid for 30 minutes:

```json
{
  "access_token": "<BEARER_TOKEN>",
  "expires_in": 1799,
  "token_type": "bearer"
}
```

## Step 3 - Discover Available Streams

Use the bearer token from Step 2 to discover available data streams:

```bash
curl -X GET "https://api.crowdstrike.com/sensors/entities/datafeed/v2?appId=<YOUR_APP_ID>" \
 -H 'Authorization: bearer <BEARER_TOKEN>' \
 -H 'Accept: application/json'
```

**Response:**

```json
{
 "resources": [
  {
   "dataFeedURL": "https://firehose.crowdstrike.com/sensors/entities/datafeed/v1/0?appId=<YOUR_APP_ID>",
   "sessionToken": {
    "token": "<SESSION_TOKEN>",
    "expiration": "2026-02-13T05:20:57.826373335Z"
   },
   "refreshActiveSessionURL": "https://api.crowdstrike.com/sensors/entities/datafeed-actions/v1/0?appId=<YOUR_APP_ID>&action_name=refresh_active_stream_session",
   "refreshActiveSessionInterval": 1800
  }
 ],
 "meta": {
  "query_time": 0.001088349,
  "powered_by": "FalconHose",
  "trace_id": "<TRACE_ID>"
 }
}
```

## Step 4 - Connect to the Event Stream

Use the **dataFeedURL** and **sessionToken** from Step 3 to connect to the stream:

```bash
curl -X GET "https://firehose.crowdstrike.com/sensors/entities/datafeed/v1/0?appId=<YOUR_APP_ID>&offset=<OFFSET_NUMBER>" \
  -H 'Accept: application/json' \
  -H 'Authorization: Token <SESSION_TOKEN>'
```

## Step 5 - View Streaming Events

After connecting, the terminal may initially appear to hang, but you should see responses from the API endpoint. This represents the Kinesis Firehose data stream.

**Example Event Structure:**

```json
{
  "metadata": {
    "customerIDString": "<CUSTOMER_ID>",
    "offset": 28,
    "eventType": "APIActivityAuditEvent",
    "eventCreationTime": 1770959918709,
    "version": "1.0"
  },
  "event": {
    "UserId": "",
    "UserIp": "<IP_ADDRESS>",
    "OperationName": "logged",
    "ServiceName": "api_request",
    "Success": true,
    "UTCTimestamp": 1770959918,
    "Attributes": {
      "APIClientID": "<API_CLIENT_ID>",
      "cid": "<CUSTOMER_ID>",
      "consumes": "application/x-www-form-urlencoded,text/html",
      "elapsed_microseconds": "92686",
      "elapsed_time": "92.686765ms",
      "produces": "application/json",
      "received_time": "2026-02-13T05:18:38.616693834Z",
      "request_content_type": "application/x-www-form-urlencoded",
      "request_method": "POST",
      "request_path": "/oauth2/token",
      "request_uri_length": "13",
      "status_code": "201",
      "sub_component_1": "logged",
      "sub_component_2": "POST /oauth2/token",
      "sub_component_3": "us-1",
      "trace_id": "<TRACE_ID>",
      "user_agent": "Go-http-client/1.1",
      "user_ip": "<IP_ADDRESS>"
    },
    "Message": "",
    "Source": "api_request",
    "SourceIp": "<IP_ADDRESS>",
    "AuditKeyValues": [
      {"Key": "consumes", "ValueString": "application/x-www-form-urlencoded,text/html"},
      {"Key": "request_path", "ValueString": "/oauth2/token"},
      {"Key": "produces", "ValueString": "application/json"},
      {"Key": "received_time", "ValueString": "2026-02-13T05:18:38.616693834Z"},
      {"Key": "trace_id", "ValueString": "<TRACE_ID>"},
      {"Key": "status_code", "ValueString": "201"},
      {"Key": "elapsed_time", "ValueString": "92.686765ms"},
      {"Key": "cid", "ValueString": "<CUSTOMER_ID>"},
      {"Key": "request_content_type", "ValueString": "application/x-www-form-urlencoded"},
      {"Key": "sub_component_3", "ValueString": "us-1"},
      {"Key": "sub_component_1", "ValueString": "logged"},
      {"Key": "user_agent", "ValueString": "Go-http-client/1.1"},
      {"Key": "request_uri_length", "ValueString": "13"},
      {"Key": "request_method", "ValueString": "POST"},
      {"Key": "sub_component_2", "ValueString": "POST /oauth2/token"},
      {"Key": "user_ip", "ValueString": "<IP_ADDRESS>"},
      {"Key": "elapsed_microseconds", "ValueString": "92686"},
      {"Key": "APIClientID", "ValueString": "<API_CLIENT_ID>"}
    ]
  }
}
```

**Common Event Fields:**

Detection events may include additional sensitive fields that should be handled appropriately:

- **AgentId**: `<AGENT_ID>`
- **CompositeId**: `<COMPOSITE_ID>`
- **FalconHostLink**: Detection links with sanitized identifiers
- **ContainerId**: `<CONTAINER_ID>`
- **HostGroups**: `<HOST_GROUP_ID>`

> **Security Note:** All sensitive identifiers in actual stream output are confidential and should be replaced with appropriate placeholders for documentation purposes.

## References

- [Event Streams API Documentation](https://falcon.crowdstrike.com/documentation/page/ddad2900/event-streams-apis)
- [CrowdStrike OAuth2 API Documentation](https://falcon.crowdstrike.com/documentation/page/a2a7fc0e/crowdstrike-oauth2-based-apis)