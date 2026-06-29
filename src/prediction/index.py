import json
import os
import uuid
import hashlib
import hmac
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse
import boto3

lambda_client = boto3.client("lambda")
dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])

SERVING_ADAPTER_LAMBDA_NAME = os.environ["SERVING_ADAPTER_LAMBDA_NAME"]
AMP_QUERY_ENDPOINT = os.environ["AMP_QUERY_ENDPOINT"]
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", 120))
# Danh sách các metric types cần query (theo telemetry contract)
METRIC_TYPES = [
    "cpu_usage_percent",
    "memory_usage_percent",
    "active_connections",
    "db_connection_pool_pct",
    "queue_depth",
    "cache_hit_rate_pct",
    "api_latency_ms"
]


def handler(event, context):
    correlation_id = str(uuid.uuid4())
    service_id = event.get("service_id")
    tenant_id = event.get("tenant_id")
    scheduled_at = event.get("scheduled_at")

    log_event("prediction_started", {
        "correlation_id": correlation_id,
        "service_id": service_id,
        "tenant_id": tenant_id
    })

    try:
        # Bước 1: Query AMP lấy dữ liệu 120 phút
        signal_window = query_amp(tenant_id, service_id)

        # Tính toán time range
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(minutes=LOOKBACK_MINUTES)

        # Bước 2: Gọi Serving Adapter
        response = invoke_serving_adapter({
            "signal_window": signal_window,
            "service_id": service_id,
            "tenant_id": tenant_id,
            "correlation_id": correlation_id,
            "context": {
                "deployment_version": "v1.0",
                "time_range": {
                    "start_ts": start_time.isoformat().replace("+00:00", "Z"),
                    "end_ts": end_time.isoformat().replace("+00:00", "Z")
                }
            }
        })

        # Bước 3: Ghi audit
        write_audit(correlation_id, service_id, tenant_id, response, scheduled_at, False)

        log_event("prediction_completed", {
            "correlation_id": correlation_id
        })

        return response

    except Exception as e:
        log_event("prediction_failed", {
            "correlation_id": correlation_id,
            "error": str(e)
        })
        write_audit(correlation_id, service_id, tenant_id, {"error": str(e)}, scheduled_at, True)
        raise


def query_amp(tenant_id, service_id):
    """Query AMP lấy dữ liệu cho tất cả các metric types trong 120 phút"""
    signal_window = []
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=LOOKBACK_MINUTES)

    for metric_type in METRIC_TYPES:
        try:
            data_points = query_metric_from_amp(
                metric_type=metric_type,
                tenant_id=tenant_id,
                service_id=service_id,
                start_time=start_time,
                end_time=end_time
            )
            signal_window.extend(data_points)
        except Exception as e:
            log_event("amp_query_error", {
                "metric_type": metric_type,
                "error": str(e)
            })
            continue

    return signal_window


def query_metric_from_amp(metric_type, tenant_id, service_id, start_time, end_time):
    """Query một metric cụ thể từ AMP bằng PromQL"""
    # Chuyển thời gian về Unix timestamp (giây)
    start_unix = int(start_time.timestamp())
    end_unix = int(end_time.timestamp())

    # PromQL query: lấy tất cả giá trị của metric với tenant_id và service_id tương ứng
    # Lưu ý: Tên metric trong AMP chính là giá trị của trường `metric_type`
    promql_query = f'{metric_type}{{tenant_id="{tenant_id}", service_id="{service_id}"}}'

    # Tạo query parameters cho AMP API
    query_params = urllib.parse.urlencode({
        "query": promql_query,
        "start": str(start_unix),
        "end": str(end_unix),
        "step": "60s"  # Lấy mẫu mỗi 60 giây
    })

    url = f"{AMP_QUERY_ENDPOINT.rstrip('/')}/api/v1/query_range?{query_params}"
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-Amz-Content-Sha256": hashlib.sha256(b"").hexdigest()  # Payload trống cho GET request
    }

    # Sign request với SigV4 (tương tự như writer lambda)
    signed_headers = sign_aws_request("GET", url, b"", headers)

    request = urllib.request.Request(url, headers=signed_headers, method="GET")

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read())

            if result.get("status") != "success":
                log_event("amp_query_failed", {
                    "metric_type": metric_type,
                    "result": result
                })
                return []

            # Parse kết quả về định dạng signal_window theo AI API contract
            data_points = []
            for series in result.get("data", {}).get("result", []):
                labels = series.get("metric", {})
                values = series.get("values", [])

                for ts_unix, value_str in values:
                    # Chuyển timestamp về RFC3339
                    ts_dt = datetime.fromtimestamp(float(ts_unix), tz=timezone.utc)
                    ts_rfc3339 = ts_dt.isoformat().replace("+00:00", "Z")

                    data_points.append({
                        "ts": ts_rfc3339,
                        "tenant_id": tenant_id,
                        "service_id": service_id,
                        "metric_type": metric_type,
                        "value": float(value_str),
                        "labels": {k: v for k, v in labels.items() if k not in ["tenant_id", "service_id", "metric_type"]}
                    })

            return data_points

    except urllib.error.HTTPError as e:
        log_event("amp_http_error", {
            "metric_type": metric_type,
            "code": e.code,
            "body": e.read().decode()
        })
        return []
    except Exception as e:
        log_event("amp_error", {
            "metric_type": metric_type,
            "error": str(e)
        })
        return []


def sign_aws_request(method, endpoint, payload, headers):
    """Sign AWS request with SigV4 (tham khảo từ writer/handler.py)"""
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

    credential_scope = f"{date_stamp}/{region}/aps/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])

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


def invoke_serving_adapter(payload):
    response = lambda_client.invoke(
        FunctionName=SERVING_ADAPTER_LAMBDA_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload)
    )
    return json.loads(response["Payload"].read())


def write_audit(correlation_id, service_id, tenant_id, result, scheduled_at, is_fallback):
    audit_table.put_item(Item={
        "correlation_id": correlation_id,
        "service_id": service_id,
        "tenant_id": tenant_id,
        "result": result,
        "is_fallback": is_fallback,
        "scheduled_at": scheduled_at,
        "timestamp": datetime.now(timezone.utc).isoformat()
    })


def log_event(event_name, details):
    print(json.dumps({
        "component": "prediction-lambda",
        "event": event_name,
        **details
    }))