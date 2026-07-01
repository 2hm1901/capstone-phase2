# Requirements Analysis - Task Force 4 · CDO08

**Document owner:** CDO08

**Status:** Final draft for W12 Evidence Pack #2
**Last updated:** 2026-07-01

## 1. Đề tài context

Client là Head of SRE tại một fintech vận hành khoảng 120 microservice trên ECS Fargate, RDS Aurora MySQL, DynamoDB và SQS. Trong ba tháng gần đây, Client đã miss SLO availability 99.9% bảy lần liên tiếp. Các sự cố không mang tính catastrophic mà bắt đầu bằng capacity exhaustion âm thầm: RDS CPU tăng đến 100% trước khi connection pool exhaust, queue backlog tăng làm consumer timeout, hoặc ALB active connections chạm giới hạn khi traffic tăng. Internal monitoring hiện phát hiện muộn, sau khi người dùng đã tạo 18–25 support ticket. Static threshold không giải quyết được vì quá nhạy sẽ gây alert fatigue, còn quá tù sẽ không bắt được drift chậm.

Foresight Lens là hệ thống dự báo chủ động: nhận telemetry hạ tầng liên tục, học baseline riêng từng service, dự đoán drift/capacity exhaustion và đưa capacity recommendation cụ thể để con người duyệt. Sản phẩm chỉ **predict + recommend**, không auto-remediation. Các phần ngoài phạm vi là cross-service root cause analysis, cost forecasting, auto-retrain pipeline, multi-region deployment thực tế, production traffic mirror, custom business metric, LLM prediction và UI dashboard mới.

CDO08 chịu trách nhiệm platform: tạo/ingest telemetry cho ba service demo, lưu và query time-series, **host AI Engine Runtime trên platform CDO08 theo artifact/spec AI bàn giao**, gọi endpoint `POST /v1/predict`, hiển thị kết quả trên Grafana bằng annotation, tạo audit log mã hóa và duy trì static-threshold fail-open khi AI serving down. AI team sở hữu thuật toán/baseline logic, prediction, confidence và capacity recommendation; CDO08 sở hữu runtime hosting, IAM, network, scaling, rollout/rollback và observability theo Deployment Contract. Telemetry, AI API và Deployment contracts là interface bắt buộc, freeze vào T5 W11.

## 2. Infra non-functional requirements

| NFR | Target cho capstone | Justification |
|---|---:|---|
| Multi-service / logical tenant | ≥3 service; event có `tenant_id`, `service_id`, `metric_type` | Hard requirement TF4. Capstone chứng minh baseline/query theo service, không cam kết provision 50 tenant thật. |
| Telemetry retention | ≥90 ngày | Yêu cầu contract TF4; storage phải query time-series hiệu quả, raw S3 không là primary store. |
| Lead time | ≥15 phút trước SLO breach trong cửa sổ test ≥2 giờ | Hard acceptance criterion; CDO08 phải giữ timestamp để chứng minh. |
| Detection quality | FP ≤12%, catch ≥80% drift | AI sở hữu model metric; CDO08 tạo scenario, ground truth và artifact test. |
| Integration latency | Target P99 platform-to-AI <1,000 ms; AI API contract target <500 ms cho model serving path khi ổn định | Tránh dashboard/alert chậm; không thay thế measured latency evidence trong W12 test report. |
| Availability | ≥99.5% demo-quality, có fail-open | Client chấp nhận demo-quality; AI down không được làm mất cảnh báo. |
| Security | IAM least privilege, KMS encryption at rest, secret không có trong code/log | Telemetry không có PII; audit cần truy vết an toàn. |
| Audit | Mỗi prediction call có ≥6 field và retention được ghi rõ | Hard requirement; phải liên kết request, outcome, recommendation và fallback. |
| Cost | Forecast platform < $200/tháng; budget alert/circuit-breaker testable | Rough cap cho capstone, cập nhật actual ở W12. |

## 3. CDO08 focus: operational trust, with measurable evidence

CDO08 chọn trọng tâm **operational trust**: telemetry phải đến đúng nơi, prediction phải truy vết được tới dashboard/audit, và cảnh báo không được biến mất khi AI serving gặp lỗi. Đây không phải yêu cầu dùng kiến trúc khác hai CDO còn lại. Theo định hướng mentor, các nhóm có thể chọn công nghệ giống nhau; CDO08 cạnh tranh bằng implementation, failure handling và evidence tốt hơn.

CDO08 ưu tiên ba năng lực. Thứ nhất, telemetry pipeline có schema validation, retry/error visibility và query được theo service/metric. Thứ hai, correlation ID xuyên suốt ingest, AI request, response, Grafana annotation và encrypted audit log để một alert có thể điều tra ngược. Thứ ba, static-threshold fail-open chỉ kích hoạt khi AI timeout, 429/503 hoặc exhausted retry, và được test thực tế. Trọng tâm này trực tiếp xử lý pain point của Client: internal alert không thể đến sau support ticket.

Trade-off được chấp nhận là không chạy theo các feature ngoài scope như auto-remediation, active-active multi-region hoặc dashboard UI mới. Thời gian tập trung cho E2E test, audit/security, failure scenarios và IaC tái lập. CDO08 không tuyên bố thắng trước khi đo; claim sẽ có dạng **target → test procedure → raw artifact → measured result**.

| Tiêu chí cạnh tranh | Target / câu hỏi đánh giá | Evidence cần tạo |
|---|---|---|
| Telemetry reliability | Event hợp lệ có đến storage/query được không? | Ingest success/error/retry metrics; query result cho 3 service |
| E2E traceability | Có lần được từ metric tới prediction, annotation và audit không? | Shared request/correlation ID xuyên các artifact |
| Lead time | Có cảnh báo ≥15 phút trước breach không? | Timestamp generator, prediction, breach; phép tính lead time |
| Resilience | AI down có fallback alert không? | Test timeout/503, fallback alert, audit `fallback=true` |
| Security/isolation | Service/tenant khác có đọc hoặc gửi nhầm data không? | IAM/KMS config, negative isolation test, redacted log sample |
| Cost/operability | Có dưới budget và deploy lại được không? | Terraform plan/apply, cost model, budget/circuit-breaker evidence |

## 4. Final platform scope

CDO08 demo ba service synthetic đã align với AI baseline và evidence hiện tại:

| Service ID | Ý nghĩa demo | Metric focus |
|---|---|---|
| `payment-gw` | Payment gateway | CPU, memory, latency, active connections, queue depth, DB pool, cache hit rate |
| `ledger` | Ledger service | CPU, memory, latency, queue depth, DB pool, cache hit rate |
| `fraud-detector` | Fraud detection service | CPU, memory, latency, queue depth, DB pool, cache hit rate |

Generator tạo normal baseline và bốn test profiles: `gradual_drift`, `sudden_spike`, `slow_leak`, `noisy_baseline`. Mỗi scenario có thể chạy tái lập trên ECS Fargate bằng k6. Với W12 evidence, best practice là chạy **3 services + 1 scenario** trong cùng một window để dashboard và annotation dễ giải thích; `all` chỉ dùng smoke/mixed test, không dùng làm số liệu precision/recall chính.

Luồng mục tiêu là: synthetic generator → telemetry ingestion → time-series storage → query window → Prediction Lambda → AI Engine Runtime do CDO08 host → prediction/recommendation → Grafana annotation và encrypted audit log. CDO08 có thể dùng mock endpoint đúng contract shape trong W11; W12 T3 phải deploy artifact AI thật lên ECS Fargate của CDO08 và gọi endpoint thật. Static threshold evaluation là nhánh độc lập chỉ hoạt động khi AI call thất bại, không thay thế model trong normal path.

## 5. Constraints

- **Cloud:** AWS-only, single region `us-east-1`. DR multi-region chỉ design-only.
- **Timeline:** Contract freeze T5 W11; EOD T6 W11 cần base infra; W12 tích hợp real engine, test và hoàn tất evidence. Code freeze 08:00 T5 W12, 02/07/2026.
- **Data and scope:** Không ingest PII, không dùng production traffic hoặc historical 6-month data. Grafana annotation thay UI mới.
- **Cost:** Resource có tags, budget alert và teardown/runbook; không vượt rough cap $200/tháng.
- **Change control:** Sau contract freeze, schema/URL/auth/SLA chỉ đổi qua quy trình curveball/đồng thuận; implementation nội bộ có thể iterate với ADR.

## 6. Resolved decisions and remaining evidence

| Topic | W12 decision |
|---|---|
| Tier-1 services | `payment-gw`, `ledger`, `fraud-detector` |
| Logical tenant | `tenant_id` is retained as a logical tenant/account label; demo tenant is `tenant-cdo08-demo` |
| Region/account | Shared AWS account `894597652722`, region `us-east-1` |
| Telemetry granularity | 60 seconds default; 120-minute lookback for prediction |
| Telemetry store | AMP, because Timestream LiveAnalytics is unavailable to the capstone account |
| Ingest auth | API Gateway `AWS_IAM`; k6 signs requests with SigV4 |
| AI runtime path | AI API Gateway `AWS_IAM` → VPC Link → internal ALB → ECS Fargate private subnets |
| AI image/baseline | AI image is deployed from ECR with immutable tag; baseline files are in `s3://cdo08-sandbox-ai-baselines-894597652722/baselines/` |
| Audit | CDO platform audit in DynamoDB with KMS/TTL; AI Engine audit logs in CloudWatch with 1-year retention per contract |
| Dashboard | Amazon Managed Grafana workspace with AMP datasource and annotation overlay |

Remaining W12 evidence to capture is tracked in [`W12_EVIDENCE_PACK.md`](W12_EVIDENCE_PACK.md) and [`07_test_eval_report.md`](07_test_eval_report.md).
