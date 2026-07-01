# Phân tích chi phí - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Final draft for W12 Evidence Pack #2

**Last updated:** 2026-07-01

## 1. Mục tiêu cost

CDO08 cần chứng minh platform Foresight Lens có thể chạy dưới rough cap **$200/tháng** cho scope capstone. Chi phí cần được giải thích theo driver chính, không chỉ đưa tổng số. Với kiến trúc hiện tại, cost driver quan trọng nhất là:

1. AI Engine Runtime ECS Fargate chạy 24/7.
2. Internal ALB cho AI Engine.
3. Amazon Managed Grafana user/workspace.
4. CloudWatch logs/alarms.
5. NAT Gateway của workload VPC nếu để chạy 24/7 ngoài test window.
6. Telemetry ingestion volume nếu sampling interval quá dày.

Telemetry data point là yếu tố cần kiểm soát, nhưng với scope demo `3 services × 7 metrics × 60s` thì AMP ingest/query cost dự kiến thấp. Rủi ro chỉ tăng mạnh nếu sampling giảm xuống 10s/1s hoặc volume tiến gần mức contract peak.

## 2. Assumptions for W12 forecast

| Assumption | Value | Note |
|---|---:|---|
| AWS region | `us-east-1` | Region đã cấu hình cho shared sandbox account |
| Services demo | 3 | `payment-gw`, `ledger`, `fraud-detector` |
| Metrics/service | 7 | Theo Telemetry Contract |
| Telemetry emit interval | 60s | 1 data point/phút/metric/service |
| Prediction interval | 5 phút/service | EventBridge Scheduler |
| Prediction lookback | ≥120 phút | AI API Contract |
| AI Engine compute | ECS Fargate 0.5 vCPU, 1 GB | Theo Deployment Contract hiện tại |
| AI Engine replicas | min 2, max 4 | Forecast dùng min 2 chạy 24/7 |
| AI algorithm | Statistical time-series, không Bedrock LLM | Không có Bedrock inference cost |
| Generator runtime | Chỉ chạy test window | Không chạy 24/7 nếu không cần |
| NAT Gateway | 1 workload NAT trong test window | ECS k6 chạy private subnet cần outbound để pull image, ghi logs và gọi API Gateway ingest |

## 3. Telemetry volume estimate

### 3.1 Data points

Với config mặc định:

```text
3 services × 7 metrics × 1 sample/minute
= 21 data points/minute
```

Monthly estimate:

```text
21 × 60 × 24 × 30
= 907,200 data points/month
```

Nếu đổi sampling interval:

| Emit interval | Data points/month | Multiplier vs 60s | Cost risk |
|---:|---:|---:|---|
| 60s | 907,200 | 1× | Low |
| 30s | 1,814,400 | 2× | Low-medium |
| 10s | 5,443,200 | 6× | Medium |
| 1s | 54,432,000 | 60× | High if kept running |

Decision:

```text
CDO08 dùng 60s làm default.
10s chỉ được dùng trong short test window có start/end rõ.
1s không dùng cho baseline/demo mặc định.
```

### 3.2 Prediction calls

```text
3 services × 12 calls/hour × 24 × 30
= 25,920 prediction calls/month
```

Mỗi prediction call query tối thiểu:

```text
120 minutes × 7 metrics
= 840 data points/service/call
```

Query samples processed estimate:

```text
25,920 × 840
= 21,772,800 samples/month
```

Con số này thấp cho capstone. Prediction cost chủ yếu nằm ở Lambda invocation, AI Engine runtime và audit/annotation side effects, không phải AMP query volume.

## 4. Monthly forecast by component

> **Note:** Số dưới đây là W12 forecast dựa trên services đang deploy. Cần attach thêm Cost Explorer/Budget screenshot để biến forecast thành measured evidence. Unit price có thể thay đổi theo region và account/free tier nên không xem đây là invoice.

| Component | Usage assumption | Forecast/month | Cost driver | Control |
|---|---:|---:|---|---|
| ECS Fargate AI Engine | 2 tasks, 0.5 vCPU/1GB, 24/7 | ~$35–$45 | Always-on compute | Right-size, scale down outside demo if allowed |
| Internal ALB | 1 ALB 24/7 | ~$16–$30 | Fixed hourly + LCU | Reuse one ALB, avoid extra ALB |
| ECS/Fargate synthetic generator | Test windows only | ~$0–$5 | Runtime hours | Stop after test, no 24/7 generator |
| API Gateway ingest | ~0.9M telemetry requests/month if one event/request | ~$0–$2 | Request count | Batch if needed, throttle |
| Lambda ingest/writer/prediction/fallback | Low million invocations/month | ~$0–$3 | Invocation + duration | Batch SQS writer, cap concurrency |
| SQS + telemetry DLQ | ~0.9M messages/month | ~$0–$1 | API requests | Retention sane, DLQ alarm |
| AMP | ~0.9M ingested samples + ~21.8M query samples | ~$0–$2 | Samples, active series, query | 60s sampling, low cardinality labels |
| DynamoDB audit | ~25,920 prediction records/month + fallback records | ~$0–$2 | Writes/storage | TTL, on-demand |
| S3 baseline storage | Small JSON/CSV baseline files | <$1 | GB-month + requests | Lifecycle if grows |
| CloudWatch Logs/Alarms | Lambda/ECS logs + alarms | ~$2–$10 | Log volume/retention | Structured logs, 14–30d app retention |
| AI Engine audit logs | Low volume, retention 1 year | ~$0–$3 initially | Long retention | Log only required audit fields |
| Managed Grafana | 1 workspace/user minimum | ~$9–$30 | Active users/license | Minimal users/service accounts |
| Secrets Manager/SSM/KMS | Few secrets/keys | ~$1–$5 | Secret/month + KMS requests | Avoid unnecessary secrets |
| SNS email alerts | Prediction/fallback anomaly notifications | <$1 at demo volume | Email notifications, topic requests | Keep subscribers minimal; confirm only required recipients |
| EventBridge Scheduler | ~25,920 invokes/month | ~$0 | Free tier likely covers | 5-min cadence |
| VPC interface endpoints | ECR API, ECR DKR, Logs across 2 AZs | ~$40–$45 + data | Endpoint hourly per AZ | Keep only endpoints required by private ECS path |
| NAT Gateway | 1 workload NAT when ECS k6 is used | ~$32.85 + data if left 24/7 | Hourly + data processing | Keep bounded to test window; review cleanup after demo |
| **Total forecast** | Current deployed shape, if kept 24/7 | **~$160–$190/month** | Mostly Fargate + ALB + NAT + endpoints + Grafana | Under $200 only with guardrails enforced |
| **Cost risk case** | Extra users/log volume/NAT data or extra always-on tasks | **Can exceed $200** | Fixed hourly services | Disable generator, scale down AI, remove NAT after demo if needed |

## 5. Cost per demo service / tenant

CDO08 đang demo 3 logical services trên shared platform. Fixed cost không chia đều tốt khi chỉ có 3 services, nhưng cần estimate để mentor thấy scaling behavior.

| Scenario | Monthly total | Effective cost/service/month | Note |
|---|---:|---:|---|
| 3 services demo, no NAT | ~$70–$135 | ~$23–$45 | Capstone baseline |
| 3 services demo, one NAT | ~$110–$200+ | ~$37–$67+ | Risky near cap |
| 10 services same platform | ~$80–$150 | ~$8–$15 | Fixed cost amortized |
| 50 services same platform | Not load-tested in W12 | Lower fixed cost/service, but AMP/cardinality/query grow | Design-level only; outside capstone implementation scope |

Production note: per-service cost giảm khi fixed cost như ALB, Grafana, base ECS service được dùng chung. Nhưng telemetry cardinality, query volume và dashboard usage sẽ tăng theo service count.

## 6. Cost vs alternatives

| Design option | Cost impact | Why CDO08 current choice |
|---|---|---|
| Lambda Writer → AMP | Low fixed cost | Chỉ chạy theo SQS backlog, phù hợp telemetry volume thấp |
| ECS/ADOT Writer → AMP | Higher fixed cost | Chỉ dùng nếu Lambda remote-write POC fail |
| Timestream | Not available for account | Bị AWS console chặn new customer; rejected |
| Self-managed Prometheus/InfluxDB | Higher ops/storage risk | Không phù hợp W11/W12 timeline |
| AI Engine on ECS Fargate | Moderate fixed cost | Contract yêu cầu FastAPI/container; predictable runtime |
| AI Engine on Lambda container | Potentially lower fixed cost | Chỉ cân nhắc nếu AI artifact light, startup/latency phù hợp |
| NAT Gateway for private k6 egress | High fixed cost | Chỉ dùng 1 NAT ở workload VPC cho ECS k6; AI VPC dùng VPC endpoints |
| Sampling 10s/1s | Increases AMP/API/Lambda volume | Không cần cho capacity trend; 60s khớp contract |

## 7. Cost guardrails

W11/W12 must-have:

- AWS Budget alert ở 80% `$160` và 100% `$200`.
- Resource tagging bắt buộc: `Project=TF4`, `Team=CDO08`, `Env`, `Owner`.
- Generator chỉ chạy trong test window; teardown/stop sau test.
- Default telemetry sampling 60s.
- Prediction interval 5 phút/service; không gọi AI theo từng data point.
- Lambda reserved/max concurrency cho ingest/prediction.
- SQS queue retention vừa đủ demo; DLQ có alarm.
- CloudWatch app log retention 14–30 ngày; AI audit log retention 1 năm theo contract.
- Không tạo thêm NAT Gateway; workload NAT chỉ phục vụ ECS k6 trong test window và cần review cleanup sau demo.
- Scale-to-zero/circuit breaker cho ECS AI Engine nếu cost vượt ngưỡng nguy hiểm theo Deployment Contract.

Circuit breaker action:

```text
Budget >= 100% cap
-> disable generator tasks/schedules
-> set AI Engine desired_count = 0 nếu cần dừng cost
-> giữ AMP/DynamoDB/audit để không mất evidence
-> ghi incident/cost note vào Jira
```

## 8. W12 actual measurement plan

### 8.1 What to capture

| Evidence | Source |
|---|---|
| Daily service cost | AWS Cost Explorer/Billing |
| ECS AI Engine task hours | ECS service metrics/task history |
| Lambda invocations/duration | CloudWatch metrics |
| API Gateway request count | CloudWatch/API Gateway metrics |
| SQS request/message count | CloudWatch SQS metrics |
| AMP samples ingested/query usage | AMP/CloudWatch usage metrics if available |
| DynamoDB writes/storage | CloudWatch/DynamoDB metrics |
| Grafana users/workspace cost | AWS billing/Grafana workspace |
| CloudWatch log ingestion/storage | CloudWatch usage/billing |

### 8.2 Actual spend table - W12 capture

| Service | Forecast | Actual W12 evidence | Delta / note |
|---|---:|---|---|
| ECS Fargate AI Engine | ~$35–$45 | Capture Cost Explorer/ECS task-hours screenshot | Fixed 2 tasks 24/7 while demo is active |
| ALB | ~$16–$30 | Capture Cost Explorer ELB line | Required for internal AI Engine path |
| Generator ECS task | ~$0–$5 | Capture ECS task run duration/k6 summary | Only during test windows |
| API Gateway | ~$0–$2 | Capture API Gateway request metrics | Ingest + AI API |
| Lambda | ~$0–$3 | Capture Lambda invocations/duration | Ingest/writer/prediction/adapter/fallback |
| SQS | ~$0–$1 | Capture SQS metrics | Queue/DLQ low volume |
| AMP | ~$0–$5 | Capture AMP/CloudWatch usage if available | Demo sample volume low |
| DynamoDB | ~$0–$2 | Capture DynamoDB consumed/write metrics | Audit records low volume |
| CloudWatch | ~$2–$10+ | Capture log ingestion/storage | Main variable cost if logs are verbose |
| Grafana | ~$9–$30 | Capture Grafana workspace/users | Depends active users |
| KMS/Secrets/SSM/S3/ECR | ~$1–$8 | Capture Cost Explorer grouped services | Includes baseline bucket, secrets, ECR images |
| VPC endpoints | ~$40–$45 + data | Capture VPC endpoint count | 3 endpoint services × 2 AZ |
| NAT Gateway | ~$32.85 + data if 24/7 | Capture NAT Gateway hours/data | Workload VPC only, review cleanup |
| **Total** | **~$160–$190** | Capture Cost Explorer total | Should stay below `$200` with guardrails |

### 8.3 Cost per useful prediction - W12 calculation

| Metric | Value |
|---|---:|
| Total prediction calls | Count from Prediction Lambda logs / CloudWatch invocations |
| Valid AI responses | Count `prediction_completed` and Serving Adapter success logs |
| Fallback responses | Count fallback logs/annotations |
| Correct early warnings | Count scenario annotations that match ground truth |
| False positives | Count annotations during `noisy_baseline` window |
| Monthly platform cost during test | Use Cost Explorer/Budget screenshot |
| Cost per correct early warning | `monthly platform cost / correct early warnings`; report only after final evidence count |

## 9. Resolved W12 cost decisions

| Topic | Decision |
|---|---|
| Region/account pricing | `us-east-1` on shared sandbox AWS account |
| AI Engine desired count | Keep min 2 for contract/demo availability while testing; scale down only after demo/evidence if cost guardrail triggers |
| NAT Gateway | AI VPC does not use NAT; workload VPC has 1 NAT so private ECS k6 can call public API Gateway and AWS public endpoints |
| Grafana | Managed Grafana is kept for W12 because annotation overlay is a core requirement |
| AMP usage metrics | Capture if exposed; otherwise use request/sample model + Grafana evidence |
| 50k events/sec peak | Design-level capacity only; W12 implementation validates demo scope, not full production peak |

Remaining evidence: Cost Explorer by service, AWS Budget screenshot, and NAT/Grafana cost explanation screenshots.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - component selection quyết định cost driver
- [`03_security_design.md`](03_security_design.md) - KMS, secrets, log retention và network choices ảnh hưởng cost
- [`04_deployment_design.md`](04_deployment_design.md) - deployment, rollout, teardown và cost guardrails
- [`07_test_eval_report.md`](07_test_eval_report.md) - W12 load test và actual measurement
