import os
import sys
import time
import json
import uuid
import random
from datetime import datetime, timezone
import urllib.request
import urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

# Load configuration from environment variables
INGEST_API_ENDPOINT = os.environ.get("INGEST_API_ENDPOINT")
TENANT_ID = os.environ.get("TENANT_ID", "tenant-cdo08-demo")
SERVICE_LIST = [s.strip() for s in os.environ.get("SERVICE_LIST", "payment-api,queue-worker,gateway-api").split(",") if s.strip()]
SCENARIO = os.environ.get("SCENARIO", "noisy_baseline")
EMIT_INTERVAL = int(os.environ.get("EMIT_INTERVAL_SECONDS", "60"))
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

METRIC_TYPES = [
    "cpu_usage_percent",
    "memory_usage_percent",
    "active_connections",
    "db_connection_pool_pct",
    "queue_depth",
    "cache_hit_rate_pct",
    "api_latency_ms"
]

def log(msg, level="INFO"):
    timestamp = datetime.now(timezone.utc).isoformat()
    print(json.dumps({
        "timestamp": timestamp,
        "level": level,
        "component": "synthetic-generator",
        "message": msg
    }))

def get_base_metrics(service):
    if service == "payment-api":
        return {
            "cpu_usage_percent": 30.0,
            "memory_usage_percent": 40.0,
            "active_connections": 200.0,
            "db_connection_pool_pct": 25.0,
            "queue_depth": 0.0,
            "cache_hit_rate_pct": 90.0,
            "api_latency_ms": 150.0,
        }
    elif service == "queue-worker":
        return {
            "cpu_usage_percent": 45.0,
            "memory_usage_percent": 50.0,
            "active_connections": 10.0,
            "db_connection_pool_pct": 35.0,
            "queue_depth": 120.0,
            "cache_hit_rate_pct": 80.0,
            "api_latency_ms": 800.0,
        }
    else: # gateway-api
        return {
            "cpu_usage_percent": 20.0,
            "memory_usage_percent": 35.0,
            "active_connections": 500.0,
            "db_connection_pool_pct": 10.0,
            "queue_depth": 0.0,
            "cache_hit_rate_pct": 95.0,
            "api_latency_ms": 50.0,
        }

def calculate_metric_value(scenario, service, metric_type, elapsed_minutes):
    base = get_base_metrics(service)[metric_type]
    
    # 1. Add normal noise (+/- 5%)
    noise_factor = random.uniform(-0.05, 0.05)
    val = base * (1.0 + noise_factor)
    
    # 2. Apply scenario logic
    if scenario == "noisy_baseline":
        pass
        
    elif scenario == "gradual_drift":
        # CPU, active_connections, db_pool, queue_depth, and latency drift upwards. cache hit drifts down.
        if metric_type == "cache_hit_rate_pct":
            val = max(0.0, base * (1.0 - 0.002 * elapsed_minutes))
        else:
            val = base * (1.0 + 0.02 * elapsed_minutes)
            
    elif scenario == "sudden_spike":
        # Spike for 5 minutes every 30 minutes cycle (minutes 15-20, 45-50, etc.)
        cycle_minute = elapsed_minutes % 30.0
        if 15.0 <= cycle_minute < 20.0:
            if metric_type == "cache_hit_rate_pct":
                val = max(0.0, base * 0.3)
            elif metric_type == "queue_depth":
                val = base * 10.0 + 500
            else:
                val = base * 5.0
                
    elif scenario == "slow_leak":
        # Memory leak specifically grows memory usage by 0.4% absolute per minute.
        if metric_type == "memory_usage_percent":
            val = min(100.0, base + 0.4 * elapsed_minutes)
            
    # Post-process bounds
    if metric_type in ["cpu_usage_percent", "memory_usage_percent", "db_connection_pool_pct", "cache_hit_rate_pct"]:
        val = max(0.0, min(100.0, val))
    else:
        val = max(0.0, val)
        
    return round(val, 2)

def get_metric_labels(service, metric_type, region):
    labels = {"region": region, "environment": "sandbox"}
    if metric_type == "db_connection_pool_pct":
        labels["db_type"] = "postgres"
    elif metric_type == "queue_depth":
        labels["queue_name"] = f"{service}-queue"
    elif metric_type == "cache_hit_rate_pct":
        labels["cache_type"] = "redis"
    return labels

def send_request_with_sigv4(url, payload, region):
    data_bytes = json.dumps(payload).encode("utf-8")
    correlation_id = payload["correlation_id"]
    
    headers = {
        "Content-Type": "application/json",
        "X-Tenant-Id": payload["tenant_id"],
        "X-Correlation-Id": correlation_id
    }
    
    session = boto3.Session()
    credentials = session.get_credentials()
    frozen_creds = credentials.get_frozen_credentials() if credentials else None
    
    if frozen_creds:
        request = AWSRequest(
            method="POST",
            url=url,
            data=data_bytes,
            headers=headers
        )
        auth = SigV4Auth(frozen_creds, "execute-api", region)
        auth.add_auth(request)
        signed_headers = dict(request.headers)
    else:
        signed_headers = headers

    req = urllib.request.Request(
        url=url,
        data=data_bytes,
        headers=signed_headers,
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            res_body = response.read().decode("utf-8")
            return response.status, res_body
    except urllib.error.HTTPError as error:
        res_body = error.read().decode("utf-8") if error else ""
        return error.code, res_body
    except Exception as error:
        return 500, str(error)

def main():
    log(f"Starting synthetic generator in scenario '{SCENARIO}'")
    log(f"Configured services: {SERVICE_LIST}")
    log(f"Emit interval: {EMIT_INTERVAL} seconds")
    
    if not INGEST_API_ENDPOINT:
        log("Error: INGEST_API_ENDPOINT environment variable is not configured.", "ERROR")
        sys.exit(1)
        
    start_time = time.time()
    
    while True:
        elapsed_minutes = (time.time() - start_time) / 60.0
        log(f"Running metrics simulation iteration. Elapsed time: {elapsed_minutes:.2f} minutes")
        
        for service in SERVICE_LIST:
            correlation_id = str(uuid.uuid4())
            for metric in METRIC_TYPES:
                val = calculate_metric_value(SCENARIO, service, metric, elapsed_minutes)
                labels = get_metric_labels(service, metric, AWS_REGION)
                
                payload = {
                    "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                    "tenant_id": TENANT_ID,
                    "service_id": service,
                    "metric_type": metric,
                    "value": val,
                    "labels": labels,
                    "schema_version": "v1.0",
                    "correlation_id": correlation_id
                }
                
                log(f"Emitting metric: service={service}, metric={metric}, value={val}")
                
                status, response_body = send_request_with_sigv4(INGEST_API_ENDPOINT, payload, AWS_REGION)
                
                if status in (200, 201, 202):
                    log(f"Successfully sent metric: service={service}, metric={metric}, status={status}")
                else:
                    log(f"Failed to send metric: service={service}, metric={metric}, status={status}, response={response_body}", "WARNING")
                    
        time.sleep(EMIT_INTERVAL)

if __name__ == "__main__":
    main()
