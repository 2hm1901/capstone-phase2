import json
import os
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DIR / "src" / "ingest"))

os.environ.setdefault("TELEMETRY_QUEUE_URL", "https://queue-url")
os.environ.setdefault("ALLOWED_METRIC_TYPES", "api_latency_ms")

import index as ingest_handler  # noqa: E402


def make_event(body, headers=None):
    return {
        "headers": headers or {},
        "body": json.dumps(body),
    }


def valid_payload(**overrides):
    payload = {
        "schema_version": "v1.0",
        "correlation_id": "corr-valid-001",
        "ts": "2026-06-29T10:30:00.000Z",
        "tenant_id": "tenant-cdo08-demo",
        "service_id": "payment-api",
        "metric_type": "api_latency_ms",
        "value": 450.5,
        "labels": {"region": "us-east-1"},
    }
    payload.update(overrides)
    return payload


def test_handler_accepts_valid_payload(monkeypatch):
    monkeypatch.setenv("TELEMETRY_QUEUE_URL", "https://queue-url")
    monkeypatch.setenv("ALLOWED_METRIC_TYPES", "api_latency_ms")

    called = {}

    def fake_send_message(QueueUrl, MessageBody, MessageAttributes):
        called["sent"] = True
        assert QueueUrl == "https://queue-url"
        assert json.loads(MessageBody)["metric_type"] == "api_latency_ms"
        assert MessageAttributes["tenant_id"]["StringValue"] == "tenant-cdo08-demo"

    monkeypatch.setattr(ingest_handler.sqs, "send_message", fake_send_message)

    response = ingest_handler.handler(
        make_event(valid_payload(), headers={"X-Tenant-Id": "tenant-cdo08-demo"}), None
    )

    assert response["statusCode"] == 202
    assert json.loads(response["body"])["correlation_id"] == "corr-valid-001"
    assert called.get("sent") is True


def test_handler_rejects_unknown_metric_type(monkeypatch):
    monkeypatch.setenv("TELEMETRY_QUEUE_URL", "https://queue-url")
    monkeypatch.setenv("ALLOWED_METRIC_TYPES", "api_latency_ms")
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(metric_type="not_in_contract"),
            headers={"X-Tenant-Id": "tenant-cdo08-demo"},
        ),
        None,
    )

    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"] == "unsupported_metric_type"
    assert body["correlation_id"] == "corr-valid-001"


def test_handler_rejects_tenant_mismatch(monkeypatch):
    monkeypatch.setenv("TELEMETRY_QUEUE_URL", "https://queue-url")
    monkeypatch.setenv("ALLOWED_METRIC_TYPES", "api_latency_ms")
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(tenant_id="tenant-b"),
            headers={"X-Tenant-Id": "tenant-a"},
        ),
        None,
    )

    assert response["statusCode"] == 403
    assert json.loads(response["body"])["error"] == "tenant_mismatch"


def test_handler_rejects_pii_labels(monkeypatch):
    monkeypatch.setenv("TELEMETRY_QUEUE_URL", "https://queue-url")
    monkeypatch.setenv("ALLOWED_METRIC_TYPES", "api_latency_ms")
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(labels={"region": "us-east-1", "email": "user@example.com"}),
            headers={"X-Tenant-Id": "tenant-cdo08-demo"},
        ),
        None,
    )

    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"] == "pii_detected"


def test_handler_rejects_invalid_json(monkeypatch):
    monkeypatch.setenv("TELEMETRY_QUEUE_URL", "https://queue-url")
    monkeypatch.setenv("ALLOWED_METRIC_TYPES", "api_latency_ms")
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    event = {"headers": {"X-Tenant-Id": "tenant-cdo08-demo"}, "body": "{not json"}
    response = ingest_handler.handler(event, None)

    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"] == "invalid_json"

def test_handler_rejects_missing_schema_version(monkeypatch):
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    payload = valid_payload()
    payload.pop("schema_version")

    response = ingest_handler.handler(
        make_event(payload, headers={"X-Tenant-Id": "tenant-cdo08-demo"}),
        None,
    )

    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"] == "missing_required_fields"
    assert "schema_version" in body["fields"]


def test_handler_rejects_missing_correlation_id(monkeypatch):
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    payload = valid_payload()
    payload.pop("correlation_id")

    response = ingest_handler.handler(
        make_event(payload, headers={"X-Tenant-Id": "tenant-cdo08-demo"}),
        None,
    )

    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"] == "missing_required_fields"
    assert "correlation_id" in body["fields"]


def test_handler_rejects_labels_not_object(monkeypatch):
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(labels="not-object"),
            headers={"X-Tenant-Id": "tenant-cdo08-demo"},
        ),
        None,
    )

    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"] == "invalid_labels"


def test_handler_rejects_value_not_number(monkeypatch):
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(value="450.5"),
            headers={"X-Tenant-Id": "tenant-cdo08-demo"},
        ),
        None,
    )

    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"] == "invalid_value"


def test_handler_rejects_invalid_timestamp(monkeypatch):
    monkeypatch.setattr(
        ingest_handler.sqs,
        "send_message",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("should not send")),
    )

    response = ingest_handler.handler(
        make_event(
            valid_payload(ts="not-a-timestamp"),
            headers={"X-Tenant-Id": "tenant-cdo08-demo"},
        ),
        None,
    )

    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"] == "invalid_timestamp"
