import json
import os
import uuid

import boto3


sqs = boto3.client("sqs")

QUEUE_URL = os.environ["TELEMETRY_QUEUE_URL"]
ALLOWED_METRIC_TYPES = set(os.environ.get("ALLOWED_METRIC_TYPES", "").split(","))


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    tenant_header = (
        event.get("headers", {}).get("x-tenant-id")
        or event.get("headers", {}).get("X-Tenant-Id")
    )

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        correlation_id = (
            event.get("headers", {}).get("x-correlation-id")
            or event.get("headers", {}).get("X-Correlation-Id")
            or str(uuid.uuid4())
        )
        return response(400, {"error": "invalid_json", "correlation_id": correlation_id})

    correlation_id = (
        body.get("correlation_id")
        or event.get("headers", {}).get("x-correlation-id")
        or event.get("headers", {}).get("X-Correlation-Id")
        or str(uuid.uuid4())
    )

    required_fields = ["ts", "tenant_id", "service_id", "metric_type", "value"]
    missing = [field for field in required_fields if field not in body]
    if missing:
        return response(
            400,
            {
                "error": "missing_required_fields",
                "fields": missing,
                "correlation_id": correlation_id,
            },
        )

    if tenant_header and tenant_header != body["tenant_id"]:
        return response(403, {"error": "tenant_mismatch", "correlation_id": correlation_id})

    if body["metric_type"] not in ALLOWED_METRIC_TYPES:
        return response(400, {"error": "unsupported_metric_type", "correlation_id": correlation_id})

    # Minimal PII guard for placeholder. Full validation should be implemented in production Lambda.
    labels = body.get("labels", {})
    pii_keys = {"email", "phone", "name"}
    if any(key.lower() in pii_keys for key in labels.keys()):
        return response(400, {"error": "pii_detected", "correlation_id": correlation_id})

    body["correlation_id"] = correlation_id

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(body),
        MessageAttributes={
            "tenant_id": {
                "DataType": "String",
                "StringValue": body["tenant_id"],
            },
            "service_id": {
                "DataType": "String",
                "StringValue": body["service_id"],
            },
            "metric_type": {
                "DataType": "String",
                "StringValue": body["metric_type"],
            },
            "correlation_id": {
                "DataType": "String",
                "StringValue": correlation_id,
            },
        },
    )

    return response(202, {"status": "accepted", "correlation_id": correlation_id})
