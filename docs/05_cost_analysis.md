# Phân tích chi phí - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Final draft for W12 Evidence Pack #2

**Last updated:** 2026-07-01

## 1. Mục tiêu cost

CDO08 cần chứng minh platform Foresight Lens có thể chạy dưới rough cap **$200/tháng** cho scope capstone. Chi phí cần được giải thích theo driver chính, không chỉ đưa tổng số. Với kiến trúc hiện tại, cost driver quan trọng nhất là:

1. Fixed monthly services: VPC endpoints, AI Engine ECS Fargate, ALB, Managed Grafana, KMS/Secrets/S3/ECR.
2. Telemetry volume: số data point ingest/query qua AMP, API Gateway, Lambda, SQS và Writer.
3. Log volume: CloudWatch log ingestion/retention từ generator, Lambda và AI Engine.
4. Test runtime: ECS k6 generator chỉ nên chạy theo test window.

CDO08 không tính cost theo concurrent users như một web application truyền thống. Hạ tầng này chủ yếu tốn tiền theo **telemetry volume**: càng nhiều service, metric, sample interval ngắn và prediction query nhiều thì AMP/API/Lambda/SQS/CloudWatch càng tăng. Fixed monthly cost vẫn tồn tại vì một số managed resources tính tiền theo giờ, nhưng phần cần kiểm soát khi scale là telemetry.

## 2. Assumptions for W12 forecast

| Assumption | Value | Note |
|---|---:|---|
| AWS region | `us-east-1` | Region đã cấu hình cho shared sandbox account |
| Services demo | 3 | `payment-gw`, `ledger`, `fraud-detector` |
| Metrics/service | 7 | Theo Telemetry Contract |
| Telemetry emit interval | 60s | 1 data point/phút/metric/service |
| Low telemetry case | ~20M data points/month | Demo/sandbox mở rộng nhẹ |
| Mid telemetry case | ~200M data points/month | Nhiều test window hoặc sampling dày hơn |
| High telemetry case | ~1B data points/month | Stress/capacity-style volume; ngoài scope vận hành hằng ngày W12 |
| Prediction interval | 5 phút/service | EventBridge Scheduler |
| Prediction lookback | ≥120 phút | AI API Contract |
| AI Engine compute | ECS Fargate 0.5 vCPU, 1 GB | Theo Deployment Contract hiện tại |
| AI Engine replicas | min 2, max 4 | Forecast dùng min 2 chạy 24/7 |
| AI algorithm | Statistical time-series, không Bedrock LLM | Không có Bedrock inference cost |
| Generator runtime | Chỉ chạy test window | Không chạy 24/7 nếu không cần |

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

Volume planning cho cost forecast:

| Volume tier | Data points/month | Khi nào dùng để ước tính |
|---|---:|---|
| Low | ~20M | Demo/sandbox có thêm test nhưng vẫn dưới cap |
| Mid | ~200M | Nhiều service/scenario hơn hoặc sampling dày hơn trong test window |
| High | ~1B | Capacity/stress estimate; không phải mức vận hành mặc định W12 |

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

## 4. Monthly forecast by telemetry volume

> **Note:** Số dưới đây là W12 forecast dựa trên services đang deploy. Cần attach thêm Cost Explorer/Budget screenshot để biến forecast thành measured evidence. Unit price có thể thay đổi theo region và account/free tier nên không xem đây là invoice.

| Service | Tăng tiền khi nào? | Low ~20M | Mid ~200M | High ~1B | Ghi chú |
|---|---|---:|---:|---:|---|
| **Trả cố định hằng tháng** |  |  |  |  |  |
| VPC endpoints | Không tăng theo telemetry; bật endpoint là tính tiền | ~$42 | ~$42 | ~$43 | 3 endpoint services × 2 AZ |
| Fargate AI Engine | Tăng khi thêm task/scale service | ~$40 | ~$40 | ~$60 | +1 task khi volume/service lớn |
| ALB | Gần như cố định ở mức demo | ~$23 | ~$23 | ~$25 | Đường dẫn nội bộ tới AI |
| Grafana | Tăng theo số người xem/editor | ~$19 | ~$19 | ~$19 | Tính theo user/workspace |
| KMS/Secrets/S3/ECR | Gần như cố định ở mức demo | ~$5 | ~$6 | ~$8 | Key/secret/baseline/image storage |
| **Trả theo mức dùng** |  |  |  |  |  |
| AMP | Tăng theo data point ingest, active series và query samples | ~$2 | ~$18 | ~$95 | Tốn nhất khi scale telemetry |
| CloudWatch | Tăng theo log ghi ra và retention | ~$3 | ~$15 | ~$50 | Cắt bằng log ngắn, structured log, giảm debug |
| Generator ECS | Tăng theo thời gian chạy và task size | ~$3 | ~$8 | ~$20 | Chỉ chạy lúc test |
| Lambda | Tăng theo số event/query/prediction package xử lý | ~$0.5 | ~$3 | ~$12 | ingest/writer/prediction/adapter/fallback |
| API Gateway | Tăng theo lượt gọi ingest + AI API | ~$0.2 | ~$2 | ~$10 | Ingest API và AI SigV4 API |
| DynamoDB | Tăng theo số prediction/fallback audit writes/query | ~$0.5 | ~$2 | ~$6 | Theo số lần predict |
| SQS | Tăng theo số message qua queue/DLQ | ~$0.2 | ~$1 | ~$4 | Queue/DLQ |
| SNS email alerts | Tăng theo số alert gửi ra | <$1 | <$1 | ~$1 | Demo volume thấp; tránh spam bằng cooldown |
| EventBridge Scheduler | Tăng theo số schedule/invocation | ~$0 | ~$0 | ~$1 | 5-min cadence/service |
| **Total forecast** | Theo telemetry volume, không theo concurrent user | **~$140** | **~$180** | **~$350** | Low/Mid dưới hoặc gần cap; High vượt cap |

## 5. Cost scaling interpretation

CDO08 dùng bảng trên để giải thích cost theo telemetry:

- **Fixed monthly cost** gần như không đổi khi tăng nhẹ telemetry: VPC endpoints, AI Engine base tasks, ALB, Grafana và KMS/Secrets/S3/ECR.
- **Usage-based cost** tăng theo data point và log volume: AMP, CloudWatch, Generator ECS, Lambda, API Gateway, DynamoDB và SQS.
- **Low ~20M** là mức hợp lý cho sandbox/demo có thêm test window.
- **Mid ~200M** vẫn có thể nằm trong mục tiêu khoảng `$200/tháng` nếu log được kiểm soát.
- **High ~1B** là stress/capacity estimate, không phải mức vận hành mặc định; ở mức này AMP và CloudWatch là hai cost driver chính.

Kết luận: CDO08 không scale cost theo số concurrent users. Hệ thống scale cost chủ yếu theo công thức:

```text
services × metrics/service × samples/minute × test/runtime duration
+ prediction query volume
+ log volume
```

## 6. Cost vs alternatives

| Design option | Cost impact | Why CDO08 current choice |
|---|---|---|
| Lambda Writer → AMP | Low fixed cost | Chỉ chạy theo SQS backlog, phù hợp telemetry volume thấp |
| ECS/ADOT Writer → AMP | Higher fixed cost | Chỉ dùng nếu Lambda remote-write POC fail |
| Timestream | Not available for account | Bị AWS console chặn new customer; rejected |
| Self-managed Prometheus/InfluxDB | Higher ops/storage risk | Không phù hợp W11/W12 timeline |
| AI Engine on ECS Fargate | Moderate fixed cost | Contract yêu cầu FastAPI/container; predictable runtime |
| AI Engine on Lambda container | Potentially lower fixed cost | Chỉ cân nhắc nếu AI artifact light, startup/latency phù hợp |
| Sampling 10s/1s | Increases AMP/API/Lambda volume | Không cần cho capacity trend; 60s khớp contract |

## 7. Cost guardrails

W11/W12 must-have:

- AWS Budget alert ở 80% `$160` và 100% `$200`.
- Resource tagging bắt buộc theo Terraform: `Project=CDO08`, `Environment=sandbox`, `ManagedBy=Terraform`.
- Generator chỉ chạy trong test window; teardown/stop sau test.
- Default telemetry sampling 60s.
- Prediction interval 5 phút/service; không gọi AI theo từng data point.
- Lambda reserved/max concurrency cho ingest/prediction.
- SQS queue retention vừa đủ demo; DLQ có alarm.
- CloudWatch app log retention 14–30 ngày; AI audit log retention 1 năm theo contract.
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
| Telemetry data point estimate | Generator config, API Gateway/Lambda request count, AMP usage if exposed |
| ECS AI Engine task hours | ECS service metrics/task history |
| Lambda invocations/duration | CloudWatch metrics |
| API Gateway request count | CloudWatch/API Gateway metrics |
| SQS request/message count | CloudWatch SQS metrics |
| AMP samples ingested/query usage | AMP/CloudWatch usage metrics if available |
| DynamoDB writes/storage | CloudWatch/DynamoDB metrics |
| Grafana users/workspace cost | AWS billing/Grafana workspace |
| CloudWatch log ingestion/storage | CloudWatch usage/billing |

### 8.2 Actual spend table - W12 capture

| Service | Low ~20M | Mid ~200M | High ~1B | Actual W12 evidence | Delta / note |
|---|---:|---:|---:|---|---|
| VPC endpoints | ~$42 | ~$42 | ~$43 | Capture VPC endpoint count | Fixed monthly, 3 endpoint services × 2 AZ |
| Fargate AI Engine | ~$40 | ~$40 | ~$60 | Capture ECS task-hours screenshot | Fixed base; grows only if adding tasks |
| ALB | ~$23 | ~$23 | ~$25 | Capture Cost Explorer ELB line | Internal AI path |
| Grafana | ~$19 | ~$19 | ~$19 | Capture Grafana workspace/users | Depends users, not telemetry |
| KMS/Secrets/S3/ECR | ~$5 | ~$6 | ~$8 | Capture Cost Explorer grouped services | Key/secret/baseline/image |
| AMP | ~$2 | ~$18 | ~$95 | Capture AMP/CloudWatch usage if available | Main telemetry-volume cost driver |
| CloudWatch | ~$3 | ~$15 | ~$50 | Capture log ingestion/storage | Main variable cost if logs are verbose |
| Generator ECS | ~$3 | ~$8 | ~$20 | Capture ECS task run duration/k6 summary | Only during test windows |
| Lambda | ~$0.5 | ~$3 | ~$12 | Capture Lambda invocations/duration | ingest/writer/prediction/adapter/fallback |
| API Gateway | ~$0.2 | ~$2 | ~$10 | Capture API Gateway request metrics | ingest + AI API |
| DynamoDB | ~$0.5 | ~$2 | ~$6 | Capture DynamoDB consumed/write metrics | Audit writes/query |
| SQS | ~$0.2 | ~$1 | ~$4 | Capture SQS metrics | Queue/DLQ |
| SNS email alerts | <$1 | <$1 | ~$1 | Capture SNS/email alert count | Demo volume low |
| EventBridge Scheduler | ~$0 | ~$0 | ~$1 | Capture scheduler invocation count | 5-min cadence/service |
| **Total** | **~$140** | **~$180** | **~$350** | Capture Cost Explorer total | Low/Mid acceptable; High exceeds cap |

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
| Grafana | Managed Grafana is kept for W12 because annotation overlay is a core requirement |
| AMP usage metrics | Capture if exposed; otherwise use request/sample model + Grafana evidence |
| Cost model | Cost is explained by telemetry volume tiers: Low ~20M, Mid ~200M, High ~1B data points/month |
| 50k events/sec peak | Design-level capacity only; W12 implementation validates demo scope, not full production peak |

Remaining evidence: Cost Explorer by service, AWS Budget screenshot, and Grafana cost explanation screenshots.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - component selection quyết định cost driver
- [`03_security_design.md`](03_security_design.md) - KMS, secrets, log retention và network choices ảnh hưởng cost
- [`04_deployment_design.md`](04_deployment_design.md) - deployment, rollout, teardown và cost guardrails
- [`07_test_eval_report.md`](07_test_eval_report.md) - W12 load test và actual measurement
