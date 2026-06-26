# Giải thích template `nhan_task_doc_template.md`

File này giải thích cách điền đầy đủ từng mục trong template task của Nhân cho AI Integration Adapter, Fail-open và Scheduler Security. Nội dung được thiết kế để PM/TL đọc hiểu requirement, design hiện tại, lựa chọn thay thế, recommendation, security, observability/evidence và cost impact.

---

## 1. Executive summary

Mục đích của section này là tóm tắt nhanh: việc này giải quyết vấn đề gì, tại sao chọn thiết kế này, và những điều chính cần biết.

Nên trả lời:
- Component này làm gì: EventBridge Scheduler trigger Prediction Lambda.
- Tại sao không gọi AI theo từng data point: vì phải bảo đảm lead time, giảm tải AI và tránh gọi theo cadence high-frequency.
- Cách xử lý lỗi: 400/401/429/503 được phân loại rõ, chỉ retry trên lỗi tạm thời, và fail-open static threshold khi AI không phục vụ.
- Fallback: khi AI down hoặc quá tải, dùng static threshold để vẫn giữ hành vi an toàn.
- Security input chính: IAM role cho Scheduler và Lambda, SigV4, idempotency key, không có Scheduler DLQ, tránh duplicate annotation.

---

## 2. Requirement từ đề bài / contract

Section này ghi rõ các nguồn requirement và mapping vào thiết kế.

Ví dụ:
- TF4 learner brief: lead time ≥15 phút và fail-open khi AI down => cần prediction theo lịch và fallback tách biệt.
- AI API Contract: `POST /v1/predict` với window ≥120 phút, build `signal_window` đúng định dạng, xử lý 400/401/429/503.
- Deployment Contract: AI Engine internal `CDO08` host, SigV4 auth, rate limit và network security.
- CDO08 docs 02: EventBridge Scheduler mỗi 5 phút; Prediction Lambda; Fallback Lambda.
- CDO08 docs 03: IAM least privilege, idempotency key, no Scheduler DLQ, no duplicate annotation.

Nên nêu rõ: EventBridge Scheduler chỉ trigger prediction, không ra quyết định telemetry data point interval. Scheduler chỉ định kỳ gọi prediction, interval telemetry vẫn được quyết định bởi AMP/telemetry pipeline và business cadence.

---

## 3. Component/security input này là gì?

Section này giải thích component cụ thể trong flow và phân biệt rõ trách nhiệm.

### 3.1 Nó nằm ở đâu trong flow?

Sơ đồ dòng đơn giản:

```text
EventBridge Scheduler
  -> Prediction Lambda
      -> query AMP window ≥120 phút
      -> build signal_window
      -> POST /v1/predict
      -> handle AI response / errors
      -> DynamoDB audit + Grafana annotation
      -> if needed call Fallback Lambda
```

### 3.2 Nó chịu trách nhiệm gì?

- Trigger prediction theo lịch định sẵn.
- Query AMP với window >= 120 phút, không quyết định telemetry interval.
- Build payload `signal_window` hợp lệ.
- Gọi `/v1/predict` và xử lý lỗi 400/401/429/503.
- Dùng fail-open static threshold khi AI timeout/429/503/exhausted retry.
- Ghi audit, annotation, và bảo đảm idempotency.

### 3.3 Nó không chịu trách nhiệm gì?

- Không quyết định telemetry data point interval.
- Không trực tiếp điều khiển ingest hoặc alerting.
- Không dùng để train model.
- Không duplicate annotation khi scheduler invoke trùng.

---

## 4. Current CDO08 design

Section này trình bày thiết kế hiện tại đã chọn và lý do.

- AWS service/pattern: EventBridge Scheduler + Prediction Lambda + Fallback Lambda.
- Lý do: tách prediction cadence khỏi telemetry ingest, đơn giản hoá retry/fallback, giữ security boundary rõ.
- Input: schedule payload, AMP query window ≥120 phút.
- Output: AI/fallback result, audit record, Grafana annotation.
- Security boundary: Scheduler role chỉ invoke Prediction; Prediction role giới hạn AMP query, AI call, audit write; Fallback role cũng giới hạn.
- Observability: metrics cho latency, error, fallback, scheduler invoke.
- Cost driver: cadence 5 phút, AMP query, Lambda invocation.

Phần giải thích nên nhắc:
- Prediction Lambda query AMP window ≥120 phút và build `signal_window`.
- `signal_window` phải là dữ liệu input cho `/v1/predict`.
- `POST /v1/predict` là điểm gọi AI chính, dùng SigV4.
- Xử lý lỗi:
  - 400: bad request, không retry, log audit.
  - 401: auth issue, không retry, security investigation.
  - 429/503: retry theo backoff, nếu vẫn fail thì activate fail-open static threshold.
  - timeout: cũng coi là dependency failure và fallback.

---

## 5. Options considered

So sánh ngắn với các phương án khác và vì sao current design phù hợp.

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào phù hợp | Fit với CDO08 |
|---|---|---|---|---|
| Current: Scheduler + Lambda adapter/fallback | Simple, bounded, rõ ràng, dễ observe | Cold start, cần manage concurrent Lambda | Scope dự án hiện tại | High |
| SQS-trigger prediction | Có thể buffer và dễ retry | Gây latency, dễ tạo nhiều AI calls, phức tạp duplicate | Khi cần queue-based resilience lớn | Low |
| ECS integration service | Giữ connection pool, có thể xử lý high throughput | Fixed cost, deploy overhead | Khi số lượng prediction lớn liên tục | Medium |
| Step Functions | Workflow rõ, audit từng bước | Complex, cost cao, latency tăng | Khi có nhiều step approval / orchestration | Low |

Giải thích thêm:
- SQS-trigger prediction có thể phù hợp nếu muốn buffer request từ nhiều nguồn, nhưng không cần trong thiết kế scheduler định kỳ.
- ECS integration service phù hợp khi AI endpoint cần kết nối lâu dài hoặc cần high QPS; hiện tại prediction theo lịch 5 phút nên Lambda đủ.
- Step Functions phù hợp khi cần orchestration phức tạp, nhưng cho workflow đơn giản này sẽ gây chi phí và latency không cần thiết.

---

## 6. Recommendation

Section này nêu rõ lựa chọn chính và lý do. Dùng ngôn ngữ đủ để PM/TL hiểu và merge.

Recommendation tiêu biểu:

> Giữ current design EventBridge Scheduler + Prediction Lambda + Fallback Lambda vì nó tối ưu cho reliability, security và cost trong scope CDO08.

Lý do:
- Reliability: bounded retry, fail-open static threshold khi AI timeout/429/503/exhausted retry.
- Security: SigV4 internal call, IAM least privilege, idempotency key, no Scheduler DLQ.
- Cost: prediction every 5 phút thay vì gọi AI theo mỗi telemetry point.
- Delivery timeline: có thể triển khai nhanh W11 mock, W12 chuyển sang real engine.
- Evidence: test AI success, AI 503 fallback, duplicate invoke/idempotency, fallback annotation/audit.

Condition/assumption:
- EventBridge Scheduler không dùng DLQ, nên cần CloudWatch alarm và monitoring scheduler invoke failure.
- Fallback threshold config cần người quản lý và version.
- Duplicate scheduler invokes có thể xảy ra; idempotency key và audit logic bắt buộc.

---

## 7. Security considerations

Section này liệt rõ security input và risk mitigation.

| Security area | Yêu cầu / quyết định |
|---|---|
| IAM least privilege | Scheduler role chỉ invoke Prediction Lambda; Prediction/Fallback role chỉ thực hiện AMP query, AI call, audit write |
| Scheduler role | chỉ có quyền `events:InvokeFunction` với target Prediction Lambda |
| Prediction/Fallback IAM | không cho phép update dữ liệu không cần thiết, chỉ read AMP, write audit, invoke fallback nếu cần |
| Network | Prediction Lambda gọi internal AI endpoint, không public internet |
| SigV4 | mọi request tới `/v1/predict` phải dùng SigV4 để đảm bảo auth và integrity |
| Idempotency | mỗi scheduler invoke phải dùng idempotency key để tránh duplicate annotation và duplicate audit |
| No Scheduler DLQ | không tạo DLQ riêng cho Scheduler; dùng CloudWatch alarm/alert thay vì silent retries |
| No duplicate annotation | logic annotation audit phải kiểm tra idempotency và chỉ ghi một lần cho cùng prediction lần gọi |
| Secret handling | Grafana/annotation token lưu ở Secrets Manager; không log secrets |

Negative tests / security evidence:
- AI 503 fallback phải ghi audit và annotation rõ lý do.
- Duplicate scheduler invoke không tạo duplicate annotation.
- 401/400 phải báo rõ và không retry vô ích.

---

## 8. Observability and evidence

Section này trình bày logs/metrics/evidence cần để chốt W12.

### 8.1 Logs cần có
- Scheduler invoke metadata.
- AMP query window, duration, request summary.
- POST `/v1/predict` request payload size, endpoint, status code.
- Error category: 400/401/429/503/timeout.
- Fallback activation reason và threshold value.
- Idempotency key và duplicate suppression events.

### 8.2 Metrics cần có

| Metric | Mục đích | Alert |
|---|---|---|
| prediction_success_count | đo path AI thành công | sudden drop |
| ai_error_count | đo dependency AI failure | sustained >0 |
| fallback_count | đo fail-open kích hoạt | spike bất thường |
| prediction_duration_ms | đo latency, lead time | p95 cao |
| scheduler_invoke_failures | đo sự cố Scheduler role/call | >0 |

### 8.3 W12 evidence/test đề xuất

- [ ] AI success response audit: xác nhận schema và annotation.
- [ ] AI 503 fallback test: trigger 503 trên `/v1/predict`, verify static threshold fallback và audit record.
- [ ] Duplicate invoke / idempotency test: kích hoạt cùng scheduler payload 2 lần, verify only one annotation/audit.
- [ ] Fallback annotation/audit test: verify fallback path ghi annotation và audit event rõ lý do.

---

## 9. Cost impact

Section này nêu chi phí và rủi ro chi phí của thiết kế.

| Cost driver | Tác động | Biện pháp giảm |
|---|---|---|
| Lambda runtime | invoke every 5 phút | giữ cadence, tái sử dụng cold start nếu có thể |
| AMP query | query window ≥120 phút mỗi prediction | không query theo per-point, chỉ lấy window aggregate |
| AI calls | mỗi prediction một call, không dồn AI call cho từng data point | giới hạn cadence 5 phút và xử lý retry có backoff |
| Audit/storage | DynamoDB audit records | dùng TTL và chỉ store summary |
| Logs | nhiều logs nếu debug không kiểm soát | tóm tắt, redact, levels đúng |

Giải thích thêm:
- So với SQS-trigger hoặc ECS service, current design hạn chế fixed cost và dễ estimate hơn.
- Step Functions sẽ tăng chi phí workflow orchestration không cần thiết.

---

### Ghi chú
File này là tài liệu bổ sung để hiểu template hiện có và dùng làm bản mẫu điền nội dung. Nó không thay đổi file template gốc mà tạo thêm một bản explanation chuyên dụng.
