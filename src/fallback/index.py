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

dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])
secretsmanager = boto3.client("secretsmanager")
grafana_secret_arn = os.environ.get("GRAFANA_SECRET_ARN")
grafana_workspace_endpoint = os.environ.get("GRAFANA_WORKSPACE_ENDPOINT")
AMP_QUERY_ENDPOINT = os.environ["AMP_QUERY_ENDPOINT"]
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", 30))

# Threshold tĩnh cho từng metric type (bạn có thể điều chỉnh)
STATIC_THRESHOLDS = {
    "cpu_usage_percent": {"warning": 70.0, "critical": 90.0},
    "memory_usage_percent": {"warning": 80.0, "critical": 95.0},
    "active_connections": {"warning": 100, "critical": 500},
    "db_connection_pool_pct": {"warning": 80.0, "critical": 95.0},
    "queue_depth": {"warning": 100, "critical": 1000},
    "cache_hit_rate_pct": {"warning": 80.0, "critical": 50.0, "is_lower_better": True},
    "api_latency_ms": {"warning": 500, "critical": 2000}
}


def handler(event, context):
    correlation_id = event.get("correlation_id", str(uuid.uuid4()))
    service_id = event.get("service_id")
    tenant_id = event.get("tenant_id")
    scheduled_at = event.get("scheduled_at")

    log_event("fallback_started", {
        "correlation_id": correlation_id,
        "service_id": service_id,
        "tenant_id": tenant_id
    })

    try:
        # Bước 1: Query AMP lấy dữ liệu gần nhất (5 phút)
        latest_metrics = get_latest_metrics(tenant_id, service_id)

        # Bước 2: Áp dụng static threshold
        anomaly, severity, reasoning = evaluate_static_thresholds(latest_metrics)

        # Bước 3: Xác định action verb dựa trên severity
        action_verb = "INVESTIGATE"
        if severity >= 0.8:
            action_verb = "SCALE_UP"
        elif severity >= 0.5:
            action_verb = "INVESTIGATE"
        else:
            action_verb = "INVESTIGATE"

        result = {
            "anomaly": anomaly,
            "severity": severity,
            "recommendation": {
                "action_verb": action_verb,
                "target": service_id,
                "from_to": None,
                "confidence": 0.5,
                "evidence_link": None
            },
            "reasoning": reasoning,
            "audit_id": correlation_id
        }

        # Bước 4: Ghi audit
        write_audit(correlation_id, service_id, tenant_id, result, scheduled_at, True)

        # Bước 5: Tạo Grafana annotation (nếu có secret)
        if grafana_secret_arn:
            try:
                create_grafana_annotation(result, service_id, tenant_id, latest_metrics)
            except Exception as e:
                log_event("grafana_annotation_error", {"error": str(e)})

        log_event("fallback_completed", {
            "correlation_id": correlation_id,
            "anomaly": anomaly
        })

        return result

    except Exception as e:
        log_event("fallback_failed", {
            "correlation_id": correlation_id,
            "error": str(e)
        })
        raise


def get_latest_metrics(tenant_id, service_id):
    """Lấy giá trị metric mới nhất từ AMP (5 phút gần nhất)"""
    end_time = datetime.now(timezone.utc)
    metrics = {}

    for metric_type in STATIC_THRESHOLDS.keys():
        try:
            # Query instant value (giá trị hiện tại)
            value = query_instant_metric(metric_type, tenant_id, service_id, end_time)
            if value is not None:
                metrics[metric_type] = value
        except Exception as e:
            log_event("fallback_amp_query_error", {
                "metric_type": metric_type,
                "error": str(e)
            })
            continue

    return metrics


def query_instant_metric(metric_type, tenant_id, service_id, at_time):
    """Query giá trị metric tại một thời điểm cụ thể từ AMP"""
    at_unix = int(at_time.timestamp())
    promql_query = f'{metric_type}{{tenant_id="{tenant_id}", service_id="{service_id}"}}'
    query_params = urllib.parse.urlencode({
        "query": promql_query,
        "time": str(at_unix)
    })

    url = f"{amp_api_base_url()}/api/v1/query?{query_params}"

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
                return None

            data = result.get("data", {}).get("result", [])
            if not data:
                return None

            # Lấy giá trị cuối cùng
            value_str = data[0].get("value", [None, None])[1]
            if value_str is None:
                return None

            return float(value_str)
    except Exception:
        return None


# Hàm sign mới dùng botocore:
def sign_request_with_botocore(method, url, body, region, service):
    session = boto3.Session()
    credentials = session.get_credentials()
    creds = credentials.get_frozen_credentials()

    request = AWSRequest(method=method, url=url, data=body)
    SigV4Auth(creds, service, region).add_auth(request)

    return dict(request.headers)


def evaluate_static_thresholds(metrics):
    """Đánh giá các metrics dựa trên static threshold"""
    max_severity = 0.0
    reasons = []

    for metric_type, value in metrics.items():
        thresholds = STATIC_THRESHOLDS.get(metric_type)
        if not thresholds:
            continue

        is_lower_better = thresholds.get("is_lower_better", False)
        warning = thresholds["warning"]
        critical = thresholds["critical"]

        # Kiểm tra xem giá trị có vượt threshold không
        is_warning = False
        is_critical = False

        if is_lower_better:
            is_warning = value < warning
            is_critical = value < critical
        else:
            is_warning = value > warning
            is_critical = value > critical

        if is_critical:
            severity = 0.9
            reasons.append(f"{metric_type} is critical (value={value})")
        elif is_warning:
            severity = 0.6
            reasons.append(f"{metric_type} is warning (value={value})")
        else:
            severity = 0.0

        if severity > max_severity:
            max_severity = severity

    is_anomaly = max_severity > 0
    reasoning = " | ".join(reasons) if reasons else "No thresholds exceeded"

    return is_anomaly, max_severity, reasoning


def create_grafana_annotation(result, service_id, tenant_id, metrics):
    """Tạo annotation trên Grafana"""
    try:
        # Lấy Grafana API token từ Secrets Manager
        secret_response = secretsmanager.get_secret_value(SecretId=grafana_secret_arn)
        secret_string = secret_response["SecretString"]
        grafana_url, grafana_token = parse_grafana_secret(secret_string)

        if not grafana_url or not grafana_token:
            log_event("grafana_config_missing", {})
            return

        # Tạo annotation payload
        now = datetime.now(timezone.utc)
        annotation_payload = {
            "dashboardUID": None,  # Thay thế bằng UID của dashboard nếu có
            "panelId": None,      # Thay thế bằng panel ID nếu có
            "time": int(now.timestamp() * 1000),
            "timeEnd": int((now + timedelta(minutes=5)).timestamp() * 1000),
            "tags": [
                "fallback",
                f"tenant:{tenant_id}",
                f"service:{service_id}",
                f"anomaly:{result['anomaly']}"
            ],
            "text": f"**Fallback Alert**\n"
                    f"Service: {service_id}\n"
                    f"Tenant: {tenant_id}\n"
                    f"Anomaly: {result['anomaly']}\n"
                    f"Severity: {result['severity']:.2f}\n"
                    f"Reasoning: {result['reasoning']}\n"
                    f"Metrics: {json.dumps(metrics)}"
        }

        # Gọi Grafana API
        headers = {
            "Authorization": f"Bearer {grafana_token}",
            "Content-Type": "application/json"
        }
        request = urllib.request.Request(
            url=f"{grafana_url.rstrip('/')}/api/annotations",
            data=json.dumps(annotation_payload).encode("utf-8"),
            headers=headers,
            method="POST"
        )

        with urllib.request.urlopen(request, timeout=10) as response:
            log_event("grafana_annotation_created", {"status": response.status})

    except Exception as e:
        log_event("grafana_annotation_failed", {"error": str(e)})
        raise


def parse_grafana_secret(secret_string):
    grafana_url = grafana_workspace_endpoint or os.environ.get("GRAFANA_URL")
    grafana_token = secret_string

    try:
        grafana_config = json.loads(secret_string)
        grafana_url = grafana_config.get("url") or grafana_url
        grafana_token = grafana_config.get("token") or grafana_config.get("api_token") or grafana_token
    except json.JSONDecodeError:
        pass

    return normalize_grafana_url(grafana_url), grafana_token


def normalize_grafana_url(grafana_url):
    if not grafana_url:
        return None

    if grafana_url.startswith("http://") or grafana_url.startswith("https://"):
        return grafana_url

    return f"https://{grafana_url}"


def amp_api_base_url():
    endpoint = AMP_QUERY_ENDPOINT.rstrip("/")
    for suffix in ("/api/v1/query_range", "/api/v1/query"):
        if endpoint.endswith(suffix):
            return endpoint[: -len(suffix)]
    return endpoint


def write_audit(correlation_id, service_id, tenant_id, result, scheduled_at, is_fallback):
    prediction_id = correlation_id  # Dùng correlation_id làm prediction_id
    tenant_service = f"{tenant_id}#{service_id}"
    now = datetime.now(timezone.utc)
    expires_at = int((now + timedelta(days=AUDIT_RETENTION_DAYS)).timestamp())

    audit_table.put_item(Item=to_dynamodb_safe({
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
    }))


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
        "component": "fallback-lambda",
        "event": event_name,
        **details
    }))
