"""
Mock prediction/fallback annotation + audit evidence script (W12).

Usage (Mac/Linux):
    export GRAFANA_TOKEN_SECRET_ID=arn:aws:secretsmanager:us-east-1:894597652722:secret:cdo08-sandbox-grafana-token-XXXX
    export GRAFANA_WORKSPACE_ENDPOINT=https://g-XXXX.grafana-workspace.us-east-1.amazonaws.com
    python scripts/mock_annotation_audit.py --service payment-gw --metric cpu_usage_percent --outcome prediction --fallback false

Windows (PowerShell): use $env:GRAFANA_TOKEN_SECRET_ID = "..." instead of export.

This script does NOT require the AI Engine. It writes a DynamoDB audit item
and publishes a Grafana annotation using the standardized payload contract
(docs/assets/grafana_audit_payload_contract.md), so the evidence path can be
demonstrated end-to-end while AI integration is still deferred.

No secret is hard-coded. The Grafana token is fetched from Secrets Manager
at runtime via the AWS SDK and is never printed or logged.
"""

import argparse
import json
import os
import time
import uuid

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
AUDIT_TABLE = os.environ.get("AUDIT_TABLE", "cdo08-sandbox-audit")
AUDIT_TABLE_ARN = os.environ.get(
    "AUDIT_TABLE_ARN",
    "arn:aws:dynamodb:us-east-1:894597652722:table/cdo08-sandbox-audit",
)
LOG_GROUP = os.environ.get("ANNOTATION_LOG_GROUP", "cdo08-sandbox/annotation-audit")
GRAFANA_TOKEN_SECRET_ID = os.environ.get("GRAFANA_TOKEN_SECRET_ID")
GRAFANA_WORKSPACE_ENDPOINT = os.environ.get("GRAFANA_WORKSPACE_ENDPOINT")
TENANT_ID = os.environ.get("TENANT_ID", "tenant-cdo08-demo")
RETENTION_DAYS = 90


def put_audit_item(dynamodb, args, correlation_id, prediction_id, grafana_annotation_id=None, ai_audit_id=None):
    now = int(time.time())
    expires_at = now + RETENTION_DAYS * 86400
    tenant_service = f"{TENANT_ID}#{args.service}"
    item = {
        "tenant_service": {"S": tenant_service},
        "prediction_id": {"S": prediction_id},
        "correlation_id": {"S": correlation_id},
        "tenant_id": {"S": TENANT_ID},
        "service_id": {"S": args.service},
        "metric_type": {"S": args.metric},
        "outcome": {"S": args.outcome},
        "fallback": {"BOOL": args.fallback},
        "confidence": {"N": str(args.confidence)},
        "recommendation_ref": {"S": args.recommendation},
        "expires_at": {"N": str(expires_at)},
        "created_at": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))},
    }
    if grafana_annotation_id is not None:
        item["grafana_annotation_id"] = {"S": str(grafana_annotation_id)}
    if ai_audit_id is not None:
        item["ai_audit_id"] = {"S": ai_audit_id}
    dynamodb.put_item(TableName=AUDIT_TABLE, Item=item)
    print(f"[audit] PutItem OK table={AUDIT_TABLE} pk={tenant_service} sk={prediction_id}")
    return item


def put_audit_log(logs, args, correlation_id, prediction_id, status="ok"):
    event = {
        "event": "fallback_annotation" if args.fallback else "prediction_annotation",
        "tenant_id": TENANT_ID,
        "service_id": args.service,
        "metric_type": args.metric,
        "prediction_id": prediction_id,
        "correlation_id": correlation_id,
        "fallback": args.fallback,
        "status": status,
    }
    stream_name = f"mock-{prediction_id}"
    try:
        logs.create_log_stream(logGroupName=LOG_GROUP, logStreamName=stream_name)
    except logs.exceptions.ResourceAlreadyExistsException:
        pass
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ResourceAlreadyExistsException":
            raise
    logs.put_log_events(
        logGroupName=LOG_GROUP,
        logStreamName=stream_name,
        logEvents=[{"timestamp": int(time.time() * 1000), "message": json.dumps(event)}],
    )
    print(f"[log] PutLogEvents OK group={LOG_GROUP} stream={stream_name} event={event['event']}")


def get_grafana_token(secretsmanager):
    if not GRAFANA_TOKEN_SECRET_ID:
        raise SystemExit(
            "GRAFANA_TOKEN_SECRET_ID env var is required (Secrets Manager ARN). "
            "No token is hard-coded in this script."
        )
    resp = secretsmanager.get_secret_value(SecretId=GRAFANA_TOKEN_SECRET_ID)
    raw = resp["SecretString"]
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict) and "token" in parsed:
            return parsed["token"]
    except (ValueError, TypeError):
        pass
    return raw


def publish_grafana_annotation(grafana_token, args, prediction_id):
    import urllib.request

    if not GRAFANA_WORKSPACE_ENDPOINT:
        raise SystemExit("GRAFANA_WORKSPACE_ENDPOINT env var is required.")
    now_ms = int(time.time() * 1000)
    payload = {
        "time": now_ms,
        "timeEnd": now_ms + 60000,
        "title": f"{args.outcome}:{args.service}",
        "text": f"recommendation: {args.recommendation}; confidence: {args.confidence}",
        "tags": [
            f"tenant_id={TENANT_ID}",
            f"service_id={args.service}",
            f"metric_type={args.metric}",
            f"prediction_id={prediction_id}",
            f"fallback={str(args.fallback).lower()}",
        ],
        "isRegion": True,
    }
    body = json.dumps(payload).encode("utf-8")
    url = GRAFANA_WORKSPACE_ENDPOINT.rstrip("/") + "/api/annotations"
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {grafana_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            annotation_id = data.get("id")
            print(f"[grafana] Annotation published id={annotation_id} service={args.service}")
            return annotation_id
    except Exception as exc:
        print(f"[grafana] Annotation publish FAILED: {exc}")
        return None


def query_audit_by_correlation(dynamodb, correlation_id):
    resp = dynamodb.query(
        TableName=AUDIT_TABLE,
        IndexName="correlation-index",
        KeyConditionExpression="correlation_id = :c",
        ExpressionAttributeValues={":c": {"S": correlation_id}},
        Limit=5,
    )
    print(f"[audit] Query GSI correlation-index correlation_id={correlation_id} count={resp['Count']}")
    if resp["Count"] > 0:
        print(json.dumps(resp["Items"][0], indent=2, default=str))
    return resp["Count"]


def main():
    parser = argparse.ArgumentParser(description="Mock prediction/fallback annotation + audit evidence.")
    parser.add_argument("--service", default=None, help="service_id (payment-gw, ledger, fraud-detector)")
    parser.add_argument("--metric", default=None, help="metric_type (cpu_usage_percent, ...)")
    parser.add_argument("--outcome", default="prediction", choices=["prediction", "fallback", "error"])
    parser.add_argument("--fallback", action="store_true", help="mark as fallback event")
    parser.add_argument("--confidence", type=float, default=0.0)
    parser.add_argument("--recommendation", default="no-action")
    parser.add_argument("--query-correlation", help="query audit by correlation_id and exit")
    args = parser.parse_args()

    dynamodb = boto3.client("dynamodb", region_name=REGION)
    logs = boto3.client("logs", region_name=REGION)

    if args.query_correlation:
        query_audit_by_correlation(dynamodb, args.query_correlation)
        return

    if not args.service or not args.metric:
        parser.error("--service and --metric are required unless --query-correlation is used")

    correlation_id = f"corr-{uuid.uuid4().hex[:12]}"
    prediction_id = f"pred-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:4]}"
    ai_audit_id = f"ai-audit-mock-{uuid.uuid4().hex[:8]}"

    annotation_id = None
    grafana_token = None
    if GRAFANA_TOKEN_SECRET_ID and GRAFANA_WORKSPACE_ENDPOINT:
        secretsmanager = boto3.client("secretsmanager", region_name=REGION)
        try:
            grafana_token = get_grafana_token(secretsmanager)
            annotation_id = publish_grafana_annotation(grafana_token, args, prediction_id)
        except ClientError as exc:
            print(f"[grafana] Secret/annotation step skipped: {exc}")
    else:
        print("[grafana] Skipped: GRAFANA_TOKEN_SECRET_ID or GRAFANA_WORKSPACE_ENDPOINT not set (Grafana workspace not ready).")

    item = put_audit_item(dynamodb, args, correlation_id, prediction_id, annotation_id, ai_audit_id)
    put_audit_log(logs, args, correlation_id, prediction_id, status="ok" if annotation_id else "grafana-skipped")

    print("\n[evidence] Audit item sample (correlation/prediction/fallback fields):")
    print(json.dumps(item, indent=2, default=str))
    print(f"\n[evidence] correlation_id for GSI query: {correlation_id}")
    print(f"[evidence] prediction_id: {prediction_id}")
    print(f"[evidence] Grafana annotation id: {annotation_id}")


if __name__ == "__main__":
    main()