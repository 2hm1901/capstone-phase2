# Test & Eval Report - Task Force 4 · CDO08

**Document owner:** CDO08  
**Status:** Final draft for W12 Evidence Pack #2  
**Last updated:** 2026-07-01

## 1. Test objective

Mục tiêu W12 của CDO08 là chứng minh platform Foresight Lens chạy được end-to-end trên AWS, không chỉ có sơ đồ:

```text
k6 ECS generator
-> API Gateway ingest
-> Lambda Ingest
-> SQS + DLQ
-> Lambda Writer
-> AMP
-> Prediction Lambda
-> Serving Adapter
-> AI API Gateway + internal ALB
-> AI Engine ECS
-> DynamoDB audit + Grafana annotation
```

Các test tập trung vào 5 câu hỏi:

1. Telemetry từ ECS k6 có được ingest, buffer, remote-write vào AMP và hiển thị trên Grafana không?
2. Prediction Lambda có query được window 120 phút từ AMP và gọi AI Engine qua path bảo mật không?
3. AI Engine có tạo recommendation/actionable annotation và audit record không?
4. Khi dependency lỗi hoặc telemetry stale, hệ thống có tránh spam annotation và có fallback/fail-open không?
5. Cost/security/operability có đủ evidence để defend W12 không?

## 2. Test coverage

| Test type | Tool / source | Coverage |
|---|---|---|
| Terraform validation | `terraform fmt`, `terraform validate`, `terraform plan/apply` | Infra modules, remote state, IAM, networking, ECS, Lambda, API Gateway, AMP, Grafana, DynamoDB |
| Synthetic workload | k6 on ECS Fargate | 3 services: `payment-gw`, `ledger`, `fraud-detector`; scenarios `noisy_baseline`, `sudden_spike`, `gradual_drift`, `slow_leak` |
| Telemetry E2E | CloudWatch Logs, SQS attributes, Grafana | k6 → API Gateway → Lambda → SQS → Writer → AMP → Grafana |
| AI integration | `scripts/smoke-ai-engine.py`, Lambda logs | AI `/health`, `/v1/predict`, Prediction Lambda, Serving Adapter Lambda |
| Audit/annotation | Grafana dashboard, DynamoDB query | Annotation popup, tags, audit/correlation ID, DynamoDB item |
| Failure handling | Manual fault injection / stale window observation | AI image architecture failure, AI 400 missing data, annotation spam/cooldown fix, stale telemetry skip |
| Security | IAM/SigV4/config review | API Gateway `AWS_IAM`, private AI ALB, VPC Link, KMS, Secrets Manager, IAM Identity Center |
| Cost | AWS Budget / Cost Explorer | Budget guardrail and current service cost forecast |

## 3. Environment under test

| Item | Value |
|---|---|
| AWS account | `894597652722` |
| Region | `us-east-1` |
| Terraform environment | `infra/environments/sandbox` |
| Ingest API | `https://vbs9nb95i8.execute-api.us-east-1.amazonaws.com/sandbox/v1/telemetry` |
| AI API | `https://quu5b0vqpc.execute-api.us-east-1.amazonaws.com/sandbox` |
| AI internal ALB | `internal-cdo08-sandbox-ai-engine-alb-2003992455.us-east-1.elb.amazonaws.com` |
| AMP workspace | `ws-eb0a1ab7-9c8d-4656-89b0-4f5a2e4cf507` |
| Grafana workspace | `g-9411285a4b.grafana-workspace.us-east-1.amazonaws.com` |
| Grafana dashboard | `CDO08 Foresight Lens Overview` |
| Audit table | `cdo08-sandbox-audit` |
| Baseline bucket | `cdo08-sandbox-ai-baselines-894597652722` |
| Generator cluster | `cdo08-sandbox-generator-cluster` |

## 4. Telemetry pipeline results

### 4.1 k6 generator

ECS k6 generator đã chạy được real mode trong private subnet. Trong các lần test, k6 log cho thấy:

- `http_req_failed: 0.00%`
- API response status `202`
- service IDs khớp AI baseline: `payment-gw`, `ledger`, `fraud-detector`
- scenario labels xuất hiện trên Grafana, ví dụ `payment-gw / sudden_spike`
- final generator image tag cho phased scenario: `k6-phased-scenarios-20260702-1`
- anomaly scenarios dùng `ANOMALY_START_SECONDS=7200`: 120 phút baseline warm-up trước khi bắt đầu drift/spike/leak.

Command kiểm chứng:

```bash
aws logs tail /ecs/cdo08-sandbox-generator \
  --region us-east-1 \
  --since 30m \
  --filter-pattern '"metric_emit_result"'
```

Evidence cần chụp:

- k6 summary sau phased run, ví dụ `RUN_DURATION_SECONDS=10800` cho `sudden_spike`.
- CloudWatch log có `metric_emit_result`, `status:202`, đủ 3 services.

### 4.2 Queue and DLQ

SQS queue đã drain về 0 sau khi writer xử lý. DLQ cần được chụp lại ở trạng thái 0 cho clean run.

Command kiểm chứng:

```bash
aws sqs get-queue-attributes \
  --region us-east-1 \
  --queue-url "$(terraform -chdir=infra/environments/sandbox output -raw telemetry_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed
```

```bash
aws sqs get-queue-attributes \
  --region us-east-1 \
  --queue-url "$(terraform -chdir=infra/environments/sandbox output -raw telemetry_dlq_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed
```

Expected clean result:

```json
{
  "ApproximateNumberOfMessages": "0",
  "ApproximateNumberOfMessagesNotVisible": "0",
  "ApproximateNumberOfMessagesDelayed": "0"
}
```

### 4.3 AMP and Grafana

Grafana dashboard đã hiển thị metric series từ AMP. Dashboard hiện có 7 panels:

- CPU usage
- Memory usage
- Active connections
- API latency
- Queue depth
- DB connection pool
- Cache hit rate

Dashboard đã được cập nhật để visualize đủ 7 metric theo telemetry contract/generator.

## 5. AI integration results

### 5.1 AI Engine health and predict

AI Engine đã chạy trên ECS Fargate sau khi rebuild image đúng architecture `linux/amd64`. Smoke test đã trả:

- `/health`: HTTP 200
- `/v1/predict`: HTTP 200 với `anomaly`, `severity`, `recommendation`, `confidence`, `audit_id`

Command:

```bash
AI_ENGINE_ENDPOINT="$(terraform -chdir=infra/environments/sandbox output -raw ai_engine_endpoint)" \
  python scripts/smoke-ai-engine.py
```

Evidence cần chụp:

- Terminal output health/predict HTTP 200.
- ECS AI Engine service desired/running = 2.
- Target group healthy.

### 5.2 Prediction Lambda and Serving Adapter

Prediction Lambda chạy theo EventBridge Scheduler mỗi 5 phút/service và có thể invoke thủ công. Logs đã ghi nhận:

- `prediction_started`
- `prediction_completed`
- service IDs: `payment-gw`, `ledger`, `fraud-detector`

Serving Adapter logs đã ghi nhận các case:

- AI call success.
- AI non-retryable HTTP 400 khi input window thiếu dữ liệu liên tục.
- Sau fix, stale/no recent telemetry được skip để tránh annotation spam.

Evidence cần chụp:

- Prediction Lambda logs cho một successful run.
- Serving Adapter logs cho AI success.
- Logs sau fix cooldown/freshness chứng minh không còn tạo annotation khi telemetry stale.

## 6. Grafana annotation and audit results

Grafana annotation đã xuất hiện trên dashboard. Popup annotation chứa các thông tin cần thiết:

- Service.
- Tenant.
- Severity.
- Action.
- Target.
- Confidence.
- Reasoning.
- Audit ID.
- Correlation ID.
- Tags như `prediction`, `tenant:<id>`, `service:<service_id>`, `anomaly:true`, `action:<ACTION>`.

DynamoDB audit table `cdo08-sandbox-audit` là nơi chứng minh traceability. Cần query audit item bằng `correlation_id` từ popup Grafana để chứng minh annotation ↔ audit cùng một event.

Command:

```bash
aws dynamodb query \
  --region us-east-1 \
  --table-name cdo08-sandbox-audit \
  --index-name correlation-index \
  --key-condition-expression "correlation_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"<correlation-id-from-grafana-popup>"}}'
```

Evidence cần chụp:

- Grafana annotation popup.
- DynamoDB audit query result cùng `correlation_id`.
- Nếu có fallback test: annotation/audit có `fallback=true`.

## 7. Scenario evaluation status

| Scenario | Services | Status | Notes |
|---|---|---|---|
| `noisy_baseline` | 3 services | Implemented and visible in Grafana | Dùng để chứng minh baseline/noise; cần capture false-positive count nếu muốn claim FP ≤12% |
| `sudden_spike` | 3 services | Implemented and generated annotations | Phased run: 120 phút baseline, sau đó spike cycle; dùng tốt nhất cho live demo anomaly/recommendation |
| `gradual_drift` | 3 services | Implemented, needs final evidence | Phased run: 120 phút baseline, sau đó drift; dùng để đo lead time ≥15 phút |
| `slow_leak` | 3 services | Implemented, needs final evidence | Phased run: 120 phút baseline, sau đó memory leak; dùng để demo memory/OOM recommendation |
| `all` | mixed | Implemented | Không nên dùng cho precision/recall chính thức vì ground truth khó giải thích |

Recommendation cho final demo: chạy **3 services + 1 scenario** trong một window, ví dụ `sudden_spike`, với `ANOMALY_START_SECONDS=7200` và `RUN_DURATION_SECONDS=10800` để dashboard có baseline liền mạch, anomaly phase rõ ràng và annotation dễ giải thích.

## 8. SLO and acceptance evidence

| Requirement | Target | Current evidence | Status |
|---|---:|---|---|
| Test window | ≥2h | k6 real run 2h completed | Pass, screenshot required |
| Multi-service | ≥3 services | `payment-gw`, `ledger`, `fraud-detector` in generator/Grafana | Pass |
| Telemetry retention | ≥90d | AMP managed retention exceeds 90d | Pass by design |
| Prediction lookback | ≥120m | Prediction Lambda queries 120m window | Pass by implementation |
| Lead time | ≥15m | Needs final timestamp measurement from scenario | Evidence pending |
| FP rate | ≤12% | Needs noisy_baseline count | Evidence pending |
| Catch drift | ≥80% | Sudden spike detected; broader matrix pending | Partially proven |
| Actionable recommendation | action + target + from→to + confidence + evidence | AI response/annotation contains these fields | Pass for observed samples |
| Audit every prediction | DynamoDB audit + AI audit ID | Audit item query required | Evidence pending |
| Fail-open fallback | Static threshold if AI down | Code path exists; fault injection screenshot required | Evidence pending |
| Email notification | SNS email for prediction/fallback anomaly | SNS topic/subscription implemented; confirmation/e-mail screenshot required | Evidence pending |

## 9. Failure analysis

| Failure | Root cause | Fix | Result |
|---|---|---|---|
| ECS AI Engine `exec format error` | Docker image built from Mac for wrong architecture | Rebuilt/pushed image with `docker buildx --platform linux/amd64` and immutable tag | ECS tasks healthy |
| AI smoke returned 404 | Smoke script/API path mismatch | Corrected path to match deployed AI API | `/health` and `/predict` pass |
| AI returned 400 `Missing data detected` | Prediction window had gaps >1 minute | Use continuous real k6 window; stale telemetry guard added | AI no longer called blindly on stale windows |
| Annotation spam | Cooldown/dedupe needed DynamoDB `Query`; stale data still triggered scheduler | Added DynamoDB Query permission, freshness guard, point annotation, cooldown/dedupe | Need final post-apply evidence |
| Dashboard confusing with mixed services/scenarios | Grafana panels show `service/scenario` series together | Use filters and run one scenario per window for demo | Operational workaround |

## 10. Security test status

| Test | Expected | Status |
|---|---|---|
| Ingest without SigV4 | 403/Unauthorized | Need screenshot |
| k6 IAM signed ingest | 202 Accepted | Pass from logs |
| AI API through SigV4 | Serving Adapter can call AI API | Pass from smoke/path |
| AI ALB private | No public ALB access; API Gateway/VPC Link only | Pass by architecture, screenshot required |
| Secret not in repo/logs | No Grafana token in source/log | Pass by convention; run grep/screenshot if needed |
| DynamoDB audit encrypted | SSE-KMS | Pass by Terraform, screenshot required |

## 11. Final evidence checklist

- [ ] k6 phased scenario summary with `http_req_failed: 0.00%`.
- [ ] Grafana dashboard showing 3 services in one scenario.
- [ ] Grafana annotation popup with recommendation.
- [ ] DynamoDB audit item with matching correlation ID.
- [ ] Prediction Lambda logs success and stale/cooldown skip.
- [ ] Serving Adapter logs AI success.
- [ ] SQS queue and DLQ empty after clean run.
- [ ] AI ECS service and target group healthy.
- [ ] API Gateway AI route `AWS_IAM` + VPC Link.
- [ ] Cost Explorer/Budget screenshot.
- [ ] Fallback injected failure evidence.
- [ ] Active connections panel visible on Grafana after reprovisioning dashboard.
- [ ] SNS subscription confirmed and prediction/fallback email alert received.

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md)
- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`04_deployment_design.md`](04_deployment_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`08_adrs.md`](08_adrs.md)
- [`W12_EVIDENCE_PACK.md`](W12_EVIDENCE_PACK.md)
