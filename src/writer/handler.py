import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse


REQUIRED_FIELDS = ("ts", "tenant_id", "service_id", "metric_type", "value")
PROMETHEUS_REMOTE_WRITE_VERSION = "0.1.0"
DEFAULT_ALLOWED_EXTRA_LABELS = {
    "region",
    "db_type",
    "queue_name",
    "cache_type",
    "environment",
    "instance_id",
    "scenario",
}
DEFAULT_BLOCKED_LABELS = {
    "correlation_id",
    "request_id",
    "event_id",
    "trace_id",
    "session_id",
    "user_id",
}


class ValidationError(Exception):
    pass


class RemoteWriteError(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def handler(event, context):
    records = event.get("Records", [])
    failures = []
    samples = []
    valid_message_ids = []

    for record in records:
        message_id = record.get("messageId")

        try:
            payload = parse_record_body(record)
            sample = normalize_telemetry_payload(payload)
            samples.append(sample)
            valid_message_ids.append(message_id)
        except ValidationError as error:
            failures.append({"itemIdentifier": message_id})
            log_event(
                "record_rejected",
                {
                    "message_id": message_id,
                    "reason": str(error),
                },
            )
        except Exception as error:
            failures.append({"itemIdentifier": message_id})
            log_event(
                "record_failed",
                {
                    "message_id": message_id,
                    "error_type": type(error).__name__,
                },
            )

    remote_write_status = "skipped_empty_batch"
    if samples:
        try:
            remote_write_samples(samples)
            remote_write_status = "success"
        except RemoteWriteError as error:
            remote_write_status = error.reason
            failures.extend({"itemIdentifier": message_id} for message_id in valid_message_ids)

    log_batch_processed(records, samples, failures, remote_write_status)

    return {"batchItemFailures": failures}


def parse_record_body(record):
    body = record.get("body")
    if not body:
        raise ValidationError("missing_sqs_body")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise ValidationError("invalid_json") from error

    if not isinstance(payload, dict):
        raise ValidationError("payload_must_be_object")

    return payload


def normalize_telemetry_payload(payload):
    validate_required_fields(payload)

    labels = payload.get("labels", {})
    if labels is None:
        labels = {}
    if not isinstance(labels, dict):
        raise ValidationError("labels_must_be_object")

    validate_label_keys(labels)

    value = parse_metric_value(payload["value"])
    timestamp_ms = parse_timestamp_ms(payload["ts"])

    metric_type = require_non_empty_string(payload, "metric_type")
    tenant_id = require_non_empty_string(payload, "tenant_id")
    service_id = require_non_empty_string(payload, "service_id")

    prometheus_labels = {
        "tenant_id": tenant_id,
        "service_id": service_id,
        "metric_type": metric_type,
    }
    prometheus_labels.update({key: str(value) for key, value in labels.items()})

    return {
        "metric_name": metric_type,
        "labels": prometheus_labels,
        "value": value,
        "timestamp_ms": timestamp_ms,
    }


def validate_required_fields(payload):
    missing_fields = [field for field in REQUIRED_FIELDS if field not in payload]
    if missing_fields:
        raise ValidationError(f"missing_required_fields:{','.join(missing_fields)}")

    require_non_empty_string(payload, "ts")
    require_non_empty_string(payload, "tenant_id")
    require_non_empty_string(payload, "service_id")
    require_non_empty_string(payload, "metric_type")


def require_non_empty_string(payload, field_name):
    value = payload.get(field_name)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"invalid_{field_name}")
    return value.strip()


def parse_metric_value(value):
    if isinstance(value, bool):
        raise ValidationError("invalid_value")

    try:
        metric_value = float(value)
    except (TypeError, ValueError) as error:
        raise ValidationError("invalid_value") from error

    return metric_value


def parse_timestamp_ms(timestamp):
    if not isinstance(timestamp, str) or not timestamp.strip():
        raise ValidationError("invalid_ts")

    normalized = timestamp.strip()
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"

    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValidationError("invalid_ts") from error

    if parsed.tzinfo is None:
        raise ValidationError("timestamp_must_include_timezone")

    return int(parsed.astimezone(timezone.utc).timestamp() * 1000)


def validate_label_keys(labels):
    allowed_labels = get_csv_env("ALLOWED_PROMETHEUS_LABELS", DEFAULT_ALLOWED_EXTRA_LABELS)
    blocked_labels = get_csv_env("BLOCKED_PROMETHEUS_LABELS", DEFAULT_BLOCKED_LABELS)

    for key in labels:
        if not isinstance(key, str) or not key:
            raise ValidationError("invalid_label_key")
        if key in blocked_labels:
            raise ValidationError(f"blocked_label:{key}")
        if key not in allowed_labels:
            raise ValidationError(f"unsupported_label:{key}")


def get_csv_env(name, default_values):
    raw_value = os.environ.get(name)
    if not raw_value:
        return set(default_values)

    return {item.strip() for item in raw_value.split(",") if item.strip()}


def remote_write_samples(samples):
    endpoint = os.environ.get("AMP_REMOTE_WRITE_ENDPOINT")
    if not endpoint:
        raise RemoteWriteError("missing_amp_remote_write_endpoint")

    write_request = encode_write_request(samples)
    compressed_payload = snappy_compress(write_request)
    headers = build_remote_write_headers(compressed_payload)
    signed_headers = sign_aws_request("POST", endpoint, compressed_payload, headers)

    request = urllib.request.Request(
        endpoint,
        data=compressed_payload,
        headers=signed_headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=get_http_timeout_seconds()) as response:
            status_code = response.getcode()
    except urllib.error.HTTPError as error:
        raise RemoteWriteError(f"remote_write_http_{error.code}") from error
    except urllib.error.URLError as error:
        raise RemoteWriteError("remote_write_url_error") from error
    except TimeoutError as error:
        raise RemoteWriteError("remote_write_timeout") from error

    if status_code < 200 or status_code >= 300:
        raise RemoteWriteError(f"remote_write_http_{status_code}")


def build_remote_write_headers(payload):
    return {
        "Content-Type": "application/x-protobuf",
        "Content-Encoding": "snappy",
        "X-Prometheus-Remote-Write-Version": PROMETHEUS_REMOTE_WRITE_VERSION,
        "X-Amz-Content-Sha256": hashlib.sha256(payload).hexdigest(),
    }


def get_http_timeout_seconds():
    raw_timeout = os.environ.get("REMOTE_WRITE_TIMEOUT_SECONDS", "10")
    try:
        return int(raw_timeout)
    except ValueError:
        return 10


def encode_write_request(samples):
    payload = bytearray()
    for sample in samples:
        payload.extend(encode_field_message(1, encode_time_series(sample)))
    return bytes(payload)


def encode_time_series(sample):
    payload = bytearray()
    labels = build_prometheus_labels(sample)
    for name, value in labels:
        payload.extend(encode_field_message(1, encode_label(name, value)))
    payload.extend(encode_field_message(2, encode_sample(sample["value"], sample["timestamp_ms"])))
    return bytes(payload)


def build_prometheus_labels(sample):
    labels = {"__name__": sample["metric_name"]}
    labels.update(sample["labels"])
    return sorted((str(name), str(value)) for name, value in labels.items())


def encode_label(name, value):
    payload = bytearray()
    payload.extend(encode_field_string(1, name))
    payload.extend(encode_field_string(2, value))
    return bytes(payload)


def encode_sample(value, timestamp_ms):
    payload = bytearray()
    payload.extend(encode_field_double(1, value))
    payload.extend(encode_field_varint(2, timestamp_ms))
    return bytes(payload)


def encode_field_message(field_number, value):
    return encode_field_bytes(field_number, value)


def encode_field_string(field_number, value):
    return encode_field_bytes(field_number, value.encode("utf-8"))


def encode_field_bytes(field_number, value):
    return encode_varint((field_number << 3) | 2) + encode_varint(len(value)) + value


def encode_field_double(field_number, value):
    import struct

    return encode_varint((field_number << 3) | 1) + struct.pack("<d", float(value))


def encode_field_varint(field_number, value):
    return encode_varint((field_number << 3) | 0) + encode_varint(int(value))


def encode_varint(value):
    output = bytearray()
    while value > 0x7F:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)
    return bytes(output)


def snappy_compress(data):
    if not data:
        return b"\x00"

    output = bytearray()
    output.extend(encode_varint(len(data)))
    output.extend(encode_snappy_literal(data))
    return bytes(output)


def encode_snappy_literal(data):
    length = len(data)
    length_minus_one = length - 1

    if length < 60:
        return bytes([(length_minus_one << 2)]) + data

    length_bytes = length_minus_one.to_bytes((length_minus_one.bit_length() + 7) // 8, "little")
    if len(length_bytes) > 4:
        raise RemoteWriteError("snappy_literal_too_large")

    tag = (59 + len(length_bytes)) << 2
    return bytes([tag]) + length_bytes + data


def sign_aws_request(method, endpoint, payload, headers):
    parsed_url = urlparse(endpoint)
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    session_token = os.environ.get("AWS_SESSION_TOKEN")

    if not region:
        raise RemoteWriteError("missing_aws_region")
    if not access_key or not secret_key:
        raise RemoteWriteError("missing_aws_credentials")

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
    canonical_request = "\n".join(
        [
            method,
            parsed_url.path or "/",
            parsed_url.query,
            canonical_headers,
            signed_header_names,
            hashlib.sha256(payload).hexdigest(),
        ]
    )

    credential_scope = f"{date_stamp}/{region}/aps/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    signing_key = get_signature_key(secret_key, date_stamp, region, "aps")
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


def log_event(event_name, details):
    print(
        json.dumps(
            {
                "component": "telemetry-writer",
                "event": event_name,
                **details,
            },
            sort_keys=True,
        )
    )


def log_batch_processed(records, samples, failures, remote_write_status):
    log_event(
        "batch_processed",
        {
            "batch_size": len(records),
            "valid_count": len(samples),
            "failure_count": len(failures),
            "amp_workspace_id": os.environ.get("AMP_WORKSPACE_ID"),
            "remote_write_status": remote_write_status,
        },
    )
