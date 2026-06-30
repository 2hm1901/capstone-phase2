import json
import os
import time
import uuid
import urllib.request
import urllib.error
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

    headers = build_headers(tenant_id, correlation_id)

    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        if e.code in [429, 503]:
            raise Exception(f"AI Engine returned {e.code}")
        raise


def build_headers(tenant_id, correlation_id):
    return {
        "Content-Type": "application/json",
        "X-Tenant-Id": tenant_id,
        "X-Correlation-Id": correlation_id
    }


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
