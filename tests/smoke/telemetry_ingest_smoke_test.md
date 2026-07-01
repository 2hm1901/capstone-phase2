# Telemetry Ingest Smoke Test

Use this after the PR is applied to collect evidence for telemetry ingest validation.

## Resolve Terraform outputs

```bash
cd infra/environments/sandbox
export INGEST_API_ENDPOINT="$(terraform output -raw ingest_api_endpoint)"
export TELEMETRY_QUEUE_URL="$(terraform output -raw telemetry_queue_url)"
export INGEST_LOG_GROUP_NAME="/aws/lambda/$(terraform output -raw ingest_lambda_name)"
```

## Check Terraform before deployment

```bash
cd ../../..
make tf-fmt-check
make tf-validate
make tf-plan
```

## Valid payload

```bash
curl --request POST "$INGEST_API_ENDPOINT" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  --header "Content-Type: application/json" \
  --header "X-Tenant-Id: tenant-cdo08-demo" \
  --header "X-Correlation-Id: corr-valid-001" \
  --data '{
    "schema_version": "v1.0",
    "correlation_id": "corr-valid-001",
    "ts": "2026-06-29T10:30:00.000Z",
    "tenant_id": "tenant-cdo08-demo",
    "service_id": "payment-api",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {"region": "us-east-1"}
  }'
```

Expected result: HTTP `202`, response contains the same `correlation_id`, and the Lambda log contains `telemetry_validation_passed`.

Check SQS:

```bash
aws sqs receive-message \
  --queue-url "$TELEMETRY_QUEUE_URL" \
  --max-number-of-messages 1 \
  --message-attribute-names All \
  --visibility-timeout 5
```

## Verify CloudWatch validation logs

```bash
aws logs filter-log-events \
  --log-group-name "$INGEST_LOG_GROUP_NAME" \
  --filter-pattern '"telemetry_validation_passed"' \
  --limit 20

aws logs filter-log-events \
  --log-group-name "$INGEST_LOG_GROUP_NAME" \
  --filter-pattern '"telemetry_validation_failed"' \
  --limit 20
```

## Verify CloudWatch metrics

```bash
aws cloudwatch list-metrics \
  --namespace CDO/TelemetryIngest \
  --metric-name TelemetryValidationPassed

aws cloudwatch list-metrics \
  --namespace CDO/TelemetryIngest \
  --metric-name TelemetryValidationFailed
```

## Invalid metric type

```bash
curl --request POST "$INGEST_API_ENDPOINT" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  --header "Content-Type: application/json" \
  --header "X-Tenant-Id: tenant-cdo08-demo" \
  --header "X-Correlation-Id: corr-invalid-metric-001" \
  --data '{
    "schema_version": "v1.0",
    "correlation_id": "corr-invalid-metric-001",
    "ts": "2026-06-29T10:30:00.000Z",
    "tenant_id": "tenant-cdo08-demo",
    "service_id": "payment-api",
    "metric_type": "not_in_contract",
    "value": 450.5,
    "labels": {"region": "us-east-1"}
  }'
```

Expected result: HTTP `400`, error `unsupported_metric_type`, and the Lambda log contains `telemetry_validation_failed`.

## Invalid tenant isolation

```bash
curl --request POST "$INGEST_API_ENDPOINT" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  --header "Content-Type: application/json" \
  --header "X-Tenant-Id: tenant-a" \
  --header "X-Correlation-Id: corr-tenant-mismatch-001" \
  --data '{
    "schema_version": "v1.0",
    "correlation_id": "corr-tenant-mismatch-001",
    "ts": "2026-06-29T10:30:00.000Z",
    "tenant_id": "tenant-b",
    "service_id": "payment-api",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {"region": "us-east-1"}
  }'
```

Expected result: HTTP `403`, error `tenant_mismatch`, and no message should be sent to SQS.

## Invalid PII label

```bash
curl --request POST "$INGEST_API_ENDPOINT" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  --header "Content-Type: application/json" \
  --header "X-Tenant-Id: tenant-cdo08-demo" \
  --header "X-Correlation-Id: corr-pii-001" \
  --data '{
    "schema_version": "v1.0",
    "correlation_id": "corr-pii-001",
    "ts": "2026-06-29T10:30:00.000Z",
    "tenant_id": "tenant-cdo08-demo",
    "service_id": "payment-api",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {"region": "us-east-1", "email": "user@example.com"}
  }'
```

Expected result: HTTP `400`, error `pii_detected`, and no raw payload or credential appears in CloudWatch logs.
