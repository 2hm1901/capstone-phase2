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

dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])
secretsmanager = boto3.client("secretsmanager")
grafana_secret_arn = os.environ.get("GRAFANA_SECRET_ARN")
AMP_QUERY_ENDPOINT = os.environ["AMP_QUERY_ENDPOINT"]

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
        write_audit(correlation_id, service_id, tenant_id, result, True)

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

    url = f"{AMP_QUERY_ENDPOINT.rstrip('/')}/api/v1/query?{query_params}"
    headers = {
        "X-Amz-Content-Sha256": hashlib.sha256(b"").hexdigest()
    }
    signed_headers = sign_aws_request("GET", url, b"", headers)

    request = urllib.request.Request(url, headers=signed_headers, method="GET")

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


def sign_aws_request(method, endpoint, payload, headers):
    """Sign AWS request with SigV4 (copy từ prediction lambda)"""
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
        grafana_config = json.loads(secret_string)
        grafana_url = grafana_config.get("url", os.environ.get("GRAFANA_URL"))
        grafana_token = grafana_config.get("token")

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


def write_audit(correlation_id, service_id, tenant_id, result, is_fallback):
    audit_table.put_item(Item={
        "correlation_id": correlation_id,
        "service_id": service_id,
        "tenant_id": tenant_id,
        "result": result,
        "is_fallback": is_fallback,
        "timestamp": datetime.now(timezone.utc).isoformat()
    })


def log_event(event_name, details):
    print(json.dumps({
        "component": "fallback-lambda",
        "event": event_name,
        **details
    }))