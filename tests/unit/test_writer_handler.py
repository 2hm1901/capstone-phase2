import json
import os
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DIR / "src" / "writer"))

import handler as writer_handler  # noqa: E402


def make_record(message_id, payload):
    return {
        "messageId": message_id,
        "body": json.dumps(payload),
    }


def valid_payload(**overrides):
    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "tenant-cdo08-demo",
        "service_id": "payment-api",
        "metric_type": "api_latency_ms",
        "value": 450.5,
        "labels": {"region": "us-east-1"},
    }
    payload.update(overrides)
    return payload


def test_handler_accepts_valid_record(monkeypatch):
    monkeypatch.setenv(
        "ALLOWED_PROMETHEUS_LABELS",
        "region,db_type,queue_name,cache_type,environment,instance_id",
    )
    monkeypatch.setattr(writer_handler, "remote_write_samples", lambda samples: None)

    event = {"Records": [make_record("msg-1", valid_payload())]}

    response = writer_handler.handler(event, None)

    assert response == {"batchItemFailures": []}


def test_handler_returns_partial_batch_failures(monkeypatch):
    monkeypatch.setenv("ALLOWED_PROMETHEUS_LABELS", "region")
    monkeypatch.setattr(writer_handler, "remote_write_samples", lambda samples: None)
    event = {
        "Records": [
            make_record("msg-valid", valid_payload()),
            make_record("msg-missing", valid_payload(service_id="")),
            make_record(
                "msg-blocked-label",
                valid_payload(labels={"region": "us-east-1", "request_id": "req-1"}),
            ),
        ]
    }

    response = writer_handler.handler(event, None)

    assert response == {
        "batchItemFailures": [
            {"itemIdentifier": "msg-missing"},
            {"itemIdentifier": "msg-blocked-label"},
        ]
    }


def test_parse_record_body_rejects_invalid_json():
    record = {
        "messageId": "msg-invalid-json",
        "body": "{not-json",
    }

    response = writer_handler.handler({"Records": [record]}, None)

    assert response == {
        "batchItemFailures": [{"itemIdentifier": "msg-invalid-json"}]
    }


def test_handler_fails_valid_records_when_remote_write_fails(monkeypatch):
    def fail_remote_write(samples):
        raise writer_handler.RemoteWriteError("remote_write_http_503")

    monkeypatch.setattr(writer_handler, "remote_write_samples", fail_remote_write)
    event = {"Records": [make_record("msg-1", valid_payload())]}

    response = writer_handler.handler(event, None)

    assert response == {"batchItemFailures": [{"itemIdentifier": "msg-1"}]}


def test_normalize_telemetry_payload_maps_to_prometheus_sample(monkeypatch):
    monkeypatch.delenv("ALLOWED_PROMETHEUS_LABELS", raising=False)
    sample = writer_handler.normalize_telemetry_payload(valid_payload())

    assert sample["metric_name"] == "api_latency_ms"
    assert sample["value"] == 450.5
    assert sample["timestamp_ms"] == 1782383400000
    assert sample["labels"] == {
        "tenant_id": "tenant-cdo08-demo",
        "service_id": "payment-api",
        "metric_type": "api_latency_ms",
        "region": "us-east-1",
    }


def test_encode_write_request_returns_protobuf_bytes(monkeypatch):
    sample = writer_handler.normalize_telemetry_payload(valid_payload())

    encoded = writer_handler.encode_write_request([sample])

    assert isinstance(encoded, bytes)
    assert b"api_latency_ms" in encoded
    assert b"tenant-cdo08-demo" in encoded
    assert b"payment-api" in encoded


def test_snappy_compress_uses_raw_snappy_literal_block():
    compressed = writer_handler.snappy_compress(b"abc")

    assert compressed == b"\x03\x08abc"


def test_sign_aws_request_adds_sigv4_headers(monkeypatch):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIAEXAMPLE")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "secret")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "token")

    signed_headers = writer_handler.sign_aws_request(
        "POST",
        "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-123/api/v1/remote_write",
        b"payload",
        writer_handler.build_remote_write_headers(b"payload"),
    )

    assert signed_headers["Authorization"].startswith("AWS4-HMAC-SHA256 ")
    assert signed_headers["X-Amz-Date"]
    assert signed_headers["X-Amz-Security-Token"] == "token"
    assert signed_headers["Host"] == "aps-workspaces.us-east-1.amazonaws.com"
