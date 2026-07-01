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
from boto3.dynamodb.conditions import Key

lambda_client = boto3.client("lambda")
sns_client = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")
secretsmanager = boto3.client("secretsmanager")
audit_table = dynamodb.Table(os.environ["AUDIT_TABLE_NAME"])
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", 30))
SERVING_ADAPTER_LAMBDA_NAME = os.environ["SERVING_ADAPTER_LAMBDA_NAME"]
AMP_QUERY_ENDPOINT = os.environ["AMP_QUERY_ENDPOINT"]
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", 120))
FRESHNESS_THRESHOLD_SECONDS = int(os.environ.get("FRESHNESS_THRESHOLD_SECONDS", 180))
ANNOTATION_COOLDOWN_MINUTES = int(os.environ.get("ANNOTATION_COOLDOWN_MINUTES", 30))
GRAFANA_SECRET_ARN = os.environ.get("GRAFANA_SECRET_ARN")
GRAFANA_WORKSPACE_ENDPOINT = os.environ.get("GRAFANA_WORKSPACE_ENDPOINT")
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")
ENABLE_EMAIL_ALERTS = os.environ.get("ENABLE_EMAIL_ALERTS", "true").lower() == "true"
EMAIL_ALERT_MIN_SEVERITY = float(os.environ.get("EMAIL_ALERT_MIN_SEVERITY", "0.5"))
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
        latest_signal_time = latest_signal_timestamp(signal_window)

        if latest_signal_time is None:
            response = {
                "anomaly": False,
                "severity": 0.0,
                "recommendation": None,
                "reasoning": "Prediction skipped because no telemetry datapoints were found in the lookback window.",
                "skipped": True,
                "skip_reason": "no_recent_telemetry",
            }
            write_audit(correlation_id, service_id, tenant_id, response, scheduled_at, False)
            log_event("prediction_skipped", {
                "correlation_id": correlation_id,
                "service_id": service_id,
                "tenant_id": tenant_id,
                "reason": "no_recent_telemetry"
            })
            return response

        signal_age_seconds = (end_time - latest_signal_time).total_seconds()
        if signal_age_seconds > FRESHNESS_THRESHOLD_SECONDS:
            response = {
                "anomaly": False,
                "severity": 0.0,
                "recommendation": None,
                "reasoning": (
                    "Prediction skipped because the latest telemetry datapoint is stale. "
                    f"latest_ts={latest_signal_time.isoformat().replace('+00:00', 'Z')}, "
                    f"age_seconds={int(signal_age_seconds)}"
                ),
                "skipped": True,
                "skip_reason": "stale_telemetry",
            }
            write_audit(correlation_id, service_id, tenant_id, response, scheduled_at, False)
            log_event("prediction_skipped", {
                "correlation_id": correlation_id,
                "service_id": service_id,
                "tenant_id": tenant_id,
                "reason": "stale_telemetry",
                "latest_ts": latest_signal_time.isoformat().replace("+00:00", "Z"),
                "age_seconds": int(signal_age_seconds)
            })
            return response

        # Bước 2: Gọi Serving Adapter
        response = invoke_serving_adapter({
            "signal_window": signal_window,
            "service_id": service_id,
            "tenant_id": tenant_id,
            "correlation_id": correlation_id,
            "context": {
                "tenant_id": tenant_id,
                "service_id": service_id,
                "source": "cdo08-prediction-scheduler",
                "deployment_version": "v1.0",
                "time_range": {
                    "start_ts": start_time.isoformat().replace("+00:00", "Z"),
                    "end_ts": end_time.isoformat().replace("+00:00", "Z")
                }
            }
        })

        annotation_id = None
        if response.get("anomaly") is True:
            recommendation = response.get("recommendation") or {}
            action = recommendation.get("action_verb", "none")
            should_notify = should_publish_annotation(tenant_id, service_id, action, end_time)
            if should_notify:
                annotation_id = publish_prediction_annotation(
                    result=response,
                    service_id=service_id,
                    tenant_id=tenant_id,
                    correlation_id=correlation_id,
                    start_time=start_time,
                    end_time=end_time
                )
                publish_email_alert(
                    result=response,
                    service_id=service_id,
                    tenant_id=tenant_id,
                    correlation_id=correlation_id,
                    alert_type="prediction",
                    start_time=start_time,
                    end_time=end_time,
                )
            else:
                log_event("grafana_annotation_suppressed", {
                    "correlation_id": correlation_id,
                    "service_id": service_id,
                    "tenant_id": tenant_id,
                    "action": action,
                    "cooldown_minutes": ANNOTATION_COOLDOWN_MINUTES
                })

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


def latest_signal_timestamp(signal_window):
    latest = None
    for point in signal_window:
        ts_value = point.get("ts")
        if not ts_value:
            continue
        try:
            ts = parse_rfc3339_utc(ts_value)
        except ValueError:
            continue
        if latest is None or ts > latest:
            latest = ts
    return latest


def parse_rfc3339_utc(value):
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


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


def should_publish_annotation(tenant_id, service_id, action, now):
    """Suppress duplicate Grafana annotations for the same service/action cooldown window."""
    cooldown_start = now - timedelta(minutes=ANNOTATION_COOLDOWN_MINUTES)
    tenant_service = f"{tenant_id}#{service_id}"

    try:
        query_kwargs = {
            "KeyConditionExpression": Key("tenant_service").eq(tenant_service),
            "ProjectionExpression": "#ts, #result, grafana_annotation_id",
            "ExpressionAttributeNames": {
                "#ts": "timestamp",
                "#result": "result",
            },
        }

        while True:
            response = audit_table.query(**query_kwargs)
            for item in response.get("Items", []):
                if not item.get("grafana_annotation_id"):
                    continue

                item_timestamp = item.get("timestamp")
                if not item_timestamp:
                    continue

                try:
                    created_at = parse_rfc3339_utc(item_timestamp)
                except ValueError:
                    continue

                if created_at < cooldown_start:
                    continue

                result = item.get("result") or {}
                recommendation = result.get("recommendation") or {}
                if result.get("anomaly") is True and recommendation.get("action_verb", "none") == action:
                    return False

            if "LastEvaluatedKey" not in response:
                break
            query_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    except Exception as error:
        log_event("annotation_cooldown_check_failed", {
            "service_id": service_id,
            "tenant_id": tenant_id,
            "action": action,
            "error_type": type(error).__name__,
            "error": str(error),
            "decision": "suppress_annotation"
        })
        return False

    return True


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
            "time": int(end_time.timestamp() * 1000),
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
                f"Window Start: {start_time.isoformat().replace('+00:00', 'Z')}",
                f"Window End: {end_time.isoformat().replace('+00:00', 'Z')}",
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


def publish_email_alert(result, service_id, tenant_id, correlation_id, alert_type, start_time=None, end_time=None):
    if not ENABLE_EMAIL_ALERTS or not ALERT_TOPIC_ARN:
        log_event("email_alert_skipped", {
            "correlation_id": correlation_id,
            "reason": "email_alerts_disabled_or_topic_missing"
        })
        return None

    severity = float(result.get("severity") or 0)
    if severity < EMAIL_ALERT_MIN_SEVERITY:
        log_event("email_alert_skipped", {
            "correlation_id": correlation_id,
            "reason": "severity_below_threshold",
            "severity": severity,
            "threshold": EMAIL_ALERT_MIN_SEVERITY
        })
        return None

    recommendation = result.get("recommendation") or {}
    grafana_url = normalize_grafana_url(GRAFANA_WORKSPACE_ENDPOINT) if GRAFANA_WORKSPACE_ENDPOINT else "not-configured"
    window_lines = []
    if start_time and end_time:
        window_lines = [
            f"Window start: {start_time.isoformat().replace('+00:00', 'Z')}",
            f"Window end: {end_time.isoformat().replace('+00:00', 'Z')}",
        ]

    subject = f"[CDO08][sandbox] {alert_type.upper()} {service_id} {recommendation.get('action_verb', 'INVESTIGATE')}"
    message = "\n".join([
        "CDO08 Foresight Lens alert",
        "",
        f"Alert type: {alert_type}",
        f"Tenant: {tenant_id}",
        f"Service: {service_id}",
        f"Anomaly: {result.get('anomaly')}",
        f"Severity: {severity}",
        f"Action: {recommendation.get('action_verb')}",
        f"Target: {recommendation.get('target')}",
        f"Confidence: {recommendation.get('confidence')}",
        f"Reasoning: {result.get('reasoning')}",
        f"Audit ID: {result.get('audit_id')}",
        f"Correlation ID: {correlation_id}",
        *window_lines,
        f"Grafana: {grafana_url}",
    ])

    try:
        response = sns_client.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject=subject[:100],
            Message=message,
        )
        message_id = response.get("MessageId")
        log_event("email_alert_published", {
            "correlation_id": correlation_id,
            "message_id": message_id,
            "service_id": service_id,
            "tenant_id": tenant_id,
            "alert_type": alert_type,
        })
        return message_id
    except Exception as error:
        log_event("email_alert_failed", {
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
