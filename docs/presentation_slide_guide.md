# CDO08 Foresight Lens - Presentation Slide Guide

Mục tiêu file này là hướng dẫn team tạo slide thuyết trình theo trình tự:

```text
PM -> Tech Lead -> Members
```

Ý tưởng hiện tại là tốt: PM mở đầu bằng bài toán và outcome, TL giải thích thiết kế tổng thể, sau đó từng member bảo vệ phần mình làm. Tuy nhiên cần chỉnh lại để buổi thuyết trình không bị rời rạc theo kiểu “mỗi người kể task của mình”. Câu chuyện nên đi theo một mạch:

```text
Problem -> Target outcome -> Architecture -> Implementation choices -> Evidence -> Gaps/next steps
```

## Nguyên tắc làm slide

- Mỗi slide chỉ nên có 1 thông điệp chính.
- Không đưa quá nhiều Terraform/code lên slide; chỉ show đoạn cần chứng minh quyết định.
- Mỗi member không chỉ nói “em tạo service X”, mà phải nói:
  - Vì sao cần service đó.
  - Vì sao chọn AWS service đó thay vì option khác.
  - Service đó nằm ở đâu trong flow.
  - Evidence nào chứng minh nó chạy được.
- Ưu tiên evidence thật:
  - Grafana dashboard.
  - AI prediction annotation.
  - ECS task/log.
  - API Gateway/Lambda/SQS flow.
  - Terraform plan/apply output.
  - Cost/security controls.
- Không né gap. Nếu còn hạn chế, nói rõ scope capstone và hướng harden sau.

## Cấu trúc đề xuất

Nên làm khoảng 18-24 slides. Nếu thời gian ngắn, cắt bớt phần member detail nhưng giữ flow tổng.

---

## Part 1 - PM: Problem, outcome, project overview

PM nên nói khoảng 4-6 slides.

### Slide 1 - Title

Nội dung:

- Project: `CDO08 Foresight Lens`
- One-liner:
  - “Predictive alerting platform for synthetic cloud service telemetry.”
- Team members và role.

Ý cần nói:

- Đây là hệ thống thu thập telemetry, lưu vào AMP, dùng AI Engine để phát hiện anomaly/drift, sau đó hiển thị prediction evidence lên Grafana.

### Slide 2 - Problem statement

Nội dung:

- Vấn đề chính:
  - Monitoring truyền thống thường reactive.
  - Khi alert threshold đã đỏ thì service có thể đã gần sự cố.
  - Team cần early warning để có thời gian xử lý.
- Pain points:
  - Telemetry phân tán.
  - Alert thiếu context.
  - Không có audit trail cho quyết định AI.

Ý cần nói:

- Mục tiêu không phải auto-remediation.
- Mục tiêu là “predict and recommend”, vẫn để con người quyết định.

### Slide 3 - How we analyzed the brief

Nội dung:

- Cách tách đề:
  - Input: telemetry events.
  - Processing: ingest, queue, writer, AMP.
  - Intelligence: AI Engine prediction.
  - Evidence: Grafana annotation, audit table, logs.
  - Security: IAM, KMS, Secrets Manager, private network path.
  - Cost: bounded sandbox cost.

Ý cần nói:

- Team không bắt đầu từ AWS service trước.
- Team bắt đầu từ outcome và contract, sau đó map sang architecture.

### Slide 4 - Target outcomes

Nội dung:

Outcome chính:

1. Generate telemetry for 3 logical services:
   - `payment-gw`
   - `ledger`
   - `fraud-detector`
2. Store/query telemetry in Amazon Managed Prometheus.
3. Run AI prediction on a 120-minute signal window.
4. Show prediction result on Grafana as annotation.
5. Keep audit evidence in DynamoDB.
6. Use Terraform for reproducible infrastructure.

Ý cần nói:

- “Done” không chỉ là tạo resource AWS.
- “Done” là phải có data flow end-to-end và user có thể nhìn thấy AI prediction trên dashboard.

### Slide 5 - End-to-end flow overview

Nội dung:

Vẽ flow ngắn:

```text
k6 ECS Generator
-> API Gateway Ingest
-> Lambda Ingest
-> SQS
-> Lambda Writer
-> AMP
-> Prediction Lambda
-> Serving Adapter
-> AI Engine ECS
-> Grafana Annotation + DynamoDB Audit
```

Ý cần nói:

- Đây là xương sống của hệ thống.
- Các phần member trình bày sau đều map vào flow này.

### Slide 6 - Demo evidence snapshot

Nội dung:

- Screenshot Grafana dashboard.
- Screenshot annotation popup.

Ý cần nói:

- Đây là evidence quan trọng nhất cho người xem:
  - Metrics đã vào dashboard.
  - AI đã tạo prediction.
  - Prediction có action/reasoning/audit id.

---

## Part 2 - Tech Lead: Architecture and technical design

TL nên nói khoảng 5-7 slides.

### Slide 7 - Architecture diagram

Nội dung:

- Dùng diagram từ `docs/02_infra_design.md`.
- Highlight 3 vùng:
  - Workload/k6 VPC.
  - AI Engine VPC.
  - Serverless/observability layer.

Ý cần nói:

- Hệ thống có 2 VPC:
  - Workload VPC cho ECS k6 generator.
  - AI Engine VPC cho ECS AI service sau internal ALB.
- Các service serverless như API Gateway, Lambda, SQS, AMP, Grafana nằm ngoài VPC hoặc managed service layer.

### Slide 8 - Why this architecture

Nội dung:

Mapping requirement -> design:

| Requirement | Design choice |
| --- | --- |
| Async telemetry ingestion | SQS buffer + DLQ |
| Queryable time-series data | Amazon Managed Prometheus |
| AI runs as long-lived HTTP service | ECS Fargate + ALB |
| Secure AI access | API Gateway AWS_IAM + VPC Link |
| User-facing evidence | Grafana dashboard + annotation |
| Audit trail | DynamoDB audit table |
| IaC collaboration | Terraform S3 backend + S3 lock |

Ý cần nói:

- Architecture được chọn theo requirement, không phải chọn service ngẫu nhiên.

### Slide 9 - Network design

Nội dung:

- Workload VPC:
  - ECS k6 in private subnet.
  - NAT Gateway để gọi public API Gateway ingest.
- AI VPC:
  - ECS AI in private subnet.
  - Internal ALB.
  - API Gateway VPC Link.
  - VPC endpoints for ECR/CloudWatch Logs/S3.

Ý cần nói:

- k6 cần NAT vì nó gọi API Gateway public endpoint.
- AI Engine không expose ALB public; access đi qua API Gateway + IAM auth.
- Đây là tradeoff giữa security và demo practicality.

### Slide 10 - Security design

Nội dung:

- IAM least privilege roles.
- API Gateway IAM auth.
- Secrets Manager for Grafana token.
- KMS key.
- S3 baseline bucket encryption.
- Internal ALB for AI Engine.
- Audit records in DynamoDB.

Ý cần nói:

- SigV4 xuất hiện ở 2 nơi chính:
  - k6 gọi ingest API Gateway IAM auth.
  - Serving Adapter gọi AI Engine API Gateway IAM auth.
- Token/secrets không hard-code trong code.

### Slide 11 - Data and prediction flow

Nội dung:

```text
Telemetry payload
-> validation
-> SQS
-> AMP remote write
-> query_range 120 minutes
-> AI /v1/predict
-> anomaly/recommendation
-> Grafana annotation
```

Ý cần nói:

- Prediction Lambda không tự predict.
- Nó query AMP, chuẩn bị signal window, gọi Serving Adapter.
- AI Engine mới là nơi detect drift/anomaly.

### Slide 12 - Observability evidence

Nội dung:

- Grafana dashboard panels:
  - CPU usage.
  - Memory usage.
  - API latency.
  - Queue depth.
  - DB connection pool.
  - Cache hit rate.
  - Active connections nếu đã thêm.
- Annotation popup.
- CloudWatch dashboard/logs.

Ý cần nói:

- Dashboard line thể hiện telemetry.
- Annotation thể hiện AI decision.
- Audit ID/correlation ID cho phép trace về logs/DynamoDB.

### Slide 13 - Cost and tradeoffs

Nội dung:

- Major cost drivers:
  - ECS AI Engine.
  - NAT Gateway.
  - VPC Interface Endpoints.
  - ALB.
  - Managed Grafana.
  - AMP.
- Current sandbox estimated monthly cost: khoảng `~$160-$190/month` nếu chạy 24/7.

Ý cần nói:

- Chi phí lớn nhất không phải Lambda/SQS.
- Chi phí chính đến từ fixed hourly resources.
- Có thể tiết kiệm bằng cách scale down/destroy sau demo.

---

## Part 3 - Members: What each person implemented

Mỗi member nên có 2-3 slides. Công thức chung:

```text
Slide A: Responsibility + where it fits in architecture
Slide B: Design choices + alternatives considered
Slide C: Evidence + known limitation
```

### Thuỷ - Synthetic Generator ECS Fargate

#### Slide - What was built

Nội dung:

- ECS Fargate k6 generator.
- ECR image for generator.
- Generates telemetry for:
  - `payment-gw`
  - `ledger`
  - `fraud-detector`
- Supports scenarios:
  - `noisy_baseline`
  - `gradual_drift`
  - `sudden_spike`
  - `slow_leak`
- Uses IAM SigV4 to call ingest API Gateway.
- For anomaly scenarios, the generator runs 120 minutes of baseline warm-up before anomaly starts, so Grafana shows one continuous service/scenario line.

Ý cần nói:

- Generator là nguồn dữ liệu synthetic để test toàn bộ pipeline.
- Không có app thật, nên k6 giả lập telemetry theo contract.

#### Slide - Why ECS Fargate + k6

Nội dung:

So sánh:

| Option | Pros | Cons |
| --- | --- | --- |
| Local script | Dễ chạy | Không match AWS diagram, khó share evidence |
| Lambda | Rẻ | Không phù hợp chạy 2 giờ liên tục |
| ECS Fargate + k6 | Chạy dài, đúng diagram, có logs/evidence | Cần NAT/image/task config |

Ý cần nói:

- Chọn ECS Fargate vì cần chạy real-time 2 giờ để tạo AMP window.
- Chọn k6 vì phù hợp synthetic load/telemetry generator hơn script thủ công.
- Phased scenario giúp demo rõ hơn: baseline trước, sau đó mới spike/drift/leak trong cùng một ECS task.

#### Slide - Evidence

Nội dung:

- ECS task logs showing `metric_emit_result status=202`.
- Grafana lines appear after generator runs.
- k6 summary: `http_req_failed 0.00%`.
- Final demo nên dùng `sudden_spike` hoặc `gradual_drift` với `ANOMALY_START_SECONDS=7200`.

Ý cần nói:

- Evidence chứng minh generator gửi data thành công vào ingest API.

### Phương - Telemetry Entry, SQS Buffer and DLQ

#### Slide - What was built

Nội dung:

- API Gateway ingest endpoint.
- Lambda ingest.
- SQS telemetry queue.
- DLQ.
- Payload validation.
- IAM auth on API Gateway.

Ý cần nói:

- Đây là cửa vào của hệ thống.
- Ingest Lambda validate payload trước khi đưa vào queue.

#### Slide - Why API Gateway + Lambda + SQS

Nội dung:

| Option | Pros | Cons |
| --- | --- | --- |
| Direct SQS from k6 | Ít service | Client phải biết SQS, contract API không rõ |
| ALB + app service | Linh hoạt | Overkill cho ingest |
| API Gateway + Lambda + SQS | Serverless, auth dễ, buffer tốt | Cần manage IAM/SQS DLQ |

Ý cần nói:

- API Gateway giúp expose contract rõ ràng.
- SQS giúp decouple ingest và writer.
- DLQ giúp giữ lại message lỗi.

#### Slide - Evidence

Nội dung:

- API returns `202`.
- SQS queue drains.
- DLQ stays empty.
- Ingest Lambda logs no validation failure.

### Nam - Telemetry Writer and AMP Store

#### Slide - What was built

Nội dung:

- Lambda writer consumes SQS.
- Converts telemetry payload into AMP remote write format.
- Writes metrics to Amazon Managed Prometheus.
- Exposes AMP query/remote_write outputs.

Ý cần nói:

- Writer là cầu nối từ event queue sang time-series database.

#### Slide - Why AMP

Nội dung:

| Option | Pros | Cons |
| --- | --- | --- |
| CloudWatch custom metrics | Native AWS | Query label/time-series kém linh hoạt hơn Prometheus |
| Timestream | Time-series managed | Integration Grafana/PromQL không tiện bằng AMP |
| AMP | PromQL, Grafana native, label-rich | Cần remote write/query SigV4 |

Ý cần nói:

- AMP phù hợp vì AI cần query window 120 phút và Grafana dùng PromQL.

#### Slide - Evidence

Nội dung:

- Grafana panels có metrics.
- AMP query returns data.
- Writer Lambda logs no error.
- SQS backlog về 0.

### Nhân - Prediction, Serving Adapter and Fail-open/Fallback

#### Slide - What was built

Nội dung:

- EventBridge Scheduler.
- Prediction Lambda.
- Serving Adapter Lambda.
- Fallback Lambda.
- AI Engine integration via API Gateway AWS_IAM.
- DynamoDB audit write.
- Grafana annotation publish.

Ý cần nói:

- Prediction Lambda orchestration:
  - query AMP.
  - build signal window.
  - call Serving Adapter.
  - write audit.
  - publish annotation.

#### Slide - Why this split

Nội dung:

| Component | Reason |
| --- | --- |
| Prediction Lambda | Scheduled orchestration and AMP query |
| Serving Adapter | Isolate AI API contract/retry/SigV4 call |
| Fallback Lambda | Fail-open behavior when AI unavailable |
| EventBridge Scheduler | Regular prediction every 5 minutes |

Ý cần nói:

- Không nhét tất cả vào một Lambda để dễ quản lý responsibility.
- Serving Adapter giúp thay đổi AI endpoint/contract mà ít ảnh hưởng scheduler.

#### Slide - Evidence

Nội dung:

- Prediction Lambda logs `prediction_started/completed`.
- AI Engine returns anomaly/recommendation.
- Grafana annotation popup.
- DynamoDB audit item with correlation ID.

Known limitation nên nói thẳng:

- Cần cooldown/dedupe để tránh annotation spam mỗi 5 phút.
- Annotation nên là point event, không phải range 120 phút.
- Nếu chạy nhiều scenario cùng service, Prediction cần filter `scenario`.

### Quân - Grafana Overlay, Audit Store and Observability

#### Slide - What was built

Nội dung:

- Amazon Managed Grafana workspace.
- AMP datasource provisioning.
- Foresight Lens dashboard.
- Annotation overlay.
- DynamoDB audit table.
- CloudWatch dashboard/alarms/log metric filters.

Ý cần nói:

- Quân phụ trách phần user-facing evidence và audit/observability.

#### Slide - Why Grafana + DynamoDB

Nội dung:

| Option | Pros | Cons |
| --- | --- | --- |
| CloudWatch dashboard only | AWS native | Annotation UX yếu hơn Grafana |
| Grafana | Prometheus native, annotation tốt | Cần workspace/token/datasource setup |
| DynamoDB audit | Query by tenant/service/correlation, TTL | Không phải time-series store |

Ý cần nói:

- Grafana là nơi user nhìn thấy metric + AI decision.
- DynamoDB là nơi lưu audit evidence có TTL.

#### Slide - Evidence

Nội dung:

- Dashboard URL.
- Annotation popup screenshot.
- DynamoDB audit item.
- CloudWatch alarm/dashboard screenshot.

### Quyết - Secrets, KMS, IAM Baseline and AI Runtime Security

#### Slide - What was built

Nội dung:

- IAM roles:
  - generator.
  - ingest.
  - writer.
  - prediction.
  - scheduler.
  - AI engine.
- KMS key.
- Secrets Manager Grafana token.
- S3 baseline bucket.
- AI Engine ECR/runtime security baseline.

Ý cần nói:

- Đây là security foundation để các module khác reuse role thay vì tự tạo role trùng.

#### Slide - Why these controls

Nội dung:

| Control | Purpose |
| --- | --- |
| IAM least privilege | Giảm blast radius |
| KMS | Encryption key ownership |
| Secrets Manager | Không hard-code token |
| S3 baseline bucket | Store AI baseline artifacts |
| Private ALB + API Gateway IAM | Secure AI access path |

Ý cần nói:

- Security không phải phần riêng lẻ; nó xuyên suốt generator, ingest, writer, prediction, AI Engine.

#### Slide - Evidence

Nội dung:

- IAM role outputs.
- Secret exists but token not exposed.
- KMS key output.
- S3 baseline objects.
- AI Engine private path / SigV4 API Gateway.

---

## Part 4 - Demo flow

Nên có 3-4 slides hoặc live demo ngắn.

### Slide - Demo setup

Nội dung:

- Scenario selected:
  - `sudden_spike` hoặc `gradual_drift`.
- Services:
  - `payment-gw`
  - `ledger`
  - `fraud-detector`
- Window:
  - 120 minutes.

Ý cần nói:

- Để AI prediction sạch, chỉ chạy 1 scenario trong một window 2 giờ.
- Không mix 4 scenarios cùng một service nếu Prediction Lambda chưa filter scenario.

### Slide - Metrics evidence

Nội dung:

- Grafana panel showing 3 lines:

```text
payment-gw / sudden_spike
ledger / sudden_spike
fraud-detector / sudden_spike
```

Ý cần nói:

- Đây là telemetry evidence.
- Chưa phải AI evidence.

### Slide - AI evidence

Nội dung:

- Grafana annotation popup.
- Call out:
  - service.
  - action.
  - confidence.
  - reasoning.
  - audit id.
  - correlation id.

Ý cần nói:

- Đây mới là evidence AI đã chạy và đưa ra recommendation.

### Slide - Audit trace

Nội dung:

- Show DynamoDB audit item hoặc CloudWatch log trace.

Ý cần nói:

- Annotation là user-facing.
- Audit table/log là traceability.

---

## Part 5 - Gaps and next steps

Nên có 1-2 slides cuối.

### Slide - Known gaps

Nội dung:

- Annotation currently needs hardening:
  - Point event instead of 120-minute region.
  - Cooldown/dedupe to avoid repeated 5-minute alerts.
  - Filter annotation by service/scenario on dashboard.
- Prediction query should support `scenario` filter.
- Dashboard should show all 7 contract metrics, including `active_connections`.
- AI recommendations reference logical services; real ECS service mapping is future work.

Ý cần nói:

- Các gap này không làm mất end-to-end flow.
- Nhưng cần harden nếu đi production.

### Slide - Next steps

Nội dung:

1. Add annotation cooldown/dedupe.
2. Add scenario-aware prediction query.
3. Add service-specific dashboards.
4. Harden AI Engine private path further if needed.
5. Add CI checks for Terraform and Lambda packaging.
6. Improve cost controls: scheduled scale down, destroy NAT/Grafana after demo.

---

## Góp ý chỉnh lại ý tưởng ban đầu

Ý tưởng PM -> TL -> member là đúng. Chỉ cần tránh 3 lỗi:

### 1. PM không nên nói quá nhiều chi tiết AWS

PM nên giữ ở tầng:

```text
problem -> outcome -> success criteria -> overview
```

Không nên đi sâu vào NAT, endpoint, IAM role.

### 2. TL không chỉ đọc diagram

TL nên giải thích decision:

```text
Vì sao 2 VPC?
Vì sao NAT cho k6?
Vì sao internal ALB cho AI?
Vì sao API Gateway IAM/SigV4?
Vì sao AMP + Grafana?
```

### 3. Member không chỉ nói “em tạo resource”

Mỗi member phải bảo vệ được lựa chọn service:

```text
Requirement là gì?
Option A/B/C là gì?
Vì sao chọn option hiện tại?
Evidence chạy được là gì?
Known limitation là gì?
```

Nếu làm được vậy, buổi thuyết trình sẽ giống một engineering review, không phải đọc task list.

## Slide checklist

Trước khi finalize deck, check:

- [ ] Có slide problem statement.
- [ ] Có slide target outcome.
- [ ] Có architecture diagram.
- [ ] Có end-to-end data flow.
- [ ] Có service comparison/tradeoff cho từng phần chính.
- [ ] Có Grafana dashboard screenshot.
- [ ] Có annotation popup screenshot.
- [ ] Có audit/correlation evidence.
- [ ] Có cost summary.
- [ ] Có security summary.
- [ ] Có known gaps/next steps.
- [ ] Mỗi member có evidence thật.
- [ ] Không expose secret/token trong screenshot.
