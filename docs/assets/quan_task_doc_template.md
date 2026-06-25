# [TF4][W11] Quân - Dashboard Overlay + Audit Store + Grafana/Audit Security

**Người phụ trách:** Quân
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Quân research Grafana overlay và audit store nào?
- Vì sao TF4 yêu cầu annotation thay vì build UI mới?
- Audit cần lưu gì để truy vết prediction/fallback?
- CDO08 hiện chọn Amazon Managed Grafana + DynamoDB.
- Security input cho Grafana token và audit access là gì?

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Grafana annotation overlay; audit mỗi prediction; encrypted at rest | Cần dashboard + audit query |
| AI API Contract | Response có recommendation/confidence/evidence/audit_id | Annotation/audit phải lưu đủ context |
| CDO08 docs 02 | Dashboard overlay = Managed Grafana; audit store = DynamoDB | Validate lựa chọn |
| CDO08 docs 03 | Grafana token in Secrets Manager; DynamoDB SSE-KMS/TTL | Security input |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
Prediction/Fallback Lambda
-> DynamoDB Audit
-> Grafana Annotation
```

### 3.2 Nó chịu trách nhiệm gì?

- Hiển thị prediction/fallback trên Grafana.
- Lưu audit record cho success/error/fallback.
- Cho phép trace theo correlation/prediction ID.
- Phân biệt AI prediction và fallback threshold.

### 3.3 Nó không chịu trách nhiệm gì?

- Không build UI mới.
- Không lưu telemetry time-series chính.
- Không cho mọi role đọc/xóa audit.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | Amazon Managed Grafana + DynamoDB SSE-KMS/TTL |
| Lý do ban đầu | Khớp requirement Grafana; DynamoDB query nhanh theo ID/service |
| Input | Prediction/fallback result |
| Output | Annotation + audit record |
| Owner/runtime | Grafana workspace, DynamoDB |
| Security boundary | Grafana token in Secrets Manager; IAM read/write separated |
| Observability | annotation success/error, audit write success/error |
| Cost driver | Grafana user/workspace, DynamoDB writes/storage |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: Managed Grafana + DynamoDB | Fits requirement, serverless audit | Grafana token/cost | Current scope | High |
| Self-managed Grafana | Full control | Ops/persistent state | Existing stack | Low |
| CloudWatch Dashboard only | AWS-native | Không đáp ứng Grafana overlay rõ | Internal ops only | Low |
| RDS/Aurora audit | SQL reporting | Always-on cost | Complex audit reporting | Medium |
| S3/CloudWatch-only audit | Cheap/simple | Query traceability yếu | Archive only | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` Managed Grafana + DynamoDB audit vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<audit/annotation failure handling>`
- **Security:** `<token/IAM/KMS>`
- **Cost:** `<Grafana users, DynamoDB on-demand>`
- **Delivery timeline:** `<không build UI mới>`
- **Evidence:** `<annotation screenshot, audit query>`

### 6.3 Điều kiện / assumption

- Grafana workspace/token sẵn sàng trước W12 demo.
- Audit schema >=6 fields và có `fallback` flag.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Prediction/Fallback write audit; reviewer read-only |
| Network exposure | Grafana managed; DynamoDB via IAM |
| Secrets | Grafana token in Secrets Manager |
| Encryption at rest | DynamoDB SSE-KMS, CloudWatch encrypted |
| Encryption in transit | HTTPS API calls |
| PII/log redaction | Annotation không chứa secret/PII |
| Tenant isolation | Audit partition/query by `tenant_id#service_id` |

Negative test đề xuất:

- [ ] Reviewer role không xóa audit.
- [ ] Annotation không chứa token/secret.
- [ ] Cross-service audit query bị deny hoặc không trả dữ liệu ngoài scope.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Audit write success/error.
- Grafana annotation API success/error.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| audit_write_error | Không được silent audit loss | >0 |
| annotation_error | Dashboard mất evidence | >0 sustained |
| fallback_annotation_count | Phân biệt fallback | spike |

### 8.3 W12 evidence cần attach

- [ ] Grafana annotation screenshot.
- [ ] DynamoDB audit item sample.
- [ ] IAM denied test.
- [ ] Fallback audit/annotation sample.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | None significant | Serverless/managed |
| Requests/messages | DynamoDB writes per prediction | 5 min cadence |
| Storage/retention | Audit table TTL; AI audit logs elsewhere | TTL and minimal fields |
| Logs/observability | Annotation/audit logs | Log summary |
| Fixed cost risk | Grafana workspace/users | Minimize users/service accounts |
