import json
import os
import uuid
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime, timedelta, timezone
import boto3
import botocore
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

lambda_client = boto3.client("lambda")
dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", 30))
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
    promql_query = f'{metric_type}{{tenant_id="{tenant_id}", service_id="{service_id}"}}'

    # Tạo query parameters cho AMP API
    query_params = urllib.parse.urlencode({
        "query": promql_query,
        "start": str(start_unix),
        "end": str(end_unix),
        "step": "60s"  # Lấy mẫu mỗi 60 giây
    })

    url = f"{AMP_QUERY_ENDPOINT.rstrip('/')}/api/v1/query_range?{query_params}"

    # Sign request với SigV4 dùng botocore
    headers = sign_request_with_botocore(
        method="GET",
        url=url,
        body=b"",
        region=os.environ.get("AWS_REGION", "us-east-1"),
        service="aps"
    )

    request = urllib.request.Request(url, headers=headers, method="GET")

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


# Hàm sign mới dùng botocore:
def sign_request_with_botocore(method, url, body, region, service):
    session = boto3.Session()
    credentials = session.get_credentials()
    creds = credentials.get_frozen_credentials()

    request = AWSRequest(method=method, url=url, data=body)
    SigV4Auth(creds, service, region).add_auth(request)

    return dict(request.headers)


def invoke_serving_adapter(payload):
    response = lambda_client.invoke(
        FunctionName=SERVING_ADAPTER_LAMBDA_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload)
    )
    return json.loads(response["Payload"].read())


def write_audit(correlation_id, service_id, tenant_id, result, scheduled_at, is_fallback):
    prediction_id = correlation_id  # Dùng correlation_id làm prediction_id
    tenant_service = f"{tenant_id}#{service_id}"
    now = datetime.now(timezone.utc)
    expires_at = int((now + timedelta(days=AUDIT_RETENTION_DAYS)).timestamp())

    audit_table.put_item(Item={
        "tenant_service": tenant_service,       # Partition key (BẮT BUỘC)
        "prediction_id": prediction_id,         # Sort key (BẮT BUỘC)
        "correlation_id": correlation_id,       # Dùng cho GSI
        "service_id": service_id,
        "tenant_id": tenant_id,
        "result": result,
        "is_fallback": is_fallback,
        "scheduled_at": scheduled_at,
        "timestamp": now.isoformat(),
        "expires_at": expires_at                # TTL attribute
    })


def log_event(event_name, details):
    print(json.dumps({
        "component": "prediction-lambda",
        "event": event_name,
        **details
    }))
