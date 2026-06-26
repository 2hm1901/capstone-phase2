# [TF4][W11] Nhân - AI Integration Adapter + Fail-open + Scheduler Security

**Người phụ trách:** Nhân
**Ngày:** `2026-06-26`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Nhân chịu trách nhiệm thiết kế và triển khai phần AI Integration Adapter với trigger từ EventBridge Scheduler, đồng thời bổ sung cơ chế fail-open khi AI không phục vụ. Mục tiêu là giữ lead time ≥15 phút bằng prediction định kỳ, tránh gọi AI theo từng datapoint, và bảo đảm fallback tạm thời với static threshold khi AI timeout/429/503/exhausted retry.

- EventBridge Scheduler chỉ trigger Prediction Lambda, không quyết định telemetry data point interval.
- Prediction Lambda query AMP với window ≥120 phút và build `signal_window` để gọi `/v1/predict`.
- Các lỗi 400/401/429/503 được phân loại: 400/401 dừng, 429/503 retry/backoff, timeout/xử lý thành fail-open nếu cần.
- Fail-open sử dụng static threshold khi AI timeout/429/503/exhausted retry để vẫn đưa ra quyết định an toàn.
- Security input gồm Scheduler role, Prediction/Fallback IAM, SigV4, idempotency key, không dùng Scheduler DLQ và ngăn duplicate annotation.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Lead time ≥15 phút; fail-open khi AI down | Prediction phải định kỳ và có fallback |
| AI API Contract | `POST /v1/predict`, window ≥120 phút, 400/401/429/503 | Adapter phải build payload và xử lý lỗi đúng |
| Deployment Contract | AI Engine CDO08 host, SigV4, rate limit | Gọi endpoint nội bộ an toàn và tuân thủ auth |
| CDO08 docs 02 | EventBridge Scheduler mỗi 5 phút; Prediction Lambda; Fallback Lambda | Validate lựa chọn kiến trúc |
| CDO08 docs 03 | IAM boundary, idempotency, no Scheduler DLQ | Security input và triển khai monitoring |

> Lưu ý: EventBridge Scheduler chỉ trigger prediction, không quyết định telemetry data point interval. Interval của telemetry data point vẫn do hệ thống ingest/AMP quy định, còn Scheduler chỉ đảm bảo prediction diễn ra theo cadence định nghĩa.

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
EventBridge Scheduler
  -> Prediction Lambda
      -> Query AMP window ≥120 phút
      -> Build signal_window
      -> POST /v1/predict
      -> Handle AI response/error
      -> Write audit + Grafana annotation
      -> If needed -> Fallback Lambda
```

### 3.2 Nó chịu trách nhiệm gì?

- Trigger prediction định kỳ theo EventBridge Scheduler.
- Query AMP với `window >= 120 phút` và không lấy dữ liệu theo từng điểm telemetry.
- Build đúng payload `signal_window` theo contract để gửi `/v1/predict`.
- Gọi AI Engine nội bộ bằng SigV4.
- Xử lý lỗi 400/401/429/503/trường hợp timeout.
- Kích hoạt fail-open static threshold khi AI timeout/429/503/exhausted retry.
- Ghi audit, annotation, đảm bảo idempotency và không duplicate.

### 3.3 Nó không chịu trách nhiệm gì?

- Không quyết định hoặc thay đổi interval của các điểm telemetry.
- Không thực hiện training model.
- Không thực hiện auto-remediation hoặc sửa đổi dữ liệu ingest.
- Không ghi duplicate annotation nếu Scheduler invoke trùng.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | EventBridge Scheduler + Prediction Lambda + Fallback Lambda |
| Lý do chính | Tách rõ trigger prediction khỏi ingest, giảm số lần gọi AI, dễ kiểm soát retry/fallback |
| Input | Schedule payload, AMP query window ≥120 phút |
| Output | AI/fallback result, audit record, Grafana annotation |
| Runtime | Lambda + EventBridge |
| Security boundary | Scheduler role chỉ invoke Prediction; Prediction role hạn chế read AMP / call AI / write audit |
| Observability | AI latency/error, fallback rate, scheduler invoke failure |
| Cost driver | Cadence 5 phút, AMP query, Lambda invocations |

### Chi tiết hành vi

- Prediction Lambda query AMP với `window >= 120 phút` để tạo `signal_window` tối thiểu, đúng yêu cầu API.
- Lambda xây payload và gọi `POST /v1/predict`.
- Nếu AI trả về 200, ghi kết quả và annotation.
- Nếu AI trả về 400: dừng và ghi audit; không retry.
- Nếu AI trả về 401: dừng, báo security/auth issue; không retry.
- Nếu AI trả về 429/503 hoặc timeout: retry với backoff, nếu hết retry thì kích hoạt fail-open static threshold.
- Fail-open static threshold không phải decision AI trong normal path, mà là cơ chế an toàn khi dependency AI không phục vụ.

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào phù hợp | Fit với CDO08 |
|---|---|---|---|---|
| Scheduler + Lambda adapter/fallback | Simple, bounded, dễ vận hành, phù hợp cadence định kỳ | Cold start, cần quản lý concurrency/retry | Thiết kế theo lịch định sẵn, low-to-medium throughput | High |
| SQS-trigger prediction | Hỗ trợ buffer và retry tự động | Có thể tạo nhiều AI calls, duplicate, khó giới hạn cadence | Khi cần xử lý event-driven, bursty input | Low |
| ECS integration service | Connection reuse, ổn định cho high throughput | Fixed cost, deployment phức tạp | Khi prediction liên tục và QPS cao | Medium |
| Step Functions | Workflow rõ ràng, trace từng bước | Cost/latency lớn, overkill cho path đơn giản | Khi cần orchestration nhiều bước hoặc approval | Low |

### So sánh ngắn

- SQS-trigger prediction phù hợp nếu cần xử lý queue lớn, nhưng không phù hợp với requirement prediction định kỳ mỗi 5 phút.
- ECS integration service phù hợp cho integration liên tục hoặc AI endpoint cần giữ kết nối, nhưng current scope dùng Lambda đủ và tiết kiệm hơn.
- Step Functions phù hợp cho workflow phức tạp, nhưng thiết kế hiện tại chỉ cần trigger + prediction + fallback nên thêm Step Functions sẽ tăng chi phí/độ phức tạp không cần thiết.

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [x] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên giữ EventBridge Scheduler + Prediction Lambda + Fallback Lambda vì nó cung cấp một thiết kế đơn giản, an toàn và phù hợp với yêu cầu định kỳ, đồng thời tránh gọi AI theo từng data point.

### 6.2 Lý do quyết định

- **Reliability:** cadence định kỳ + bounded retry + fail-open static threshold khi AI timeout/429/503/exhausted retry.
- **Security:** SigV4 nội bộ, IAM least privilege, idempotency key, no Scheduler DLQ.
- **Cost:** giữ cadence 5 phút, không gọi AI cho từng điểm telemetry, chỉ query AMP window lớn.
- **Delivery timeline:** có thể triển khai mock W11 và kiểm chứng W12 với real engine.
- **Evidence:** test AI success, AI 503 fallback, duplicate invoke/idempotency, fallback annotation/audit.

### 6.3 Điều kiện / assumption

- EventBridge Scheduler không dùng DLQ riêng; cần CloudWatch alarm / alert cho scheduler invoke failure.
- Fallback static threshold phải có config owner/version và review kỹ.
- Hệ thống phải hỗ trợ idempotency để tránh duplicate annotation bởi duplicate scheduler invoke.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Scheduler role chỉ có quyền invoke Prediction Lambda; Prediction/Fallback IAM role chỉ read AMP, call AI, write audit, invoke fallback khi valid |
| Scheduler role | Giới hạn trên EventBridge target, không có quyền truy cập AMP hoặc DynamoDB khác |
| Prediction/Fallback IAM | Hạn chế quyền, không có quyền ghi ngoại trừ audit, không có quyền chỉnh cấu hình AI |
| Network exposure | Prediction Lambda gọi internal AI endpoint; không open public internet |
| SigV4 | Bắt buộc dùng SigV4 với `/v1/predict` để bảo đảm auth và integrity |
| Idempotency | Dùng idempotency key cho mỗi scheduler invoke để tránh duplicate annotation/audit |
| No Scheduler DLQ | Không dùng DLQ riêng cho Scheduler; dùng CloudWatch alarm/alert thay vì retry mù |
| No duplicate annotation | Logic ghi annotation phải kiểm tra idempotency/audit key và chỉ ghi một lần cho cùng request |
| Secret handling | Grafana token, AI secrets lưu trong Secrets Manager; không log secret thông tin |

### Negative test đề xuất

- [ ] Kịch bản AI 503 phải kích hoạt fallback audit và annotation rõ lý do.
- [ ] 400 không retry mù và ghi audit error.
- [ ] 401 không retry và báo auth issue.
- [ ] Duplicate scheduler invoke không tạo duplicate annotation.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Scheduler invoke ID và payload summary.
- AMP query window, duration, và hash/summary của request.
- AI call status code, latency, error type.
- Fallback activation reason và threshold được dùng.
- Idempotency key và duplicate suppression event.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| prediction_success_count | Đánh giá path AI chính | sudden drop |
| ai_error_count | Phát hiện dependency AI issue | sustained >0 |
| fallback_count | Phát hiện fail-open kích hoạt | spike bất thường |
| prediction_duration_ms | Theo dõi latency và lead time | p95 cao |
| scheduler_invoke_failure | Phát hiện Scheduler / permission issue | >0 |

### 8.3 W12 evidence cần attach

- [ ] AI success response audit record.
- [ ] AI 429/503 fallback test.
- [ ] Grafana fallback annotation hiển thị đúng.
- [ ] Duplicate invoke / idempotency test.
- [ ] Fallback annotation/audit case chứng minh logic hoạt động.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Lambda invocations every 5 min/service | Giữ cadence 5 phút, hạn chế hot path |
| Requests/messages | AI calls + AMP query | Không gọi per data point, chỉ một call prediction mỗi lịch |
| Storage/retention | DynamoDB audit records | Dùng TTL, chỉ lưu summary |
| Logs/observability | Prediction/fallback logs | Tóm tắt, redact, dùng log level phù hợp |
| Fixed cost risk | AI Engine ECS/ALB handled separately | Cap concurrency/retry và monitor usage |

---

### Ghi chú
Thiết kế này ưu tiên rõ ràng, bảo mật và khả năng vận hành. EventBridge Scheduler chỉ trigger prediction, `signal_window` được xây từ AMP query ≥120 phút, và fail-open static threshold là cơ chế an toàn khi AI không phục vụ.
