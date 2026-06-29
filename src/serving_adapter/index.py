import json
import os
import time
import uuid
import hashlib
import hmac
import urllib.request
import urllib.error
from datetime import datetime, timezone
from urllib.parse import urlparse
import boto3

lambda_client = boto3.client("lambda")
fallback_lambda_name = os.environ["FALLBACK_LAMBDA_NAME"]
ai_engine_endpoint = os.environ["AI_ENGINE_ENDPOINT"]


def handler(event, context):
    correlation_id = event.get("correlation_id", str(uuid.uuid4()))
    tenant_id = event.get("tenant_id")
    service_id = event.get("service_id")
    signal_window = event.get("signal_window")
    context_data = event.get("context")

    log_event("serving_adapter_started", {
        "correlation_id": correlation_id
    })

    retry_delays = [1, 2, 4]  # bounded retry
    last_error = None

    for i, delay in enumerate(retry_delays):
        try:
            response = call_ai_engine(signal_window, context_data, tenant_id, correlation_id)
            log_event("ai_engine_success", {
                "correlation_id": correlation_id
            })
            return response
        except Exception as e:
            last_error = e
            log_event("ai_engine_retry", {
                "correlation_id": correlation_id,
                "attempt": i + 1,
                "error": str(e)
            })
            if i < len(retry_delays) - 1:
                time.sleep(delay)

    # Nếu hết retry, gọi fallback
    log_event("fallback_triggered", {
        "correlation_id": correlation_id
    })
    return invoke_fallback(event)


def call_ai_engine(signal_window, context_data, tenant_id, correlation_id):
    url = f"{ai_engine_endpoint}/v1/predict"
    payload = json.dumps({
        "signal_window": signal_window,
        "context": context_data
    }).encode("utf-8")

    headers = build_headers(payload, tenant_id, correlation_id)
    signed_headers = sign_aws_request("POST", url, payload, headers)

    request = urllib.request.Request(url, data=payload, headers=signed_headers, method="POST")

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        if e.code in [429, 503]:
            raise Exception(f"AI Engine returned {e.code}")
        raise


def build_headers(payload, tenant_id, correlation_id):
    return {
        "Content-Type": "application/json",
        "X-Tenant-Id": tenant_id,
        "X-Correlation-Id": correlation_id,
        "X-Amz-Content-Sha256": hashlib.sha256(payload).hexdigest()
    }


def sign_aws_request(method, endpoint, payload, headers):
    # Tham khảo hàm sign_aws_request trong src/writer/handler.py
    parsed_url = urlparse(endpoint)
    region = os.environ.get("AWS_REGION") or "us-east-1"
    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    session_token = os.environ.get("AWS_SESSION_TOKEN")

    request_time = datetime.now(timezone.utc)
    amz_date = request_time.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = request_time.strftime("%Y%m%d")

    signed_headers = {
        **headers,
        "Host": parsed_url.netloc,
        "X-Amz-Date": amz_date,
    }
    if session_token:
        signed_headers["X-Amz-Security-Token"] = session_token

    canonical_headers, signed_header_names = build_canonical_headers(signed_headers)
    canonical_request = "\n".join([
        method,
        parsed_url.path or "/",
        parsed_url.query,
        canonical_headers,
        signed_header_names,
        hashlib.sha256(payload).hexdigest(),
    ])

    credential_scope = f"{date_stamp}/{region}/execute-api/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])

    signing_key = get_signature_key(secret_key, date_stamp, region, "execute-api")
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    signed_headers["Authorization"] = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_header_names}, "
        f"Signature={signature}"
    )
    return signed_headers


def build_canonical_headers(headers):
    canonical = []
    for name, value in headers.items():
        canonical.append((name.lower(), " ".join(str(value).strip().split())))
    canonical.sort()
    canonical_headers = "".join(f"{name}:{value}\n" for name, value in canonical)
    signed_header_names = ";".join(name for name, _ in canonical)
    return canonical_headers, signed_header_names


def get_signature_key(secret_key, date_stamp, region, service):
    date_key = hmac_sha256(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    region_key = hmac_sha256(date_key, region)
    service_key = hmac_sha256(region_key, service)
    return hmac_sha256(service_key, "aws4_request")


def hmac_sha256(key, message):
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def invoke_fallback(event):
    response = lambda_client.invoke(
        FunctionName=fallback_lambda_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(event)
    )
    return json.loads(response["Payload"].read())


def log_event(event_name, details):
    print(json.dumps({
        "component": "serving-adapter-lambda",
        "event": event_name,
        **details
    }))