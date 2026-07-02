# Architecture Decision Records - CDO08 · Task Force 4

**Document owner:** CDO08

**Status:** Final draft for W12 Evidence Pack #2

**Last updated:** 2026-07-01

ADR là log các quyết định kiến trúc có trade-off thật. File này append-only: nếu quyết định cũ không còn đúng, đánh dấu `Superseded by ADR-xxx`, không xóa.

## ADR-001 - Chọn trọng tâm operational trust thay vì khác biệt bằng service lạ

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** TF4 có nhiều nhóm CDO cùng giải một bài Foresight Lens, nên việc “dùng service khác” không đủ để thắng. Mentor cũng đã nhấn mạnh các nhóm có thể làm giống nhau nhưng phải chứng minh được cái nào tốt hơn.
- **Decision:** CDO08 chọn trọng tâm **operational trust with measurable evidence**: telemetry không mất âm thầm, prediction truy vết được, fail-open hoạt động khi AI lỗi, và mọi claim đều có artifact đo được.
- **Consequence:**
  - ✅ Dễ defend trước mentor vì mỗi claim có test/evidence.
  - ✅ Phù hợp pain point Client: phát hiện capacity exhaustion trước support ticket.
  - ✅ Giữ scope tập trung cho W11/W12.
  - ⚠️ Không ưu tiên feature ngoài scope như auto-remediation, UI mới hoặc active-active multi-region.
  - ⚠️ Cần nhiều smoke test/evidence hơn so với demo “happy path”.
- **Alternatives considered:**
  - Technology differentiation first: dùng nhiều service khác biệt để nổi bật. Rejected vì dễ tăng complexity nhưng không chứng minh reliability tốt hơn.
  - Minimal demo path: chỉ ingest → AI → dashboard. Rejected vì yếu khi bị hỏi failure, audit, replay và fallback.

---

## ADR-002 - Dùng ECS Fargate task cho synthetic workload

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** TF4 yêu cầu test ba service với gradual drift, sudden spike, slow leak và noisy baseline trong test window ≥2 giờ. Không được mirror production traffic.
- **Decision:** Dùng ECS Fargate task chạy synthetic generator/k6 để tạo workload và telemetry có thể tái lập.
- **Consequence:**
  - ✅ Chạy được test dài ≥2 giờ, không phụ thuộc laptop cá nhân.
  - ✅ Có image/version/load profile làm evidence.
  - ✅ Dễ ghi start time, breach time và ground truth để đo lead time.
  - ⚠️ Có chi phí runtime nếu quên stop task.
  - ⚠️ Cần build/push container và quản lý task role.
- **Alternatives considered:**
  - Lambda generator: rejected vì runtime limit không phù hợp scenario ≥2 giờ.
  - EC2 generator: rejected vì phải patch/terminate và dễ phát sinh cost nếu quên tắt.
  - Manual script từ laptop: rejected vì không tái lập tốt và evidence yếu.

---

## ADR-003 - Dùng API Gateway + Lambda Ingest làm telemetry entry

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** Telemetry phải có `tenant_id`, `service_id`, `metric_type`, `ts`, `value` và labels hợp lệ. Event sai schema hoặc tenant mismatch không được ghi vào storage.
- **Decision:** Dùng API Gateway làm HTTPS entry và Lambda Ingest để validate schema, whitelist metric, kiểm tra tenant/header, reject PII và gắn correlation ID trước khi gửi SQS.
- **Consequence:**
  - ✅ Có boundary rõ trước storage.
  - ✅ Có throttling, request limit và log validation.
  - ✅ Dễ tạo negative test cho schema/tenant mismatch.
  - ⚠️ Thêm một hop và Lambda cold start.
  - ⚠️ Nếu traffic lớn, cần batch hoặc tối ưu API request volume.
- **Alternatives considered:**
  - ALB + ECS collector: hợp lý cho long-running collector/custom protocol, nhưng fixed cost và vận hành cao hơn.
  - Generator ghi trực tiếp AMP/TSDB: rejected vì không có central validation/retry boundary.

---

## ADR-004 - Dùng SQS Standard + DLQ làm buffer telemetry

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** Writer hoặc telemetry store có thể chậm/lỗi tạm thời. Metric không được mất âm thầm vì mất telemetry sẽ làm sai baseline, prediction và evidence.
- **Decision:** Dùng Amazon SQS Standard queue giữa Ingest Lambda và Writer Lambda, kèm telemetry DLQ cho poison/retry-exhausted event.
- **Consequence:**
  - ✅ Decouple producer và writer.
  - ✅ Có retry, replay và DLQ evidence.
  - ✅ SQS queue age/backlog là signal vận hành rõ.
  - ⚠️ At-least-once delivery nên writer phải idempotent hoặc tolerate duplicate.
  - ⚠️ Không đảm bảo strict ordering; không phù hợp nếu AI yêu cầu event ordering tuyệt đối.
- **Alternatives considered:**
  - Kinesis Data Streams: phù hợp sustained throughput/ordering cao, nhưng shard/capacity/cost phức tạp hơn scope hiện tại.
  - Không dùng buffer: rejected vì storage/writer lỗi có thể làm producer mất hoặc block event.

---

## ADR-005 - Chọn AMP làm primary telemetry store thay Timestream

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** TF4 yêu cầu time-series store retention ≥90 ngày và query hiệu quả theo tenant/service/metric. Ban đầu CDO08 cân nhắc Amazon Timestream for LiveAnalytics nhưng account capstone bị chặn new customer access.
- **Decision:** Dùng Amazon Managed Service for Prometheus (AMP) làm primary telemetry store. `metric_type` trở thành Prometheus metric name; `tenant_id`, `service_id`, `region` là labels ổn định.
- **Consequence:**
  - ✅ Managed Prometheus, PromQL, integration tốt với Grafana.
  - ✅ Retention mặc định đủ vượt yêu cầu ≥90 ngày.
  - ✅ Phù hợp infra metrics và sliding window query cho AI.
  - ⚠️ Cần remote-write adapter từ Writer Lambda.
  - ⚠️ Phải kiểm soát label cardinality; không đưa `correlation_id` vào label.
  - ⚠️ Cần POC remote-write encoding/compression/SigV4.
- **Alternatives considered:**
  - Timestream LiveAnalytics: rejected vì không khả dụng cho account mới.
  - Self-managed Prometheus/InfluxDB: rejected vì backup/patching/persistent storage/HA quá nặng cho W11-W12.
  - S3 + Athena: rejected làm primary store vì không đáp ứng query time-series realtime; chỉ hợp lý cho archive ngoài scope.

---

## ADR-006 - Dùng Lambda Writer remote-write AMP, ADOT là fallback option

- **Status:** Accepted with POC gate
- **Date:** 2026-06-25
- **Context:** Telemetry đi qua SQS cần được chuyển thành Prometheus remote-write payload để ghi AMP. CDO08 cần giữ validation/buffer hiện có và giảm fixed cost.
- **Decision:** Dùng Lambda Writer đọc SQS theo batch, chuyển JSON telemetry thành Prometheus time series và remote-write vào AMP. ADOT/ECS collector chỉ là fallback nếu POC Lambda remote-write fail.
- **Consequence:**
  - ✅ Event-driven, trả tiền theo usage.
  - ✅ Scale theo SQS backlog.
  - ✅ Giữ pipeline validation/retry/DLQ rõ.
  - ⚠️ Cần implement remote-write encoding, Snappy compression, SigV4 và partial batch handling.
  - ⚠️ Nếu implementation khó kịp, phải chuyển sang ADOT/ECS writer.
- **Alternatives considered:**
  - ECS/Fargate consumer với ADOT Collector/Prometheus Agent: có collector chuẩn nhưng fixed cost và vận hành cao hơn.
  - Kinesis Firehose: không phù hợp trực tiếp với AMP remote-write và transform/correlation cần thiết.

---

## ADR-007 - Dùng EventBridge Scheduler cho prediction cadence, không dùng Scheduler DLQ

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** AI không nên bị gọi theo từng telemetry data point. Prediction cần chạy định kỳ để query window ≥120 phút và đo lead time ≥15 phút. Ban đầu có cân nhắc DLQ riêng cho Scheduler.
- **Decision:** Dùng EventBridge Scheduler trigger Prediction Lambda mỗi 5 phút/service, lệch 1-2 phút giữa services. Không dùng DLQ riêng cho Scheduler; dùng CloudWatch alarm cho invoke failure, Lambda error/timeout và fallback rate.
- **Consequence:**
  - ✅ Prediction cadence độc lập với telemetry ingest rate.
  - ✅ 5 phút tạo khoảng 3 cơ hội phát hiện trong lead time 15 phút.
  - ✅ Tránh gọi AI quá dày và giảm cost.
  - ✅ Kiến trúc đơn giản hơn vì không có prediction-schedule DLQ.
  - ⚠️ Một scheduled event fail không được lưu để replay.
  - ⚠️ Phải có alarm rõ để không miss lỗi Scheduler/Lambda.
- **Alternatives considered:**
  - Trigger Prediction Lambda từ SQS telemetry event: rejected vì dễ gọi AI theo từng metric/batch, quá tải và tạo prediction trùng.
  - EventBridge Event Bus: không tự tạo cadence; chỉ phù hợp nếu sau này trigger theo business/ops event.
  - Scheduler DLQ: rejected trong scope hiện tại vì prediction là recomputable job; telemetry DLQ quan trọng hơn.

---

## ADR-008 - CDO08 host AI Engine Runtime trên ECS Fargate

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** Deployment Contract sau khi được AI sửa xác nhận mỗi CDO tự host AI Engine trên platform riêng. AI bàn giao artifact/spec, CDO deploy engine và expose endpoint riêng theo contract.
- **Decision:** CDO08 host AI Engine Runtime bằng ECS Fargate stateless FastAPI, AI API Gateway `AWS_IAM` + VPC Link tới internal ALB, ECS task trong private subnet, port 8080, `/health`, `POST /v1/predict`, IAM SigV4, baseline storage trên S3 mã hóa KMS.
- **Consequence:**
  - ✅ Khớp contract và ownership CDO/CDO platform.
  - ✅ Container FastAPI phù hợp ECS Fargate và rollout/rollback bằng ECS task definition/CodeDeploy.
  - ✅ Không cần Bedrock LLM/API key vì AI contract dùng statistical time-series.
  - ⚠️ CDO08 chịu cost runtime, ALB, logs và scaling.
  - ⚠️ Cần container hardening, IAM role, internal networking và health checks.
  - ⚠️ Nếu artifact AI bàn giao muộn, W11 chỉ chứng minh được mock/skeleton path.
- **Alternatives considered:**
  - AI-hosted shared endpoint: rejected vì contract đã sửa, không đúng ownership cuối.
  - Lambda container: có thể thấp fixed cost hơn nhưng chỉ hợp lý nếu artifact nhẹ và startup/P99 phù hợp.
  - EKS: quá nặng cho timeline và không cần K8s-specific capability.

---

## ADR-009 - Dùng Lambda Prediction Adapter giữa AMP và AI Engine

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** AI Engine không nên biết chi tiết PromQL/AMP schema, còn dashboard/audit/fallback cần context riêng của CDO08. Request AI phải có `signal_window` ≥120 phút và map đúng `metric_type`.
- **Decision:** Dùng Prediction Integration Lambda để query AMP, build `signal_window`, gọi `/v1/predict`, xử lý 400/401/422/429/503, tạo audit và Grafana annotation.
- **Consequence:**
  - ✅ Cô lập AI Engine khỏi storage/query detail.
  - ✅ Dễ mock trong W11 và đổi sang engine thật trong W12.
  - ✅ Có điểm kiểm soát timeout/retry/circuit breaker.
  - ⚠️ Cold start và Lambda timeout cần cấu hình.
  - ⚠️ Phải cap concurrency để không retry storm làm quá tải AI Engine.
- **Alternatives considered:**
  - ECS integration service: hợp lý nếu QPS cao/streaming, nhưng fixed cost và ops tăng.
  - Step Functions: quan sát workflow tốt nhưng quá nặng cho một prediction call.

---

## ADR-010 - Dùng fail-open static threshold khi AI lỗi

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** TF4 hard requirement: nếu AI serving down, hệ thống vẫn phải alert bằng threshold rule. CDO08 cần phân biệt model prediction với fallback result.
- **Decision:** Dùng Fallback Evaluator Lambda khi AI timeout, 429/503 hoặc exhausted retry budget. Fallback query AMP metric gần nhất và so với static threshold per service/metric, sau đó tạo audit và Grafana annotation có `fallback=true`.
- **Consequence:**
  - ✅ Đáp ứng fail-open requirement.
  - ✅ Có evidence rõ khi inject AI failure.
  - ✅ Không làm mất cảnh báo khi AI unavailable.
  - ⚠️ Threshold có thể false positive/negative hơn model.
  - ⚠️ Cần quản lý threshold config riêng.
- **Alternatives considered:**
  - CloudWatch Alarm trực tiếp: hợp lý làm safety net, nhưng khó gắn đủ recommendation/correlation/audit vào cùng prediction flow.
  - Không fallback: rejected vì fail hard requirement.

---

## ADR-011 - Dùng DynamoDB cho CDO audit store và CloudWatch Logs cho AI Engine audit

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** CDO08 cần tra cứu prediction/fallback theo correlation/service nhanh. AI API Contract yêu cầu mỗi AI request có audit log nội bộ với retention 1 năm.
- **Decision:** Dùng DynamoDB SSE-KMS + TTL làm CDO audit store cho prediction/fallback records; AI Engine ghi audit fields bắt buộc vào CloudWatch Logs log group riêng, KMS encrypted, retention 1 năm.
- **Consequence:**
  - ✅ DynamoDB phù hợp access pattern tra một prediction/correlation.
  - ✅ Tách CDO operational audit khỏi AI Engine internal audit.
  - ✅ TTL hỗ trợ cleanup CDO audit sau retention đã chốt.
  - ✅ CloudWatch Logs đáp ứng audit retention 1 năm cho AI Engine theo contract.
  - ⚠️ DynamoDB không tiện cho báo cáo SQL phức tạp.
  - ⚠️ CloudWatch retention 1 năm có cost; phải log đúng field, không log raw PII/secret.
- **Alternatives considered:**
  - Aurora/RDS audit DB: rejected vì always-on cost/connection/backup cao cho capstone.
  - S3-only audit: rẻ nhưng query/correlation lookup và access control nghiệp vụ yếu hơn.
  - CloudWatch-only cho tất cả audit: dễ ghi log nhưng khó query theo workflow CDO/Grafana.

---

## ADR-012 - Dùng Amazon Managed Grafana làm dashboard overlay

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** TF4 yêu cầu Grafana annotation overlay; CDO không build UI mới. Cần dashboard hiển thị metric, prediction, fallback và evidence link.
- **Decision:** Dùng Amazon Managed Grafana query AMP và hiển thị annotation do Prediction/Fallback Lambda tạo.
- **Consequence:**
  - ✅ Khớp yêu cầu Grafana overlay.
  - ✅ Tận dụng AMP datasource và tag/filter theo service.
  - ✅ Không tốn thời gian build UI mới.
  - ⚠️ Cần quản lý Grafana token/service account trong Secrets Manager.
  - ⚠️ Grafana workspace/user có fixed cost.
- **Alternatives considered:**
  - Grafana tự quản trên ECS/EKS: rejected vì patching/persistent state tăng scope.
  - CloudWatch Dashboard only: rejected làm dashboard chính vì không đáp ứng rõ Grafana annotation requirement.

---

## ADR-013 - Dùng CloudWatch cho operational observability, AMP cho telemetry time-series

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** AMP lưu application/infra telemetry cho AI/Grafana, nhưng Lambda/SQS/ECS/API Gateway vẫn cần operational logs/metrics/alarms để debug reliability.
- **Decision:** Dùng CloudWatch Logs/Metrics/Alarms cho platform health; AMP giữ primary telemetry time-series; Grafana dùng AMP và annotation.
- **Consequence:**
  - ✅ CloudWatch native cho Lambda/SQS/ECS/API Gateway.
  - ✅ Có alarm cho queue age, DLQ, writer error, prediction error, fallback rate, ECS health.
  - ✅ AMP/Grafana tập trung vào metric window và dashboard.
  - ⚠️ Hai hệ quan sát cần naming/correlation ID nhất quán.
  - ⚠️ Log volume cần retention guard để không đội cost.
- **Alternatives considered:**
  - AMP + Grafana only: rejected vì không đủ debug Lambda/SQS/DLQ.
  - Full OpenTelemetry tracing ngay W11: future work; tăng instrumentation/collector/backend scope.

---

## ADR-014 - Dùng Terraform và CodeDeploy/ECS rollback cho deployment

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** CDO08 cần deploy reproducible và tạo evidence W12. AI Engine runtime là ECS Fargate theo contract, rollback target <60s bằng previous task definition/CodeDeploy.
- **Decision:** Dùng Terraform cho AWS infrastructure trong một môi trường shared `sandbox`, với S3 remote state và native S3 lockfile `use_lockfile=true`; dùng CodeDeploy canary/blue-green cho ECS AI Engine nếu kịp W12, fallback là ECS service revert previous task definition có runbook.
- **Consequence:**
  - ✅ Terraform plan/apply dễ review và attach evidence.
  - ✅ CodeDeploy/ECS task definition rollback khớp contract.
  - ✅ Không cần GitOps/ArgoCD vì không dùng EKS.
  - ⚠️ CodeDeploy setup có thêm complexity.
  - ⚠️ Nếu W11 chưa kịp, rollback evidence sẽ là manual ECS revert, phải ghi limitation.
- **Alternatives considered:**
  - CDK/CloudFormation: hợp lý nhưng team đang dùng docs/Terraform-oriented workflow.
  - ArgoCD/GitOps: rejected vì không dùng Kubernetes; chỉ cân nhắc nếu chuyển EKS.
  - Manual console deploy: rejected vì evidence yếu và khó tái lập.

---

## ADR-015 - Giữ telemetry sampling 60s và prediction interval 5 phút

- **Status:** Accepted
- **Date:** 2026-06-25
- **Context:** Telemetry Contract yêu cầu frequency 1 phút; AI API yêu cầu window ≥120 phút. Sampling quá dày làm tăng AMP/API/Lambda volume, còn prediction quá dày làm tăng AMP query, AI call, audit và annotation cost.
- **Decision:** Default telemetry emit interval = 60s; EventBridge prediction interval = 5 phút/service; lookback window ≥120 phút.
- **Consequence:**
  - ✅ Khớp Telemetry Contract frequency.
  - ✅ Trong lead time 15 phút có khoảng 3 prediction opportunities.
  - ✅ Cost thấp và query window vẫn đủ cho gradual drift/slow leak.
  - ⚠️ Không phù hợp nếu cần sub-minute detection.
  - ⚠️ 10s sampling chỉ được dùng cho short test có start/end rõ.
- **Alternatives considered:**
  - 30s/10s sampling: có thể chi tiết hơn nhưng tăng ingest/storage/query volume; không cần cho capacity trend hiện tại.
  - Prediction mỗi 30s: rejected vì query gần như trùng window và tăng cost 10x so với 5 phút.
  - Prediction theo mỗi data point: rejected vì dễ quá tải AI Engine và audit/dashboard noise.

---

## ADR-016 - Đưa AI Engine sau API Gateway AWS_IAM + VPC Link + internal ALB

- **Status:** Accepted
- **Date:** 2026-07-01
- **Context:** Deployment Contract yêu cầu AI Engine private/internal path và SigV4 auth. Ban đầu CDO08 từng dùng ALB public để demo nhanh, nhưng final W12 cần align contract và giảm public exposure.
- **Decision:** Expose AI Engine qua API Gateway `AWS_IAM`. API Gateway dùng VPC Link tới internal ALB trong AI VPC; ECS AI Engine chạy private subnet, không public IP.
- **Consequence:**
  - ✅ Khớp contract private runtime và SigV4 edge.
  - ✅ Serving Adapter không cần vào AI VPC; chỉ cần gọi public API Gateway bằng SigV4.
  - ✅ ALB không public, ECS task chỉ nhận traffic từ ALB.
  - ⚠️ Thêm API Gateway/VPC Link component cần monitor.
  - ⚠️ Cần IAM permission `execute-api:Invoke` đúng route cho Serving Adapter.
- **Alternatives considered:**
  - Public ALB: dùng được cho demo nhanh nhưng không khớp final contract/security expectation.
  - Lambda trong VPC gọi internal ALB trực tiếp: private hơn nhưng cần Lambda VPC networking, endpoint/egress path và phức tạp hơn.
  - VPC peering giữa workload/AI VPC: rejected vì hai VPC không cần nói chuyện trực tiếp.

---

## ADR-017 - Bounded outbound path cho workload generator trong private subnet

- **Status:** Accepted
- **Date:** 2026-07-01
- **Context:** Diagram yêu cầu k6 generator chạy trên AWS trong private subnet. k6 cần gọi ingest API Gateway public endpoint, pull image/ECR và ghi logs trong test window.
- **Decision:** Dùng bounded outbound path ở workload VPC để ECS k6 private subnet có egress trong test window.
- **Consequence:**
  - ✅ k6 không có public inbound/public IP.
  - ✅ Giữ đúng diagram ECS private subnet.
  - ✅ Chạy được real 2h window trên AWS, không phụ thuộc laptop.
  - ⚠️ Private outbound path có fixed hourly cost, cần cost guardrail và cleanup review sau demo.
  - ⚠️ Không nên mở rộng egress path khi chưa review cost.
- **Alternatives considered:**
  - Run k6 local: rẻ hơn nhưng không khớp diagram/evidence AWS.
  - Assign public IP cho ECS k6: đơn giản hơn nhưng yếu hơn về private workload story.
  - Chỉ dùng VPC endpoints: không đủ cho public API Gateway ingest path hiện tại và tăng endpoint complexity.

---

## ADR-018 - Provision Grafana datasource/dashboard bằng script, token lưu Secrets Manager

- **Status:** Accepted
- **Date:** 2026-07-01
- **Context:** Terraform AWS provider không quản lý đầy đủ Grafana dashboard/datasource bằng native AWS resource. Grafana service account token không được hard-code trong Terraform state/source.
- **Decision:** Terraform tạo/reference Grafana workspace và Secrets Manager secret. Script `scripts/provision_grafana.py` đọc token runtime, tạo AMP datasource và dashboard JSON.
- **Consequence:**
  - ✅ Dashboard reproducible hơn thao tác tay.
  - ✅ Token không commit vào repo.
  - ✅ Dễ update dashboard JSON theo source control.
  - ⚠️ Cần tạo/rotate Grafana service account token thủ công hoặc qua Grafana API sau khi workspace ready.
  - ⚠️ Reviewer cần chạy script sau apply nếu dashboard chưa tồn tại.
- **Alternatives considered:**
  - Tạo dashboard tay trên UI: nhanh nhưng không reproducible.
  - Commit token trong `.tfvars`/env: rejected vì secret leakage.
  - Self-managed Grafana provider: không cần thiết cho capstone scope.

---

## ADR-019 - Chặn annotation spam bằng freshness guard, cooldown và idempotent point annotations

- **Status:** Accepted
- **Date:** 2026-07-01
- **Context:** Sau khi k6 dừng, EventBridge vẫn gọi Prediction Lambda mỗi 5 phút. Nếu Prediction Lambda tiếp tục dùng stale 120-minute window hoặc không dedupe theo service, Grafana bị spam annotation dù không còn data mới.
- **Decision:** Prediction Lambda chỉ gọi AI khi có telemetry mới trong freshness window, tạo point annotation thay vì time range dài, và dùng DynamoDB `Query` để cooldown/dedupe theo service.
- **Consequence:**
  - ✅ Dashboard ít noise hơn và annotation có ý nghĩa thời điểm.
  - ✅ Khi không có data mới, Lambda ghi skip reason thay vì gọi AI.
  - ✅ Cooldown giảm duplicate annotation cùng một anomaly.
  - ⚠️ Prediction role cần thêm `dynamodb:Query`.
  - ⚠️ Nếu cooldown quá dài có thể bỏ qua anomaly kế tiếp; cần tuning sau capstone.
- **Alternatives considered:**
  - Tắt Scheduler khi k6 dừng: giảm spam nhưng không chứng minh 24/7 prediction behavior.
  - Chỉ sửa Grafana filter: che triệu chứng, không giảm audit/API calls.
  - Luôn gọi AI mỗi 5 phút: rejected vì gây annotation spam và cost/noise.
