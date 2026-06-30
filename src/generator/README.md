# k6 Synthetic Telemetry Generator

This generator is a bounded k6 workload that emits telemetry to the CDO08 ingest API.

## Contract

Each POST body follows the telemetry schema:

```json
{
  "ts": "2026-06-30T02:00:00.000Z",
  "tenant_id": "tenant-cdo08-demo",
  "service_id": "payment-gw",
  "metric_type": "api_latency_ms",
  "value": 150.5,
  "labels": {
    "region": "us-east-1",
    "environment": "sandbox",
    "scenario": "gradual_drift"
  },
  "schema_version": "v1.0",
  "correlation_id": "uuid"
}
```

Service IDs are aligned with the AI engine baseline/evidence:

- `payment-gw`
- `ledger`
- `fraud-detector`

Supported scenarios:

- `gradual_drift`
- `sudden_spike`
- `slow_leak`
- `noisy_baseline`

## Runtime config

| Env var | Default | Notes |
|---|---:|---|
| `INGEST_API_ENDPOINT` | required | API Gateway telemetry endpoint |
| `TENANT_ID` | `tenant-cdo08-demo` | Tenant value in every event |
| `SERVICE_LIST` | `payment-gw,ledger,fraud-detector` | Comma-separated service IDs |
| `SCENARIO` | `noisy_baseline` | Single scenario; use `all` to rotate through `SCENARIO_LIST` |
| `SCENARIO_LIST` | all four scenarios | Backward-compatible Terraform env |
| `EMIT_INTERVAL_SECONDS` | `60` | Sleep between k6 iterations |
| `RUN_DURATION_SECONDS` | `600` | Bounded run duration; use `7200` for a 2-hour evidence window |
| `AWS_REGION` | `us-east-1` | SigV4 signing region |

## IAM/SigV4 auth

The ingest API uses IAM auth. The k6 script signs requests with SigV4 for `execute-api`.

Credential source:

- On ECS Fargate, credentials come from the task role metadata endpoint.
- For local smoke runs, k6 can use standard `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN` environment variables.

Do not hard-code AWS access keys or secrets in code, Terraform, README examples, or logs.

## Build and push

Run from `capstone-phase2`:

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 894597652722.dkr.ecr.us-east-1.amazonaws.com

docker build -t cdo08-sandbox-generator:k6-v1 ./src/generator

docker tag cdo08-sandbox-generator:k6-v1 \
  894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:k6-v1

docker push 894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:k6-v1
```

Set `generator_image_uri` to the pushed tag before planning/applying:

```hcl
generator_image_uri = "894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:k6-v1"
```

## Terraform checks

Run from `capstone-phase2`:

```bash
terraform -chdir=infra/environments/sandbox fmt -check -recursive
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan
```

## Local k6 smoke run

This sends signed requests using your local AWS credential provider env:

```bash
docker run --rm \
  -e INGEST_API_ENDPOINT="$INGEST_API_ENDPOINT" \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e SCENARIO=noisy_baseline \
  -e RUN_DURATION_SECONDS=60 \
  cdo08-sandbox-generator:k6-v1
```

## Run ECS task

After Terraform has a task definition, run a bounded scenario:

```bash
python scripts/run-scenario.py gradual_drift payment-gw 7200
```

Or use AWS CLI directly:

```bash
aws ecs run-task \
  --cluster cdo08-sandbox-generator-cluster \
  --task-definition cdo08-sandbox-generator \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<private_subnet_id>],securityGroups=[<generator_sg_id>],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"generator","environment":[{"name":"SCENARIO","value":"gradual_drift"},{"name":"SERVICE_LIST","value":"payment-gw"},{"name":"RUN_DURATION_SECONDS","value":"7200"}]}]}'
```

## Evidence checklist

Capture these items for the PR:

- Docker build output for `src/generator`.
- ECS `run-task` response showing task ARN and overrides for `SCENARIO`/`RUN_DURATION_SECONDS`.
- Generator CloudWatch logs from `/ecs/cdo08-sandbox-generator` with `metric_emit_result` and HTTP `202`.
- Ingest Lambda logs from `/aws/lambda/cdo08-sandbox-ingest` showing validation success for a matching `correlation_id`.
- SQS queue metrics showing messages received/sent, or writer logs from `/aws/lambda/cdo08-sandbox-telemetry-writer` showing `remote_write_status=success`.

Useful log commands:

```bash
aws logs describe-log-streams \
  --log-group-name /ecs/cdo08-sandbox-generator \
  --order-by LastEventTime \
  --descending \
  --max-items 1

aws logs get-log-events \
  --log-group-name /ecs/cdo08-sandbox-generator \
  --log-stream-name '<latest-stream-name>'

aws logs describe-log-streams \
  --log-group-name /aws/lambda/cdo08-sandbox-ingest \
  --order-by LastEventTime \
  --descending \
  --max-items 1

aws logs describe-log-streams \
  --log-group-name /aws/lambda/cdo08-sandbox-telemetry-writer \
  --order-by LastEventTime \
  --descending \
  --max-items 1
```
