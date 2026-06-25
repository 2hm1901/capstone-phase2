# [TF4][W11] Thuỷ - Synthetic Workload + Fargate Generator Security

**Người phụ trách:** Thuỷ
**Ngày:** `2026-06-25`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Thuỷ thực hiện research về thành phần Synthetic Workload Generator cho TF4, tập trung vào việc lựa chọn dịch vụ AWS phù hợp để tạo telemetry giả lập phục vụ kiểm thử hệ thống AI anomaly detection.

TF4 yêu cầu sử dụng synthetic workload thay vì production traffic mirror nhằm tránh sử dụng dữ liệu thực, bảo đảm tính tái lập (reproducibility) và cho phép tạo ground truth để đo lead time giữa anomaly và alert.

Sau khi đánh giá nhiều lựa chọn khác nhau, CDO08 hiện lựa chọn Amazon ECS Fargate chạy containerized k6 generator. Generator sẽ chạy dưới dạng ECS Fargate Task để tạo telemetry cho ba service demo (`gateway-api`, `payment-api`, `queue-worker`) theo bốn scenario gồm gradual drift, sudden spike, slow leak và noisy baseline.

Security input cho Fargate generator bao gồm: không có public inbound, sử dụng IAM Task Role thay cho static credential, lưu image trong private ECR repository và áp dụng container hardening controls.

**Recommendation cuối:** CDO08 nên giữ nguyên thiết kế ECS Fargate chạy containerized k6 generator vì giải pháp này đáp ứng đầy đủ các hard requirement của TF4 về runtime, reproducibility, reliability và security mà không cần POC bổ sung trước khi triển khai W12.

---

## 2. Requirement từ đề bài / contract

| Nguồn yêu cầu            | Nội dung liên quan                                                                            | Ý nghĩa thực tế                                     |
| ------------------------ | --------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| TF4 learner brief        | Không dùng production traffic mirror; cần 3 service, 4 scenario, test window ≥2 giờ           | Phải tự tạo workload/telemetry có ground truth      |
| Telemetry Contract       | Metric có `tenant_id`, `service_id`, `metric_type`, `ts`, `value`, `labels`; frequency 1 phút | Generator phải emit đúng schema và interval         |
| AI API Contract          | AI cần `signal_window` ≥120 phút                                                              | Generator phải chạy đủ lâu để có dữ liệu 2 giờ      |
| Deployment/Security docs | Fargate task không public inbound, không static credential                                    | Generator phải chạy bằng task role, image kiểm soát |
| CDO08 docs 02/03         | Synthetic workload = ECS Fargate task chạy generator/k6                                       | Validate hoặc đề xuất option tốt hơn                |

---

## 3. Component/security input này là gì?

### 3.1 Nó nằm ở đâu trong flow?

```text
ECS Fargate Synthetic Generator
        ↓
API Gateway
        ↓
Lambda Ingest
        ↓
Telemetry Pipeline
```

### 3.2 Nó chịu trách nhiệm gì?

* Tạo telemetry và tải giả cho ba service demo.
* Chạy bốn scenario: gradual drift, sudden spike, slow leak và noisy baseline.
* Ghi nhận `test_start_time`, `anomaly_start_time`, `breach_time` và `scenario_id` để đo lead time.
* Emit payload theo đúng Telemetry Contract.
* Gửi telemetry tới API Gateway để tiếp tục xử lý trong pipeline.

### 3.3 Nó không chịu trách nhiệm gì?

* Không thực hiện anomaly detection hoặc forecasting.
* Không ghi trực tiếp vào Amazon Managed Prometheus (AMP).
* Không sử dụng production traffic hoặc dữ liệu PII.
* Không thực hiện business transaction thực tế.

---

## 4. Current CDO08 design

| Item                          | Current design                                                     |
| ----------------------------- | ------------------------------------------------------------------ |
| AWS service/pattern đang chọn | ECS Fargate task chạy generator/k6                                 |
| Lý do ban đầu                 | Chạy được test ≥2 giờ, reproducible, không phụ thuộc laptop        |
| Input                         | Scenario config, service config, emit interval                     |
| Output                        | Telemetry event gửi API Gateway                                    |
| Owner/runtime                 | ECS Fargate                                                        |
| Security boundary             | Task role chỉ `execute-api:Invoke`; no public inbound; ECR private |
| Observability                 | ECS logs, task status, emitted count, failed send count            |
| Cost driver                   | Fargate runtime hours, log volume                                  |

---

## 5. Options considered

| Option                            | Điểm mạnh                             | Điểm yếu / rủi ro                   | Khi nào option này hợp lý | Fit với CDO08 |
| --------------------------------- | ------------------------------------- | ----------------------------------- | ------------------------- | ------------- |
| Current: ECS Fargate generator/k6 | Chạy dài, reproducible, containerized | Có cost nếu quên stop               | Test window ≥2 giờ        | High          |
| Lambda generator                  | Rẻ cho burst ngắn                     | Runtime limit, không hợp ≥2 giờ     | Seed data ngắn            | Low           |
| EC2 generator                     | Linh hoạt debug                       | Quản lý server, dễ quên tắt         | Tooling đặc biệt          | Medium        |
| Local script                      | Nhanh                                 | Evidence yếu, phụ thuộc máy cá nhân | POC ban đầu               | Low           |

---

## 6. Recommendation

### 6.1 Quyết định cuối

* [x] Giữ current design.
* [ ] Giữ current design nhưng cần POC trước khi lock.
* [ ] Thay bằng option khác.
* [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation:**

> CDO08 nên giữ Fargate synthetic generator vì giải pháp này đáp ứng đầy đủ runtime ≥2 giờ, bảo đảm reproducibility và giảm operational overhead so với các lựa chọn khác.

### 6.2 Lý do quyết định

* **Reliability:** ECS Fargate có thể chạy workload liên tục trong toàn bộ test window ≥2 giờ, không phụ thuộc laptop cá nhân và hỗ trợ chạy lại nhiều lần với cùng workload profile.

* **Security:** Generator sử dụng IAM Task Role, không có public inbound, không sử dụng static AWS credential và chỉ được cấp quyền tối thiểu để gọi API Gateway.

* **Cost:** Generator chỉ chạy trong thời gian test và có thể dễ dàng teardown bằng cách stop ECS Task sau khi hoàn thành.

* **Delivery timeline:** Fargate là managed service nên nhóm không cần quản lý server hoặc patch hệ điều hành, phù hợp với timeline W11/W12.

* **Evidence:** ECS logs, k6 report, scenario timestamps và Grafana dashboard có thể được sử dụng làm evidence trong W12.

### 6.3 Điều kiện / assumption

* API Gateway ingest endpoint luôn sẵn sàng để nhận telemetry từ generator.
* Generator chỉ cần gửi telemetry và không yêu cầu quyền truy cập trực tiếp tới datastore hoặc AMP.

---

## 7. Security considerations

| Security area         | Decision / requirement                                                     |
| --------------------- | -------------------------------------------------------------------------- |
| IAM least privilege   | Generator task role chỉ gọi API Gateway ingest endpoint                    |
| Network exposure      | Không public inbound; chạy trong private subnet                            |
| Secrets               | Không dùng static AWS credential; sử dụng Secrets Manager hoặc SSM nếu cần |
| Encryption at rest    | ECR image private; logs CloudWatch mặc định encrypted                      |
| Encryption in transit | HTTPS tới API Gateway                                                      |
| PII/log redaction     | Không emit PII; không log secret/header auth                               |
| Tenant isolation      | Payload/header `tenant_id` đúng config demo                                |

### Negative test đề xuất

* [x] Generator không thể ghi AMP trực tiếp.
* [x] Generator không có public inbound port.
* [x] Static AWS access key không xuất hiện trong task definition hoặc log.

---

## 8. Observability and evidence

### 8.1 Logs cần có

* ECS task start/stop.
* Scenario started/ended.
* Emit success/failure count.

### 8.2 Metrics cần có

| Metric               | Vì sao cần                       | Alert threshold đề xuất              |
| -------------------- | -------------------------------- | ------------------------------------ |
| emitted_events_count | Biết generator có tạo data không | =0 trong test window                 |
| emit_error_count     | Biết API/ingest lỗi              | >0 liên tục                          |
| task_runtime_minutes | Chứng minh chạy ≥2 giờ           | <120 phút khi scenario yêu cầu 2 giờ |

### 8.3 W12 evidence cần attach

* [x] ECS task run log.
* [x] k6/generator scenario report.
* [x] Start time/breach time cho 4 scenario.
* [x] Sample payload đúng contract.
* [x] Evidence no public inbound/no static credential.

---

## 9. Cost impact

| Cost driver        | Estimate / risk                               | Guardrail                     |
| ------------------ | --------------------------------------------- | ----------------------------- |
| Compute/runtime    | Fargate runtime theo test window              | Stop task sau test            |
| Requests/messages  | 3 services × 7 metrics × 60s                  | Giữ emit interval 60s         |
| Storage/retention  | Tạo data cho AMP                              | Không chạy 24/7 nếu không cần |
| Logs/observability | ECS/CloudWatch logs                           | Retention 14-30 ngày          |
| Fixed cost risk    | Không nên tạo service always-on cho generator | Run task on demand            |
