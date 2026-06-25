# [TF4][W11] Phương - Telemetry Entry + Buffer/DLQ + Ingress Security

**Người phụ trách:** Phương
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Phương research telemetry entry, SQS buffer/DLQ và security boundary nào?
- Vì sao cần chặn schema sai/PII trước khi metric vào AMP?
- Vì sao cần buffer để tránh mất telemetry khi writer/store lỗi?
- CDO08 hiện chọn API Gateway + Lambda Ingest + SQS Standard + DLQ.
- Recommendation cuối và rủi ro còn lại.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Telemetry 24/7, per-service baseline, không làm bẩn baseline | Phải validate trước storage |
| Telemetry Contract | `tenant_id`, `service_id`, `metric_type`, `ts`, `value`, `labels`, no PII | Ingest phải reject payload sai |
| CDO08 docs 02 | Telemetry entry = API Gateway + Lambda; buffer = SQS + DLQ | Validate lựa chọn hiện tại |
| CDO08 docs 03 | IAM least privilege, SQS encryption, DLQ/replay security | Cần security input cho PM |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
Fargate Generator
-> API Gateway
-> Lambda Ingest
-> SQS Queue
-> Lambda Writer
```

### 3.2 Nó chịu trách nhiệm gì?

- Nhận telemetry qua HTTPS.
- Validate schema/header/tenant/timestamp/PII.
- Đưa event hợp lệ vào SQS.
- Giữ event tạm thời khi writer/AMP chậm.
- Đưa poison event vào DLQ để điều tra/replay.

### 3.3 Nó không chịu trách nhiệm gì?

- Không dự đoán anomaly.
- Không ghi trực tiếp AMP.
- Không sửa metric bất thường thành “đẹp hơn”.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | API Gateway + Lambda Ingest + SQS Standard + DLQ |
| Lý do ban đầu | Có validation boundary, retry/replay, evidence telemetry reliability |
| Input | Telemetry HTTP payload |
| Output | Valid event vào SQS; invalid event reject/log |
| Owner/runtime | API Gateway, Lambda, SQS |
| Security boundary | IAM auth/throttling; ingest role chỉ `sqs:SendMessage` |
| Observability | reject count, send success/error, queue age, DLQ depth |
| Cost driver | API requests, Lambda invocations, SQS requests |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: API Gateway + Lambda + SQS/DLQ | Validation rõ, serverless, retry/replay | Thêm hops, at-least-once | Scope hiện tại | High |
| ALB + ECS collector | Long-running, custom protocol | Fixed cost, ops nhiều | Ingest persistent connections | Medium |
| Kinesis Data Streams | Streaming throughput/ordering tốt | Shard/cost/ops phức tạp | Throughput rất cao | Medium |
| Direct write to AMP | Đơn giản | Mất validation/buffer boundary | Demo tối giản | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` API Gateway + Lambda Ingest + SQS/DLQ vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<SQS/DLQ tránh mất event thế nào>`
- **Security:** `<auth, validation, IAM>`
- **Cost:** `<request/message volume>`
- **Delivery timeline:** `<serverless nhanh triển khai>`
- **Evidence:** `<invalid reject, DLQ, replay>`

### 6.3 Điều kiện / assumption

- `<Assumption 1>`
- `<Assumption 2>`

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Generator only invoke API; Ingest only SendMessage SQS |
| Network exposure | API Gateway public HTTPS; Lambda/SQS not public |
| Secrets | Prefer IAM auth; HMAC/API key chỉ nếu contract cần |
| Encryption at rest | SQS SSE enabled |
| Encryption in transit | HTTPS to API Gateway |
| PII/log redaction | Reject PII field; log metadata only |
| Tenant isolation | `X-Tenant-Id` phải match payload `tenant_id` |

Negative test đề xuất:

- [ ] Header/payload tenant mismatch bị reject.
- [ ] Payload thiếu `metric_type` bị reject.
- [ ] Ingest role không có quyền đọc secret hoặc ghi AMP.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Validation reject reason.
- SQS send success/error.
- DLQ movement/replay note.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| ingest_success_count | Biết event hợp lệ vào queue | sudden drop |
| ingest_reject_count | Phát hiện schema/generator lỗi | spike |
| queue_age | Writer chậm/store lỗi | > configured threshold |
| DLQ_visible_messages | Poison event/retry exhausted | >0 |

### 8.3 W12 evidence cần attach

- [ ] Valid payload đi vào SQS.
- [ ] Invalid payload bị reject.
- [ ] SQS/DLQ config screenshot/Terraform.
- [ ] Replay/security note cho DLQ.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Lambda per request | Keep payload small |
| Requests/messages | API Gateway + SQS per telemetry event | 60s sampling |
| Storage/retention | SQS retention/DLQ | Retention vừa đủ demo |
| Logs/observability | Reject logs có thể tăng | Log metadata, not body |
| Fixed cost risk | Không có fixed compute lớn | Serverless pay-per-use |
