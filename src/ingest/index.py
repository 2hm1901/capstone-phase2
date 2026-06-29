import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3


logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")

QUEUE_URL = os.environ["TELEMETRY_QUEUE_URL"]
ALLOWED_METRIC_TYPES = {
    metric.strip()
    for metric in os.environ.get("ALLOWED_METRIC_TYPES", "").split(",")
    if metric.strip()
}


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def log_validation_failed(reason, correlation_id, **safe_context):
    log_body = {
        "event": "telemetry_validation_failed",
        "reason": reason,
        "correlation_id": correlation_id,
    }
    log_body.update({key: value for key, value in safe_context.items() if value is not None})
    logger.info(json.dumps(log_body))


def log_validation_passed(correlation_id, tenant_id, service_id, metric_type):
    logger.info(
        json.dumps(
            {
                "event": "telemetry_validation_passed",
                "correlation_id": correlation_id,
                "tenant_id": tenant_id,
                "service_id": service_id,
                "metric_type": metric_type,
            }
        )
    )


def is_valid_iso_timestamp(value):
    if not isinstance(value, str):
        return False

    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
        return parsed.tzinfo is not None
    except ValueError:
        return False


def handler(event, context):
    headers = event.get("headers") or {}
    tenant_header = headers.get("x-tenant-id") or headers.get("X-Tenant-Id")
    header_correlation_id = headers.get("x-correlation-id") or headers.get("X-Correlation-Id")

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        correlation_id = header_correlation_id or str(uuid.uuid4())
        log_validation_failed("invalid_json", correlation_id)
        return response(400, {"error": "invalid_json", "correlation_id": correlation_id})

    correlation_id = body.get("correlation_id") or header_correlation_id or str(uuid.uuid4())

    required_fields = [
        "ts",
        "tenant_id",
        "service_id",
        "metric_type",
        "value",
        "labels",
        "schema_version",
        "correlation_id",
    ]

    missing = [field for field in required_fields if field not in body]
    if missing:
        log_validation_failed("missing_required_fields", correlation_id)
        return response(
            400,
            {
                "error": "missing_required_fields",
                "fields": missing,
                "correlation_id": correlation_id,
            },
        )

    if tenant_header and tenant_header != body["tenant_id"]:
        log_validation_failed(
            "tenant_mismatch",
            correlation_id,
            tenant_id=body.get("tenant_id"),
        )
        return response(403, {"error": "tenant_mismatch", "correlation_id": correlation_id})

    if body["metric_type"] not in ALLOWED_METRIC_TYPES:
        log_validation_failed(
            "unsupported_metric_type",
            correlation_id,
            tenant_id=body.get("tenant_id"),
            service_id=body.get("service_id"),
            metric_type=body.get("metric_type"),
        )
        return response(400, {"error": "unsupported_metric_type", "correlation_id": correlation_id})

    if not isinstance(body["labels"], dict):
        log_validation_failed(
            "invalid_labels",
            correlation_id,
            tenant_id=body.get("tenant_id"),
            service_id=body.get("service_id"),
            metric_type=body.get("metric_type"),
        )
        return response(400, {"error": "invalid_labels", "correlation_id": correlation_id})

    if not isinstance(body["value"], (int, float)) or isinstance(body["value"], bool):
        log_validation_failed(
            "invalid_value",
            correlation_id,
            tenant_id=body.get("tenant_id"),
            service_id=body.get("service_id"),
            metric_type=body.get("metric_type"),
        )
        return response(400, {"error": "invalid_value", "correlation_id": correlation_id})

    if not is_valid_iso_timestamp(body["ts"]):
        log_validation_failed(
            "invalid_timestamp",
            correlation_id,
            tenant_id=body.get("tenant_id"),
            service_id=body.get("service_id"),
            metric_type=body.get("metric_type"),
        )
        return response(400, {"error": "invalid_timestamp", "correlation_id": correlation_id})

    pii_keys = {"email", "phone", "name", "password", "token", "secret"}
    if any(key.lower() in pii_keys for key in body["labels"].keys()):
        log_validation_failed(
            "pii_detected",
            correlation_id,
            tenant_id=body.get("tenant_id"),
            service_id=body.get("service_id"),
            metric_type=body.get("metric_type"),
        )
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

    log_validation_passed(
        correlation_id,
        body["tenant_id"],
        body["service_id"],
        body["metric_type"],
    )

    return response(202, {"status": "accepted", "correlation_id": correlation_id})