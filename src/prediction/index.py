import json
import os
import uuid
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import boto3
import botocore
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

lambda_client = boto3.client("lambda")
dynamodb = boto3.resource("dynamodb")
secretsmanager = boto3.client("secretsmanager")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", 30))
SERVING_ADAPTER_LAMBDA_NAME = os.environ["SERVING_ADAPTER_LAMBDA_NAME"]
AMP_QUERY_ENDPOINT = os.environ["AMP_QUERY_ENDPOINT"]
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", 120))
GRAFANA_SECRET_ARN = os.environ.get("GRAFANA_SECRET_ARN")
GRAFANA_WORKSPACE_ENDPOINT = os.environ.get("GRAFANA_WORKSPACE_ENDPOINT")
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

        annotation_id = None
        if response.get("anomaly") is True:
            annotation_id = publish_prediction_annotation(
                result=response,
                service_id=service_id,
                tenant_id=tenant_id,
                correlation_id=correlation_id,
                start_time=start_time,
                end_time=end_time
            )

        # Bước 3: Ghi audit
        write_audit(correlation_id, service_id, tenant_id, response, scheduled_at, False, annotation_id)

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

    # AMP query endpoints are sensitive to SigV4 canonical query encoding.
    # Use POST form body, matching the successful awscurl path.
    form_body = urllib.parse.urlencode({
        "query": promql_query,
        "start": str(start_unix),
        "end": str(end_unix),
        "step": "60s"  # Lấy mẫu mỗi 60 giây
    }).encode("utf-8")

    url = f"{amp_api_base_url()}/api/v1/query_range"
    request_headers = {
        "Content-Type": "application/x-www-form-urlencoded"
    }

    # Sign request với SigV4 dùng botocore
    headers = sign_request_with_botocore(
        method="POST",
        url=url,
        body=form_body,
        headers=request_headers,
        region=os.environ.get("AWS_REGION", "us-east-1"),
        service="aps"
    )

    request = urllib.request.Request(url, data=form_body, headers=headers, method="POST")

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


def sign_request_with_botocore(method, url, body, region, service, headers=None):
    session = boto3.Session()
    credentials = session.get_credentials()
    creds = credentials.get_frozen_credentials()

    request = AWSRequest(method=method, url=url, data=body, headers=headers or {})
    SigV4Auth(creds, service, region).add_auth(request)

    return dict(request.headers)


def invoke_serving_adapter(payload):
    response = lambda_client.invoke(
        FunctionName=SERVING_ADAPTER_LAMBDA_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload)
    )
    return json.loads(response["Payload"].read())


def publish_prediction_annotation(result, service_id, tenant_id, correlation_id, start_time, end_time):
    if not GRAFANA_SECRET_ARN or not GRAFANA_WORKSPACE_ENDPOINT:
        log_event("grafana_annotation_skipped", {
            "correlation_id": correlation_id,
            "reason": "grafana_not_configured"
        })
        return None

    try:
        grafana_token = get_grafana_token()
        recommendation = result.get("recommendation") or {}
        severity = result.get("severity")
        annotation_payload = {
            "time": int(start_time.timestamp() * 1000),
            "timeEnd": int(end_time.timestamp() * 1000),
            "tags": [
                "prediction",
                f"tenant:{tenant_id}",
                f"service:{service_id}",
                f"anomaly:{result.get('anomaly')}",
                f"action:{recommendation.get('action_verb', 'none')}",
            ],
            "text": "\n".join([
                "Prediction anomaly",
                f"Service: {service_id}",
                f"Tenant: {tenant_id}",
                f"Severity: {severity}",
                f"Action: {recommendation.get('action_verb')}",
                f"Target: {recommendation.get('target')}",
                f"Confidence: {recommendation.get('confidence')}",
                f"Reasoning: {result.get('reasoning')}",
                f"Audit ID: {result.get('audit_id')}",
                f"Correlation ID: {correlation_id}",
            ]),
        }

        request = urllib.request.Request(
            url=f"{normalize_grafana_url(GRAFANA_WORKSPACE_ENDPOINT).rstrip('/')}/api/annotations",
            data=json.dumps(annotation_payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {grafana_token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )

        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.loads(response.read() or "{}")
            annotation_id = body.get("id")
            log_event("grafana_annotation_created", {
                "correlation_id": correlation_id,
                "annotation_id": annotation_id
            })
            return annotation_id
    except Exception as error:
        log_event("grafana_annotation_failed", {
            "correlation_id": correlation_id,
            "error_type": type(error).__name__,
            "error": str(error)
        })
        return None


def get_grafana_token():
    secret = secretsmanager.get_secret_value(SecretId=GRAFANA_SECRET_ARN)["SecretString"]
    try:
        parsed = json.loads(secret)
        return parsed.get("token") or parsed.get("api_token") or secret
    except json.JSONDecodeError:
        return secret


def normalize_grafana_url(value):
    if value.startswith("http://") or value.startswith("https://"):
        return value
    return f"https://{value}"


def amp_api_base_url():
    endpoint = AMP_QUERY_ENDPOINT.rstrip("/")
    for suffix in ("/api/v1/query_range", "/api/v1/query"):
        if endpoint.endswith(suffix):
            return endpoint[: -len(suffix)]
    return endpoint


def write_audit(correlation_id, service_id, tenant_id, result, scheduled_at, is_fallback, grafana_annotation_id=None):
    prediction_id = correlation_id  # Dùng correlation_id làm prediction_id
    tenant_service = f"{tenant_id}#{service_id}"
    now = datetime.now(timezone.utc)
    expires_at = int((now + timedelta(days=AUDIT_RETENTION_DAYS)).timestamp())

    item = {
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
    }
    if grafana_annotation_id is not None:
        item["grafana_annotation_id"] = str(grafana_annotation_id)

    audit_table.put_item(Item=to_dynamodb_safe(item))


def to_dynamodb_safe(value):
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {key: to_dynamodb_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [to_dynamodb_safe(item) for item in value]
    return value


def log_event(event_name, details):
    print(json.dumps({
        "component": "prediction-lambda",
        "event": event_name,
        **details
    }))
