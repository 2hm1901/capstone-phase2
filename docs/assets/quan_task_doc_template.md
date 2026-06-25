# [TF4][W11] Quân - Dashboard Overlay + Audit Store + Grafana/Audit Security

**Người phụ trách:** Trần Đình Minh Quân
**Ngày:** 2026-06-26
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

- Quân research **Dashboard Overlay** (Amazon Managed Grafana + push-based annotation API) và **Audit Store** (DynamoDB SSE-KMS + TTL), kèm **security input** cho Grafana token và audit access.
- TF4 yêu cầu **annotation thay vì build UI mới** vì client đã có Grafana sẵn (out-of-scope: "Mobile/web UI dashboard mới"); chỉ cần overlay prediction/fallback lên dashboard hiện có.
- Audit cần lưu đủ để **truy vết mỗi prediction call**: prediction_id, tenant/service, outcome, confidence, recommendation reference, fallback status, correlation_id.
- CDO08 chọn **Amazon Managed Grafana + DynamoDB**; telemetry store là **AMP** (Grafana query PromQL từ AMP, fallback reuse metric AMP).
- Security input: Grafana service-account token trong Secrets Manager + KMS, annotation không chứa secret; DynamoDB tách IAM writer/reader, CMK SSE-KMS, chặn cross-service.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Grafana annotation overlay; audit mỗi prediction; encrypted at rest; retention spec'd | Cần dashboard overlay + audit query, mã hóa, TTL rõ |
| AI API Contract | Response có recommendation/confidence/evidence/audit_id | Annotation/audit phải lưu đủ context để dựng + trace |
| CDO08 docs 02 | Dashboard overlay = Managed Grafana; audit store = DynamoDB; telemetry = AMP | Validate lựa chọn; Grafana query AMP bằng PromQL |
| CDO08 docs 03 | Grafana token in Secrets Manager; DynamoDB SSE-KMS/TTL; IAM read/write tách | Security input |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
EventBridge Scheduler
  -> Prediction Lambda -> query AMP (PromQL) -> POST /v1/predict
        -> DynamoDB Audit (success)
        -> Grafana Annotation (kind:prediction)
  AI lỗi/timeout/429/503
  -> Fallback Lambda -> static threshold (reuse metric AMP)
        -> DynamoDB Audit (fallback=true)
        -> Grafana Annotation (kind:fallback)
```

### 3.2 Nó chịu trách nhiệm gì?

- Hiển thị prediction/fallback trên Grafana existing bằng **push-based annotation** (`POST /api/annotations`).
- Lưu audit record cho success / AI error / fallback.
- Cho phép trace theo `correlation_id` / `prediction_id` (GSI).
- Phân biệt AI prediction (amber) vs fallback threshold (đỏ) bằng 2 annotation layer + tag `kind`.

### 3.3 Nó không chịu trách nhiệm gì?

- Không build UI mới.
- Không lưu telemetry time-series chính (đó là AMP).
- Không cho mọi role đọc/xóa audit (không role nào có Scan/Delete).

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | Amazon Managed Grafana + **push-based annotation API**; DynamoDB SSE-KMS/TTL |
| Lý do ban đầu | Khớp requirement Grafana; push demo gọn + control tag/màu/region; DynamoDB query nhanh theo ID/correlation |
| Input | Prediction/fallback result từ Lambda (output AI engine) |
| Output | Grafana annotation + DynamoDB audit record |
| Owner/runtime | Grafana workspace; DynamoDB table; Annotation Publisher (Lambda mỏng) |
| Security boundary | Service-account token (Editor) in Secrets Manager (`cdo08/grafana`) + KMS; IAM writer/reader tách; `LeadingKeys` chặn cross-tenant |
| Observability | annotation success/error; audit write success/error; fallback_annotation_count |
| Cost driver | Grafana per-active-user/workspace (~$18–33/tháng); DynamoDB on-demand writes/storage |

---

## 5. Options considered

### 5.1 Dashboard overlay

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào hợp lý | Fit CDO08 |
|---|---|---|---|---|
| **Current: AMG + push annotation** | Đúng requirement, demo gọn, control tag/màu/region, AWS-native | Couple uptime Grafana; 2 đường ghi; token 30 ngày | Capstone scope | **High** |
| AMG + query-based (đọc audit store) | 1 nguồn, decouple Grafana | Demo kém tức thì, cấu hình field mapping | Production scale | Medium (future) |
| Self-managed Grafana OSS | Full control, $0 license | Ops/HA/backup, 1 task = SPOF, AGPLv3 | Đã có stack sẵn | Low |
| CloudWatch Dashboard only | AWS-native | Không đáp ứng "Grafana overlay" rõ | Internal ops only | Low |
| Grafana Cloud Free | Managed, free ≤3 user | SaaS ngoài AWS, dữ liệu rời boundary | Không phải fintech | Low |

### 5.2 Audit store

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào hợp lý | Fit CDO08 |
|---|---|---|---|---|
| **Current: DynamoDB SSE-KMS + TTL** | Query nhanh theo ID/correlation, serverless, TTL tự dọn | Không hợp báo cáo SQL phức tạp; TTL không xóa đúng giây | Tra 1 prediction | **High** |
| RDS/Aurora audit | SQL/join mạnh | Always-on cost, nhiều ops | Audit reporting phức tạp | Medium |
| S3/CloudWatch-only audit | Rẻ/đơn giản | Query traceability yếu, khó access control | Archive only | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [x] **Giữ current design** (Managed Grafana + push annotation + DynamoDB audit).
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên **giữ** Amazon Managed Grafana + **push-based annotation** + DynamoDB audit vì: (1) đúng requirement Grafana overlay không build UI mới và demo gọn nhất cho panel; (2) DynamoDB serverless query nhanh theo prediction_id/correlation_id, TTL đáp ứng retention; (3) security boundary rõ — token tách khỏi annotation, IAM writer/reader tách, mã hóa CMK auditable. Để dành query-based overlay làm production path (ghi ADR superseded-by candidate).

### 6.2 Lý do quyết định

- **Reliability:** audit ghi cả success/error/fallback; audit-write fail → đánh dấu E2E incomplete, không claim scenario pass; annotation & audit dùng chung `prediction_id` để đối chiếu.
- **Security:** token (Editor) trong Secrets Manager + KMS, publisher chỉ `GetSecretValue` 1 secret; IAM writer (PutItem) / reader (Query+GetItem) tách, không role nào Scan; `LeadingKeys` chặn cross-tenant; DynamoDB CMK SSE-KMS.
- **Cost:** Grafana license-based ~$18–33/tháng (annotation write $0/request, SRE để Viewer); DynamoDB on-demand, 5 phút/cadence.
- **Delivery timeline:** không build UI mới; push `POST` là annotation hiện ngay → ít rủi ro trong 2 tuần.
- **Evidence:** annotation screenshot + DynamoDB audit item + IAM denied test + fallback sample.

### 6.3 Điều kiện / assumption

- Grafana workspace/token sẵn sàng trước W12 demo; dùng service-account token (API key đã bị gỡ ở AMG v12), token max 30 ngày → rotation xóa token cũ.
- Audit schema ≥6 field và có `fallback` flag.
- Grafana query metric từ **AMP** (PromQL); annotation overlay lên panel AMP.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Prediction/Fallback Lambda chỉ `PutItem` audit; reviewer/reader chỉ `Query`+`GetItem`; không role nào `Scan`/`DeleteItem` |
| Network exposure | Grafana managed (HTTPS); DynamoDB qua IAM, không public |
| Secrets | Service-account token (Editor) in Secrets Manager `cdo08/grafana` + KMS; publisher chỉ đọc đúng 1 secret |
| Encryption at rest | DynamoDB SSE-KMS với customer-managed key (CMK, symmetric); CloudWatch encrypted |
| Encryption in transit | HTTPS/TLS mọi API call |
| PII/log redaction | Annotation chỉ chứa reference + recommendation text + evidence link; không token/PII/raw data |
| Tenant isolation | Audit PK `tenant_id#service_id`; condition `dynamodb:LeadingKeys` chặn đọc/ghi chéo tenant |

Negative test đề xuất:

- [ ] Reviewer/reader role không xóa được audit (no Delete).
- [ ] Annotation không chứa token/secret/PII.
- [ ] Cross-service audit query (reader service A đọc partition service B) bị **AccessDenied** (không phải rỗng); `Scan` cũng AccessDenied.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Audit write success/error (structured log + correlation_id).
- Grafana annotation API success/error.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| audit_write_error | Không được silent audit loss | >0 |
| annotation_error | Dashboard mất evidence | >0 sustained (5m) |
| fallback_annotation_count | Phân biệt/đếm fallback | spike vs baseline |

> Custom metric emit bằng **EMF** (tránh cost PutMetricData + gắn `prediction_id` mà không tạo metric series tính tiền).

### 8.3 W12 evidence cần attach

- [ ] Grafana annotation screenshot (prediction amber + fallback đỏ, filter theo `$service`).
- [ ] DynamoDB audit item sample (đủ ≥6 field + `fallback`).
- [ ] IAM denied test (cross-service AccessDenied + CloudTrail event).
- [ ] Fallback audit/annotation sample (cùng `prediction_id`, `fallback=true`).
- [ ] Traceability: 1 `prediction_id` nối telemetry (AMP) → audit (DynamoDB GSI) → annotation (Grafana).

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Không đáng kể (Lambda publisher mỏng) | Serverless, on-demand |
| Requests/messages | DynamoDB write mỗi prediction; annotation write $0/request | 5 phút/cadence; bound field |
| Storage/retention | Audit table TTL 90 ngày; AI audit log nơi khác | TTL + minimal field |
| Logs/observability | Annotation/audit log | Log summary, retention 7–30 ngày |
| Fixed cost risk | Grafana workspace/user (~$18–33/tháng); CMK ~$1/tháng | SRE để Viewer ($5); 1 service account; 1 CMK chung audit+secret; AWS Budgets alarm $40 cho dòng Grafana |
