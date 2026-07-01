#!/usr/bin/env python3
"""Provision CDO08 Grafana datasource and dashboard through Grafana HTTP API.

Prerequisites:
  1. Terraform has created Amazon Managed Grafana workspace.
  2. A Grafana service-account token has been stored in Secrets Manager:
     {"url":"https://<workspace-endpoint>","token":"<service-account-token>"}

This script intentionally keeps Grafana token usage outside Terraform state.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

import boto3


REGION = os.environ.get("AWS_REGION", "us-east-1")
DATASOURCE_UID = os.environ.get("GRAFANA_DATASOURCE_UID", "amp-cdo08")
DASHBOARD_PATH = os.environ.get(
    "GRAFANA_DASHBOARD_PATH",
    "grafana/dashboards/foresight-lens-overview.json",
)


def main():
    outputs = terraform_outputs()
    grafana_secret_arn = output_value(outputs, "grafana_secret_arn")
    grafana_endpoint = output_value(outputs, "grafana_workspace_endpoint")
    amp_workspace_id = output_value(outputs, "amp_workspace_id")

    if not grafana_endpoint:
        raise SystemExit("grafana_workspace_endpoint is empty. Apply with create_grafana_workspace=true first.")
    if not grafana_secret_arn:
        raise SystemExit("grafana_secret_arn is empty.")
    if not amp_workspace_id:
        raise SystemExit("amp_workspace_id is empty.")

    secret = get_secret(grafana_secret_arn)
    grafana_url = normalize_url(secret.get("url") or grafana_endpoint)
    token = secret.get("token") or secret.get("api_token")
    if not token:
        raise SystemExit("Grafana token secret must contain JSON with key 'token' or 'api_token'.")

    amp_url = f"https://aps-workspaces.{REGION}.amazonaws.com/workspaces/{amp_workspace_id}"
    datasource_id = upsert_amp_datasource(grafana_url, token, amp_url)
    dashboard_uid = import_dashboard(grafana_url, token)

    print(json.dumps({
        "grafana_url": grafana_url,
        "datasource_uid": DATASOURCE_UID,
        "datasource_id": datasource_id,
        "dashboard_uid": dashboard_uid,
        "dashboard_url": f"{grafana_url.rstrip('/')}/d/{dashboard_uid}",
    }, indent=2))


def terraform_outputs():
    result = subprocess.run(
        ["terraform", "-chdir=infra/environments/sandbox", "output", "-json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def output_value(outputs, name):
    item = outputs.get(name)
    if not item:
        return None
    return item.get("value")


def get_secret(secret_id):
    client = boto3.client("secretsmanager", region_name=REGION)
    value = client.get_secret_value(SecretId=secret_id)["SecretString"]
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        parsed = {"token": value}
    return parsed


def upsert_amp_datasource(grafana_url, token, amp_url):
    payload = {
        "name": "CDO08 AMP",
        "type": "prometheus",
        "uid": DATASOURCE_UID,
        "access": "proxy",
        "url": amp_url,
        "isDefault": True,
        "jsonData": {
            "httpMethod": "POST",
            "sigV4Auth": True,
            "sigV4AuthType": "default",
            "sigV4Region": REGION,
            "timeInterval": "60s",
        },
    }

    existing = grafana_request(grafana_url, token, "GET", f"/api/datasources/uid/{DATASOURCE_UID}", allow_404=True)
    if existing is None:
        created = grafana_request(grafana_url, token, "POST", "/api/datasources", payload)
        return created.get("datasource", {}).get("id") or created.get("id")

    updated = grafana_request(grafana_url, token, "PUT", f"/api/datasources/uid/{DATASOURCE_UID}", payload)
    return updated.get("datasource", {}).get("id") or existing.get("id")


def import_dashboard(grafana_url, token):
    with open(DASHBOARD_PATH, "r", encoding="utf-8") as handle:
        dashboard = json.load(handle)

    payload = {
        "dashboard": dashboard,
        "folderId": 0,
        "overwrite": True,
        "message": "Provision CDO08 Foresight Lens dashboard",
    }
    response = grafana_request(grafana_url, token, "POST", "/api/dashboards/db", payload)
    return response.get("uid") or dashboard.get("uid")


def grafana_request(grafana_url, token, method, path, payload=None, allow_404=False):
    body = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(
        f"{grafana_url.rstrip('/')}{path}",
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        if allow_404 and error.code == 404:
            return None
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Grafana API {method} {path} failed: HTTP {error.code} {detail}") from error


def normalize_url(value):
    if value.startswith("http://") or value.startswith("https://"):
        return value.rstrip("/")
    return f"https://{value.rstrip('/')}"


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
