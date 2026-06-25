# [TF4][W11] Quyết - Secrets, KMS, IAM Review + Encryption

**Người phụ trách:** Quyết
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Quyết review security baseline nào?
- Những secret/key/data store nào cần bảo vệ?
- Runtime roles nào phải tách biệt?
- CDO08 hiện chọn Secrets Manager + KMS + IAM least privilege.
- Recommendation cuối và rủi ro còn lại.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Audit encrypted at rest, security baseline, no PII | Cần KMS/secret/IAM rõ |
| AI API Contract | IAM SigV4, audit logs retention 3 năm | Không API key AI; audit log encrypted |
| Deployment Contract | ECS Fargate AI Engine, S3 baseline KMS, CloudWatch logs | Engine role/IAM/log retention |
| CDO08 docs 03 | Secrets Manager, KMS, runtime role separation | Review và bổ sung evidence |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
All runtime components
-> IAM roles / Secrets Manager / KMS / CloudWatch / DynamoDB / SQS / AMP
```

### 3.2 Nó chịu trách nhiệm gì?

- Liệt kê secrets/config nhạy cảm.
- Đề xuất KMS/encryption cho data stores.
- Review IAM matrix least privilege.
- Đề xuất no-secret-in-logs và PII reject.
- Đề xuất negative tests cho W12.

### 3.3 Nó không chịu trách nhiệm gì?

- Không tạo admin role dùng chung.
- Không quyết định model logic AI.
- Không cấp broad wildcard permission nếu không có lý do.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | Secrets Manager + KMS + IAM least privilege |
| Lý do ban đầu | Bảo vệ Grafana token, baseline/audit, runtime permissions |
| Input | Component IAM/secrets/encryption needs |
| Output | Security baseline/matrix/recommendation |
| Owner/runtime | Cross-cutting |
| Security boundary | Separate runtime roles, no static credentials |
| Observability | CloudTrail, CloudWatch, denied-action tests |
| Cost driver | Secrets/month, KMS requests, long retention logs |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: Secrets Manager + KMS + IAM roles | Strong baseline, auditable | Some cost/complexity | Current scope | High |
| SSM SecureString | Cheaper/simple | Rotation/lifecycle less specialized | Static config | Medium |
| Plain env vars | Fast | Secret leak risk | Never for secrets | Low |
| AWS-owned keys only | Simple | Less key control/evidence | Non-sensitive stores | Medium |
| CMK everywhere | Strong control | IAM/KMS complexity/cost | Strict compliance | Medium |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` Secrets Manager + KMS + IAM role separation vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<secret retrieval/logging failure handling>`
- **Security:** `<least privilege/encryption/no PII>`
- **Cost:** `<KMS/Secrets/log retention>`
- **Delivery timeline:** `<baseline đủ cho W12>`
- **Evidence:** `<IAM denied tests, KMS config, secret scan>`

### 6.3 Điều kiện / assumption

- AMP default encryption đủ trừ khi mentor yêu cầu CMK.
- AI auth dùng IAM SigV4, không có AI API key.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Separate generator/ingest/writer/prediction/fallback/AI engine/scheduler roles |
| Network exposure | No public inbound except API Gateway ingest |
| Secrets | Grafana token in Secrets Manager; config in SSM/Terraform output |
| Encryption at rest | DynamoDB SSE-KMS; SQS SSE; S3 baseline KMS; CloudWatch audit KMS |
| Encryption in transit | HTTPS/TLS/SigV4 |
| PII/log redaction | Whitelist telemetry schema; redact auth/body |
| Tenant isolation | Enforce `tenant_id` in schema/header/query |

Negative test đề xuất:

- [ ] Runtime role không có `iam:*`.
- [ ] Reviewer không đọc được secret value.
- [ ] Writer không ghi/xóa audit.
- [ ] Prediction không remote-write AMP.
- [ ] PII payload bị reject.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- CloudTrail IAM/KMS/Secrets access.
- Runtime access denied test output.
- Secret scan output.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| secret_retrieval_error | Runtime config issue | >0 |
| kms_access_denied | Wrong key policy/IAM | >0 |
| pii_reject_count | PII policy working / generator issue | spike |
| audit_log_delivery_error | Audit evidence risk | >0 |

### 8.3 W12 evidence cần attach

- [ ] IAM matrix.
- [ ] Denied-action screenshots/logs.
- [ ] KMS/SSE config evidence.
- [ ] Secret scan result.
- [ ] PII reject test.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | None direct | N/A |
| Requests/messages | KMS/Secrets requests | Cache config where safe |
| Storage/retention | CloudWatch AI audit logs 3 years | Log required fields only |
| Logs/observability | CloudTrail/CloudWatch | Retention policy |
| Fixed cost risk | Secrets Manager per secret, CMK monthly cost | Avoid unnecessary secrets/CMKs |
