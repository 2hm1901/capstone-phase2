# [TF4][W11] Thuỷ - Synthetic Workload + Fargate Generator Security

**Người phụ trách:** Thuỷ
**Ngày:** `<YYYY-MM-DD>`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Giải thích ngắn:

- Thuỷ research phần synthetic workload/generator nào?
- Vì sao TF4 cần workload giả thay vì production traffic mirror?
- CDO08 hiện chọn ECS Fargate + generator/k6 như thế nào?
- Security input cho Fargate generator là gì?
- Recommendation cuối: giữ Fargate, đổi pattern, hay cần POC thêm?

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu | Nội dung liên quan | Ý nghĩa thực tế |
|---|---|---|
| TF4 learner brief | Không dùng production traffic mirror; cần 3 service, 4 scenario, test window ≥2 giờ | Phải tự tạo workload/telemetry có ground truth |
| Telemetry Contract | Metric có `tenant_id`, `service_id`, `metric_type`, `ts`, `value`, `labels`; frequency 1 phút | Generator phải emit đúng schema và interval |
| AI API Contract | AI cần `signal_window` ≥120 phút | Generator phải chạy đủ lâu để có dữ liệu 2 giờ |
| Deployment/Security docs | Fargate task không public inbound, không static credential | Generator phải chạy bằng task role, image kiểm soát |
| CDO08 docs 02/03 | Synthetic workload = ECS Fargate task chạy generator/k6 | Validate hoặc đề xuất option tốt hơn |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
ECS Fargate Synthetic Generator
-> API Gateway
-> Lambda Ingest
```

### 3.2 Nó chịu trách nhiệm gì?

- Tạo telemetry/tải giả cho 3 service demo.
- Chạy 4 scenario: gradual drift, sudden spike, slow leak, noisy baseline.
- Ghi rõ start time, breach time, scenario ID để đo lead time.
- Emit payload đúng Telemetry Contract.

### 3.3 Nó không chịu trách nhiệm gì?

- Không dự đoán anomaly.
- Không tự ghi trực tiếp AMP.
- Không dùng production traffic hoặc dữ liệu PII.

---

## 4. Current CDO08 design

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | ECS Fargate task chạy generator/k6 |
| Lý do ban đầu | Chạy được test ≥2 giờ, reproducible, không phụ thuộc laptop |
| Input | Scenario config, service config, emit interval |
| Output | Telemetry event gửi API Gateway |
| Owner/runtime | ECS Fargate |
| Security boundary | Task role chỉ `execute-api:Invoke`; no public inbound; ECR private |
| Observability | ECS logs, task status, emitted count, failed send count |
| Cost driver | Fargate runtime hours, log volume |

---

## 5. Options considered

| Option | Điểm mạnh | Điểm yếu / rủi ro | Khi nào option này hợp lý | Fit với CDO08 |
|---|---|---|---|---|
| Current: ECS Fargate generator/k6 | Chạy dài, reproducible, containerized | Có cost nếu quên stop | Test window ≥2 giờ | High |
| Lambda generator | Rẻ cho burst ngắn | Runtime limit, không hợp ≥2 giờ | Seed data ngắn | Low |
| EC2 generator | Linh hoạt debug | Quản lý server, dễ quên tắt | Tooling đặc biệt | Medium |
| Local script | Nhanh | Evidence yếu, phụ thuộc máy cá nhân | POC ban đầu | Low |

---

## 6. Recommendation

### 6.1 Quyết định cuối

- [ ] Giữ current design.
- [ ] Giữ current design nhưng cần POC trước khi lock.
- [ ] Thay bằng option khác.
- [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên `<giữ/thay/bỏ>` Fargate synthetic generator vì `<3 lý do chính>`.

### 6.2 Lý do quyết định

- **Reliability:** `<generator có chạy đủ 2h, retry gửi telemetry không>`
- **Security:** `<task role, no public inbound, no static credential>`
- **Cost:** `<chạy theo test window, stop/teardown>`
- **Delivery timeline:** `<build/run kịp W12 không>`
- **Evidence:** `<k6 report, ECS task log, scenario timestamps>`

### 6.3 Điều kiện / assumption

- `<Assumption 1>`
- `<Assumption 2>`

---

## 7. Security considerations

| Security area | Decision / requirement |
|---|---|
| IAM least privilege | Generator task role chỉ gọi API Gateway ingest endpoint |
| Network exposure | Không public inbound |
| Secrets | Không dùng static AWS credential; config qua env/SSM nếu cần |
| Encryption at rest | ECR image private; logs CloudWatch mặc định encrypted |
| Encryption in transit | HTTPS tới API Gateway |
| PII/log redaction | Không emit PII; không log secret/header auth |
| Tenant isolation | Payload/header `tenant_id` đúng config demo |

Negative test đề xuất:

- [ ] Generator không thể ghi AMP trực tiếp.
- [ ] Generator không có public inbound port.
- [ ] Static AWS access key không xuất hiện trong task definition/log.

---

## 8. Observability and evidence

### 8.1 Logs cần có

- ECS task start/stop.
- Scenario started/ended.
- Emit success/failure count.

### 8.2 Metrics cần có

| Metric | Vì sao cần | Alert threshold đề xuất |
|---|---|---|
| emitted_events_count | Biết generator có tạo data không | =0 trong test window |
| emit_error_count | Biết API/ingest lỗi | >0 liên tục |
| task_runtime_minutes | Chứng minh chạy ≥2 giờ | <120 phút khi scenario yêu cầu 2 giờ |

### 8.3 W12 evidence cần attach

- [ ] ECS task run log.
- [ ] k6/generator scenario report.
- [ ] Start time/breach time cho 4 scenario.
- [ ] Sample payload đúng contract.
- [ ] Evidence no public inbound/no static credential.

---

## 9. Cost impact

| Cost driver | Estimate / risk | Guardrail |
|---|---|---|
| Compute/runtime | Fargate runtime theo test window | Stop task sau test |
| Requests/messages | 3 services × 7 metrics × 60s | Giữ emit interval 60s |
| Storage/retention | Tạo data cho AMP | Không chạy 24/7 nếu không cần |
| Logs/observability | ECS/CloudWatch logs | Retention 14-30 ngày |
| Fixed cost risk | Không nên tạo service always-on cho generator | Run task on demand |
