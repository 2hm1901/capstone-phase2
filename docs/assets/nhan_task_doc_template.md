# [TF4][W11] Nhân - AI Integration Adapter + Fail-open + Scheduler Security

**Người phụ trách:** Nhân
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Nhân research Prediction Lambda/AI adapter và fail-open fallback nào?
- Vì sao không gọi AI theo từng data point?
- Error 400/401/429/503 xử lý thế nào?
- Khi AI down, static threshold fallback hoạt động ra sao?
- Security input cho Scheduler/Prediction/Fallback là gì?

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Lead time ≥15 phút; fail-open khi AI down | Prediction phải định kỳ và có fallback |
| AI API Contract | `POST /v1/predict`, window ≥120 phút, 400/401/429/503 | Adapter phải map request/error đúng |
| Deployment Contract | AI Engine CDO08 host, SigV4, rate limit | Adapter gọi endpoint nội bộ an toàn |
| CDO08 docs 02 | EventBridge Scheduler mỗi 5 phút; Prediction Lambda; Fallback Lambda | Validate lựa chọn |
| CDO08 docs 03 | IAM boundary, idempotency, no Scheduler DLQ | Security input |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
EventBridge Scheduler
-> Prediction Lambda
-> AMP query
-> AI Engine /v1/predict
-> DynamoDB audit + Grafana annotation
     \
      -> Fallback Lambda nếu AI lỗi
```

### 3.2 Nó chịu trách nhiệm gì?

- Trigger prediction theo lịch.
- Query AMP window ≥120 phút.
- Build `signal_window` đúng contract.
- Gọi AI Engine và xử lý retry/error.
- Kích hoạt fail-open static threshold khi AI lỗi.
- Ghi audit/annotation, tránh duplicate.

### 3.3 Nó không chịu trách nhiệm gì?

- Không train model.
- Không auto-remediation.
- Không thay thế AI bằng fallback trong normal path.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | EventBridge Scheduler + Prediction Lambda + Fallback Lambda |
| Lý do ban đầu | Tách prediction cadence khỏi telemetry ingest; fail-open rõ |
| Input | Schedule payload, AMP metric window |
| Output | AI/fallback result, audit, Grafana annotation |
| Owner/runtime | Lambda + EventBridge |
| Security boundary | Scheduler role only invoke Prediction; Prediction role limited AMP/AI/audit |
| Observability | AI latency/error, fallback rate, scheduler invoke failure |
| Cost driver | Prediction interval, AMP query, Lambda invocation |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: Scheduler + Lambda adapter/fallback | Simple, bounded, mockable | Cold start, concurrency cap needed | Current scope | High |
| SQS-trigger prediction | Near real-time | Too many AI calls, duplicates | Very low volume only | Low |
| ECS integration service | Connection pooling | Fixed cost | High QPS/streaming | Medium |
| Step Functions | Visible workflow | Heavy/latency/cost | Multi-step approval | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` Scheduler + Prediction Lambda + Fallback Lambda vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<bounded retry/fallback>`
- **Security:** `<SigV4/IAM/tenant validation>`
- **Cost:** `<5 phút cadence, không gọi từng data point>`
- **Delivery timeline:** `<W11 mock, W12 real engine>`
- **Evidence:** `<success/fallback audit + annotation>`

### 6.3 Điều kiện / assumption

- EventBridge không dùng DLQ riêng; CloudWatch alarm đủ cho scheduler invoke failure.
- Fallback threshold config có owner và version.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Scheduler only invoke Prediction; Prediction only AMP query/call AI/write audit |
| Network exposure | Prediction calls internal AI endpoint |
| Secrets | Grafana token via Secrets Manager; no AI API key |
| Encryption at rest | Audit in DynamoDB/KMS; logs encrypted |
| Encryption in transit | HTTPS/SigV4 to AI Engine |
| PII/log redaction | Không log full `signal_window` |
| Tenant isolation | `X-Tenant-Id` match `signal_window[].tenant_id` |

Negative test đề xuất:

- [ ] AI 503 tạo fallback audit.
- [ ] 400 không retry mù.
- [ ] Duplicate scheduler invoke không tạo duplicate annotation.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Schedule payload summary.
- AMP query duration/hash.
- AI status/latency/error.
- Fallback activation reason.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| prediction_success_count | Normal path healthy | sudden drop |
| ai_error_count | AI dependency issue | sustained >0 |
| fallback_count | Fail-open activated | spike |
| prediction_duration | Lead time/latency risk | p95 high |
| scheduler_invoke_failure | Scheduler permission/target issue | >0 |

### 8.3 W12 evidence cần attach

- [ ] AI success response audit.
- [ ] 429/503 fallback test.
- [ ] Grafana fallback annotation.
- [ ] Idempotency/duplicate test.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Lambda invocations every 5 min/service | Keep cadence 5 min |
| Requests/messages | AI calls + AMP query | Do not trigger per data point |
| Storage/retention | DynamoDB audit records | TTL |
| Logs/observability | Prediction/fallback logs | Redact and summarize |
| Fixed cost risk | AI Engine ECS/ALB handled separately | Cap concurrency/retry |
