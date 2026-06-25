# [TF4][W11] Nam - Telemetry Writer + Primary Telemetry Store + AMP Security

**Người phụ trách:** Nam
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Nam research writer và primary telemetry store nào?
- Vì sao Timestream bị loại và AMP được chọn?
- Lambda Writer remote-write AMP có rủi ro/POC gì?
- Security input cho AMP/Writer là gì?
- Recommendation cuối.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Retention telemetry ≥90 ngày, query time-series theo service/metric | Cần TSDB thật, raw S3 không đủ |
| Telemetry Contract | 7 metrics, frequency 1 phút, `metric_type` | Store/query phải theo metric/service |
| AI API Contract | Prediction cần window ≥120 phút | AMP query phải lấy đúng window |
| CDO08 docs 02 | AMP thay Timestream; Writer Lambda remote-write | Validate lựa chọn và POC |
| CDO08 docs 03 | IAM remote-write/query AMP, cardinality guardrail | Security input bắt buộc |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
SQS Queue
-> Lambda Writer
-> AMP
-> Prediction Lambda / Grafana
```

### 3.2 Nó chịu trách nhiệm gì?

- Đọc event hợp lệ từ SQS theo batch.
- Convert JSON telemetry thành Prometheus metric.
- Remote-write vào AMP.
- Đảm bảo retry/partial failure/idempotency.
- Cung cấp PromQL query cho AI/Grafana.

### 3.3 Nó không chịu trách nhiệm gì?

- Không validate business schema chính, vì đã có Ingest.
- Không lưu audit prediction.
- Không dùng `correlation_id` làm AMP label.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | Lambda Writer + Amazon Managed Service for Prometheus |
| Lý do ban đầu | AMP khả dụng, PromQL/Grafana tốt, retention đủ |
| Input | SQS event JSON |
| Output | Prometheus time series trong AMP |
| Owner/runtime | Lambda, AMP |
| Security boundary | Writer role chỉ SQS read + AMP remote-write |
| Observability | writer success/error/duration, queue age, AMP query |
| Cost driver | AMP samples, Lambda duration, label cardinality |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: Lambda Writer + AMP | Serverless, PromQL, Grafana integration | Remote-write encoding/SigV4 cần POC | Scope hiện tại nếu POC pass | High |
| ECS/ADOT writer | Collector chuẩn | Fixed cost/ops | Lambda remote-write fail | Medium |
| Timestream | TSDB managed tốt | Account mới bị chặn | Nếu account có quyền | Low |
| Self-managed Prometheus/InfluxDB | Full control | Ops/backup/HA cao | Team có platform sẵn | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` Lambda Writer + AMP vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<retry/partial failure/backlog>`
- **Security:** `<AMP IAM, SigV4, no high-cardinality labels>`
- **Cost:** `<samples/cardinality/query volume>`
- **Delivery timeline:** `<POC remote-write>`
- **Evidence:** `<AMP query result, Grafana datasource>`

### 6.3 Điều kiện / assumption

- Lambda remote-write AMP POC phải pass.
- Nếu POC fail, fallback là ECS/ADOT writer.

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Writer: SQS read/delete + AMP remote-write only; Prediction: AMP query only |
| Network exposure | AMP managed endpoint; Lambda no public inbound |
| Secrets | Không log credential; AMP auth dùng SigV4/IAM |
| Encryption at rest | AMP default encryption; CMK chỉ nếu mentor yêu cầu |
| Encryption in transit | HTTPS/SigV4 remote-write/query |
| PII/log redaction | Không log raw payload nếu có label nhạy cảm |
| Tenant isolation | `tenant_id`, `service_id` labels ổn định; query builder enforce |

Negative test đề xuất:

- [ ] `correlation_id` không xuất hiện trong AMP label.
- [ ] Writer role không query/delete audit.
- [ ] Prediction role không remote-write AMP.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- Batch receive/write success.
- Remote-write error reason.
- Partial failure retry.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| writer_success_count | Biết writer chạy | sudden drop |
| writer_error_count | AMP/write lỗi | >0 sustained |
| writer_duration | Timeout risk | p95 gần timeout |
| queue_age | Writer lag | high |
| AMP active series/cardinality | Cost/query risk | spike |

### 8.3 W12 evidence cần attach

- [ ] Remote-write POC result.
- [ ] PromQL query lấy 120 phút data.
- [ ] AMP/Grafana datasource screenshot.
- [ ] IAM denied test cho wrong role.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Lambda per batch | Batch size/concurrency |
| Requests/messages | SQS + Lambda invocations | Batch reads |
| Storage/retention | AMP samples/active series | 60s sampling, low-cardinality labels |
| Logs/observability | Writer logs | Log summary not full payload |
| Fixed cost risk | AMP mostly usage-based | Avoid self-managed TSDB |
