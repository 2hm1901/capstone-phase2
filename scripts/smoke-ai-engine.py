#!/usr/bin/env python3
"""SigV4 smoke test for the AI Engine API Gateway edge.

Usage:
  AI_ENGINE_ENDPOINT="$(terraform -chdir=infra/environments/sandbox output -raw ai_engine_endpoint)" \
  python3 scripts/smoke-ai-engine.py
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


REGION = os.environ.get("AWS_REGION", "us-east-1")
TENANT_ID = os.environ.get("TENANT_ID", "tenant-cdo08-demo")
SERVICE_ID = os.environ.get("SERVICE_ID", "payment-gw")
ENDPOINT = os.environ.get("AI_ENGINE_ENDPOINT", "").rstrip("/")


def main() -> int:
    if not ENDPOINT:
        print("AI_ENGINE_ENDPOINT is required", file=sys.stderr)
        return 2

    health = request("GET", f"{ENDPOINT}/health")
    print(f"[health] status={health['status']} body={health['body'][:300]}")

    payload = {
        "signal_window": build_signal_window(),
        "context": {
            "tenant_id": TENANT_ID,
            "service_id": SERVICE_ID,
            "source": "cdo08-smoke-ai-engine",
        },
    }
    prediction = request("POST", f"{ENDPOINT}/v1/predict", payload)
    print(f"[predict] status={prediction['status']} body={prediction['body'][:1000]}")

    return 0


def build_signal_window() -> list[dict]:
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    start = now - timedelta(minutes=119)
    points: list[dict] = []

    for minute in range(120):
        ts = start + timedelta(minutes=minute)
        points.append({
            "ts": ts.isoformat().replace("+00:00", "Z"),
            "tenant_id": TENANT_ID,
            "service_id": SERVICE_ID,
            "metric_type": "cpu_usage_percent",
            "value": 42.0 + (minute % 7),
            "labels": {
                "region": REGION,
                "source": "smoke-ai-engine",
            },
        })

    return points


def request(method: str, url: str, payload: dict | None = None) -> dict:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "X-Tenant-Id": TENANT_ID,
    }
    signed_headers = sign(method, url, body, headers)
    req = urllib.request.Request(url, data=body if body else None, headers=signed_headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return {
                "status": resp.status,
                "body": resp.read().decode("utf-8"),
            }
    except urllib.error.HTTPError as exc:
        return {
            "status": exc.code,
            "body": exc.read().decode("utf-8"),
        }


def sign(method: str, url: str, body: bytes, headers: dict[str, str]) -> dict[str, str]:
    credentials = boto3.Session().get_credentials()
    if credentials is None:
        raise RuntimeError("AWS credentials unavailable for SigV4 signing")

    aws_request = AWSRequest(method=method, url=url, data=body, headers=headers)
    SigV4Auth(credentials.get_frozen_credentials(), "execute-api", REGION).add_auth(aws_request)
    return dict(aws_request.headers)


if __name__ == "__main__":
    raise SystemExit(main())
