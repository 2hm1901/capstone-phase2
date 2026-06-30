#!/usr/bin/env python3
import os
import sys
import json
import uuid
import subprocess
from datetime import datetime, timezone
import urllib.request
import urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

def get_tf_output():
    endpoint = os.environ.get("INGEST_API_ENDPOINT")
    if endpoint:
        return endpoint
        
    try:
        res = subprocess.run(
            ["terraform", "-chdir=infra/environments/sandbox", "output", "-json"],
            capture_output=True,
            text=True,
            check=True
        )
        outputs = json.loads(res.stdout)
        if "ingest_api_endpoint" in outputs and outputs["ingest_api_endpoint"]["value"]:
            return outputs["ingest_api_endpoint"]["value"]
    except Exception:
        pass
        
    try:
        client = boto3.client("apigatewayv2")
        apis = client.get_apis()
        for api in apis.get("Items", []):
            if "cdo08" in api.get("Name", ""):
                api_endpoint = api.get("ApiEndpoint")
                return f"{api_endpoint}/sandbox/v1/telemetry"
    except Exception as e:
        print(f"Error querying API Gateway via boto3: {e}")
        
    print("Please configure INGEST_API_ENDPOINT env variable or make sure you ran terraform plan/init.")
    sys.exit(1)

def send_request_with_sigv4(url, payload, region="us-east-1"):
    data_bytes = json.dumps(payload).encode("utf-8")
    correlation_id = payload["correlation_id"]
    
    headers = {
        "Content-Type": "application/json",
        "X-Tenant-Id": payload["tenant_id"],
        "X-Correlation-Id": correlation_id
    }
    
    session = boto3.Session()
    credentials = session.get_credentials()
    frozen_creds = credentials.get_frozen_credentials() if credentials else None
    
    if frozen_creds:
        request = AWSRequest(
            method="POST",
            url=url,
            data=data_bytes,
            headers=headers
        )
        auth = SigV4Auth(frozen_creds, "execute-api", region)
        auth.add_auth(request)
        signed_headers = dict(request.headers)
    else:
        signed_headers = headers

    req = urllib.request.Request(
        url=url,
        data=data_bytes,
        headers=signed_headers,
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            res_body = response.read().decode("utf-8")
            return response.status, res_body
    except urllib.error.HTTPError as error:
        res_body = error.read().decode("utf-8") if error else ""
        return error.code, res_body
    except Exception as error:
        return 500, str(error)

def main():
    print("Retrieving Ingest API endpoint...")
    endpoint = get_tf_output()
    print(f"Found Ingest API Endpoint: {endpoint}")
    
    correlation_id = str(uuid.uuid4())
    payload = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "tenant_id": "tenant-cdo08-demo",
        "service_id": "payment-gw",
        "metric_type": "api_latency_ms",
        "value": 150.5,
        "labels": {"region": "us-east-1", "environment": "sandbox"},
        "schema_version": "v1.0",
        "correlation_id": correlation_id
    }
    
    print(f"Sending smoke test payload: {json.dumps(payload, indent=2)}")
    status, response_body = send_request_with_sigv4(endpoint, payload)
    
    print(f"HTTP Response Status: {status}")
    print(f"HTTP Response Body: {response_body}")
    
    if status in (200, 201, 202):
        print("Smoke test successfully processed!")
        sys.exit(0)
    else:
        print("Smoke test failed!")
        sys.exit(1)

if __name__ == "__main__":
    main()
