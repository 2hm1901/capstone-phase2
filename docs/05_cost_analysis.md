# Phân tích chi phí - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Skeleton (W11) → Measured actual (W12)

**Last updated:** 2026-06-25

## 1. Mục tiêu cost

CDO08 cần chứng minh platform Foresight Lens có thể chạy dưới rough cap **$200/tháng** cho scope capstone. Chi phí cần được giải thích theo driver chính, không chỉ đưa tổng số. Với kiến trúc hiện tại, cost driver quan trọng nhất là:

1. AI Engine Runtime ECS Fargate chạy 24/7.
2. Internal ALB cho AI Engine.
3. Amazon Managed Grafana user/workspace.
4. CloudWatch logs/alarms.
5. NAT Gateway nếu bị tạo nhầm hoặc tạo quá sớm.
6. Telemetry ingestion volume nếu sampling interval quá dày.

Telemetry data point là yếu tố cần kiểm soát, nhưng với scope demo `3 services × 7 metrics × 60s` thì AMP ingest/query cost dự kiến thấp. Rủi ro chỉ tăng mạnh nếu sampling giảm xuống 10s/1s hoặc volume tiến gần mức contract peak.

## 2. Assumptions for W11 forecast

| Assumption | Value | Note |
|---|---:|---|
| AWS region | `us-west-2` | Region đã cấu hình cho shared sandbox account |
| Services demo | 3 | `payment-api`, `queue-worker`, `gateway-api` |
| Metrics/service | 7 | Theo Telemetry Contract |
| Telemetry emit interval | 60s | 1 data point/phút/metric/service |
| Prediction interval | 5 phút/service | EventBridge Scheduler |
| Prediction lookback | ≥120 phút | AI API Contract |
| AI Engine compute | ECS Fargate 0.5 vCPU, 1 GB | Theo Deployment Contract hiện tại |
| AI Engine replicas | min 2, max 4 | Forecast dùng min 2 chạy 24/7 |
| AI algorithm | Statistical time-series, không Bedrock LLM | Không có Bedrock inference cost |
| Generator runtime | Chỉ chạy test window | Không chạy 24/7 nếu không cần |
| NAT Gateway | Avoid by default | Chỉ dùng nếu private connectivity bắt buộc |

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

> **Note:** Số dưới đây là W11 forecast để review architecture. W12 phải thay bằng actual từ AWS Cost Explorer/Billing + CloudWatch usage. Unit price thay đổi theo region và free tier nên không xem đây là invoice.

| Component | Usage assumption | Forecast/month | Cost driver | Control |
|---|---:|---:|---|---|
| ECS Fargate AI Engine | 2 tasks, 0.5 vCPU/1GB, 24/7 | ~$35–$45 | Always-on compute | Right-size, scale down outside demo if allowed |
| Internal ALB | 1 ALB 24/7 | ~$20–$30 | Fixed hourly + LCU | Reuse one ALB, avoid extra ALB |
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
| EventBridge Scheduler | ~25,920 invokes/month | ~$0 | Free tier likely covers | 5-min cadence |
| NAT Gateway | Avoided by default | $0 if avoided; can add $30–$70+ | Hourly + data processing | Do not create unless required |
| **Total forecast** | Without NAT | **~$70–$135/month** | Mostly Fargate + ALB + Grafana + logs | Under $200 if guardrails enforced |
| **Worst likely if NAT added** | One NAT 24/7 | **~$110–$200+** | NAT fixed cost | Review before apply |

## 5. Cost per demo service / tenant

CDO08 đang demo 3 logical services trên shared platform. Fixed cost không chia đều tốt khi chỉ có 3 services, nhưng cần estimate để mentor thấy scaling behavior.

| Scenario | Monthly total | Effective cost/service/month | Note |
|---|---:|---:|---|
| 3 services demo, no NAT | ~$70–$135 | ~$23–$45 | Capstone baseline |
| 3 services demo, one NAT | ~$110–$200+ | ~$37–$67+ | Risky near cap |
| 10 services same platform | ~$80–$150 | ~$8–$15 | Fixed cost amortized |
| 50 services same platform | TBD W12 | Lower fixed cost/service, but AMP/cardinality/query grow | Need load model |

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
| NAT Gateway for private egress | High fixed cost | Tránh nếu VPC endpoints hoặc public AWS endpoint đủ an toàn |
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
- Không tạo NAT Gateway nếu chưa có quyết định Tech Lead + cost note.
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

### 8.2 Actual spend table - fill in W12

| Service | Forecast | Actual W12 | Delta | Reason |
|---|---:|---:|---:|---|
| ECS Fargate AI Engine | ~$35–$45 | TBD | TBD | TBD |
| ALB | ~$20–$30 | TBD | TBD | TBD |
| Generator ECS task | ~$0–$5 | TBD | TBD | TBD |
| API Gateway | ~$0–$2 | TBD | TBD | TBD |
| Lambda | ~$0–$3 | TBD | TBD | TBD |
| SQS | ~$0–$1 | TBD | TBD | TBD |
| AMP | ~$0–$2 | TBD | TBD | TBD |
| DynamoDB | ~$0–$2 | TBD | TBD | TBD |
| CloudWatch | ~$2–$10 | TBD | TBD | TBD |
| Grafana | ~$9–$30 | TBD | TBD | TBD |
| KMS/Secrets/SSM/S3 | ~$1–$6 | TBD | TBD | TBD |
| NAT Gateway | $0 target | TBD | TBD | Must explain if >0 |
| **Total** | **~$70–$135** | **TBD** | **TBD** | **TBD** |

### 8.3 Cost per useful prediction - fill in W12

| Metric | Value |
|---|---:|
| Total prediction calls | TBD |
| Valid AI responses | TBD |
| Fallback responses | TBD |
| Correct early warnings | TBD |
| False positives | TBD |
| Monthly platform cost during test | TBD |
| Cost per correct early warning | TBD |

## 9. Open questions

- [x] Region/account pricing final là gì? — `us-west-2` trên shared sandbox AWS account.
- [ ] AI Engine có bắt buộc min 2 tasks 24/7 trong demo không, hay được scale down ngoài test window?
- [ ] Có cần NAT Gateway để AI Engine đọc S3/CloudWatch/OTel không, hay VPC endpoint/public AWS endpoint đủ?
- [ ] Managed Grafana pricing/user count thực tế trong account mentor là bao nhiêu?
- [ ] AMP usage metrics trong account có expose đủ để đo samples ingested/query không?
- [ ] W12 có cần mô phỏng 50,000 events/sec peak không, hay chỉ design-level volume SLA?

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - component selection quyết định cost driver
- [`03_security_design.md`](03_security_design.md) - KMS, secrets, log retention và network choices ảnh hưởng cost
- [`04_deployment_design.md`](04_deployment_design.md) - deployment, rollout, teardown và cost guardrails
- [`07_test_eval_report.md`](07_test_eval_report.md) - W12 load test và actual measurement
