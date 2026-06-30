# Module: synthetic_generator

Owner: Thuy (CDO08)

This module deploys the ECS Fargate scaffolding for the k6 synthetic telemetry generator. The generator emits telemetry for `payment-gw`, `ledger`, and `fraud-detector` across `gradual_drift`, `sudden_spike`, `slow_leak`, and `noisy_baseline`.

## Resources

| Resource | Name | Notes |
|---|---|---|
| ECR repository | `cdo08-sandbox-generator` | Private image repo, immutable tags, scan on push |
| ECS cluster | `cdo08-sandbox-generator-cluster` | Dedicated Fargate cluster |
| ECS task definition | `cdo08-sandbox-generator` | Created only when `generator_image_uri` is non-empty |
| IAM task execution role | `cdo08-sandbox-generator-execution-role` | ECR pull and CloudWatch Logs write |
| IAM task role | `module.security_baseline.generator_role_arn` | Runtime role; used by k6 for SigV4 via ECS metadata |
| CloudWatch log group | `/ecs/cdo08-sandbox-generator` | Configurable retention |
| EventBridge rule | `cdo08-sandbox-generator-schedule` | Disabled by default |

## Runtime

The container entrypoint is `k6 run /scripts/generator.js`. The task is bounded by `RUN_DURATION_SECONDS` and does not run forever by default.

Important variables:

| Variable | Default | Description |
|---|---:|---|
| `service_list` | `payment-gw,ledger,fraud-detector` | Comma-separated service IDs |
| `scenario` | `noisy_baseline` | Single scenario; `all` rotates through `scenario_list` |
| `scenario_list` | all four scenarios | Backward-compatible scenario list |
| `emit_interval_seconds` | `60` | k6 sleep between emit iterations |
| `run_duration_seconds` | `600` | Bounded k6 duration; use `7200` for 2-hour evidence |
| `ingest_api_endpoint` | required | API Gateway telemetry endpoint |

## Auth

Ingest uses API Gateway IAM auth. The k6 script signs each request with SigV4 for `execute-api` using the ECS task role credentials from the task metadata endpoint. No static AWS access key or secret is injected by Terraform.

## Manual run

```bash
aws ecs run-task \
  --cluster cdo08-sandbox-generator-cluster \
  --task-definition cdo08-sandbox-generator \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<private_subnet_id>],securityGroups=[<generator_sg_id>],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"generator","environment":[{"name":"SCENARIO","value":"gradual_drift"},{"name":"RUN_DURATION_SECONDS","value":"7200"}]}]}'
```

The EventBridge rule remains disabled by default. Enable it only for a planned test window, then disable it after evidence collection.
