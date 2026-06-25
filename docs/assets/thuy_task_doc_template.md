# [TF4][W11] Thuỷ - Synthetic Workload + Fargate Generator Security

**Người phụ trách:** Thuỷ
**Ngày:** `2026-06-25`
**Loại task:** `Both`
**Status:** `Final`

---

## 1. Executive summary

Trong TF4, hệ thống cần một nguồn dữ liệu giả lập để tạo telemetry phục vụ cho việc huấn luyện và đánh giá khả năng phát hiện bất thường của AI. Đề bài không cho phép sử dụng production traffic mirror nên nhóm phải tự xây dựng một synthetic workload generator.

Thuỷ thực hiện research cho thành phần Synthetic Workload và Fargate Generator Security nhằm trả lời hai câu hỏi chính:

1. Dùng dịch vụ AWS nào để tạo workload giả lập đáp ứng yêu cầu của TF4.
2. Cần áp dụng những biện pháp bảo mật nào để generator không trở thành điểm yếu của hệ thống.

Sau khi đánh giá nhiều lựa chọn như AWS Lambda, EC2 và local script, CDO08 quyết định sử dụng Amazon ECS Fargate chạy containerized k6 generator.

Trong thiết kế này, k6 được đóng gói thành container và chạy trên ECS Fargate để sinh telemetry cho ba service demo gồm `gateway-api`, `payment-api` và `queue-worker`. Workload sẽ mô phỏng bốn hành vi hệ thống gồm gradual drift, sudden spike, slow leak và noisy baseline.

Nhóm lựa chọn ECS Fargate vì đây là giải pháp cân bằng nhất giữa khả năng chạy dài (≥ 2 giờ), tính tái lập, độ tin cậy, chi phí và mức độ vận hành đơn giản trong phạm vi capstone.

Về bảo mật, generator được triển khai trong private subnet, không có public inbound, sử dụng IAM Task Role thay cho static credential, lưu image trong private Amazon ECR và áp dụng các container hardening controls như non-root container và resource limits.

Recommendation cuối cùng là giữ nguyên kiến trúc ECS Fargate + k6 generator vì giải pháp hiện tại đáp ứng đầy đủ các yêu cầu chức năng và bảo mật của TF4, đồng thời phù hợp với timeline W11/W12.


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

| Item | Current design |
|---|---|
| AWS service/pattern đang chọn | ECS Fargate task chạy containerized k6 generator |
| Lý do ban đầu | Chạy workload liên tục ≥2 giờ, bảo đảm reproducibility và không phụ thuộc laptop cá nhân |
| Input | Scenario configuration, service configuration, workload profile và emit interval |
| Output | Telemetry events gửi tới API Gateway |
| Owner/runtime | ECS Fargate |
| Security boundary | IAM Task Role chỉ có quyền `execute-api:Invoke`; task chạy trong private subnet, không có public inbound và container image được lưu trong private ECR |
| Observability | ECS task logs, task status, emitted event count và failed send count |
| Cost driver | ECS Fargate runtime (CPU, memory, runtime hours) và CloudWatch log volume |

---

## 5. Options considered

| Option                   | Điểm mạnh                                                                                             | Điểm yếu / rủi ro                                                               | Khi nào option này hợp lý                          | Fit với CDO08 |
| ------------------------ | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------- | ------------- |
| ECS Fargate generator/k6 | Chạy workload liên tục nhiều giờ, reproducible, không phụ thuộc máy cá nhân, không cần quản lý server | Có chi phí runtime nếu quên dừng task                                           | Hệ thống cần chạy test dài và cần khả năng tái lập | High          |
| Lambda generator         | Hoàn toàn serverless, chi phí thấp cho workload ngắn                                                  | Runtime bị giới hạn, khó duy trì state lâu dài, khó mô phỏng drift/leak kéo dài | Seed data hoặc workload ngắn                       | Low           |
| EC2 generator            | Toàn quyền cấu hình môi trường, dễ debug                                                              | Phải quản lý server, patch OS, dễ quên terminate gây phát sinh chi phí          | Workload đặc biệt cần cài đặt tùy chỉnh sâu        | Medium        |
| Local script             | Thiết lập nhanh, không phát sinh chi phí AWS                                                          | Phụ thuộc laptop cá nhân, dễ bị gián đoạn, khó tái lập và evidence yếu          | Chỉ phù hợp để POC ban đầu                         | Low           |

**Tại sao CDO08 không chọn Lambda?**

Mặc dù Lambda có ưu điểm về chi phí và tính serverless, workload của TF4 cần chạy liên tục tối thiểu 2 giờ để tạo đủ telemetry cho AI. Ngoài ra, các scenario như gradual drift và slow leak yêu cầu trạng thái được duy trì trong thời gian dài. Vì vậy Lambda không phù hợp.

**Tại sao không chọn EC2?**

EC2 có thể chạy workload dài nhưng nhóm sẽ phải tự quản lý máy chủ, cập nhật hệ điều hành và theo dõi việc tắt máy sau khi test. Điều này làm tăng operational overhead trong khi thời gian capstone khá ngắn.

**Tại sao không chạy trên laptop?**

Generator chạy trên laptop sẽ phụ thuộc vào kết nối mạng và trạng thái máy của từng thành viên. Nếu máy tắt hoặc mất mạng, telemetry sẽ bị gián đoạn, dẫn tới kết quả test không ổn định và khó tái lập.

Do đó, ECS Fargate được đánh giá là lựa chọn phù hợp nhất cho CDO08.


## 6. Recommendation

### 6.1 Quyết định cuối

* [x] Giữ current design.
* [ ] Giữ current design nhưng cần POC trước khi lock.
* [ ] Thay bằng option khác.
* [ ] Bỏ component riêng, thay bằng pattern khác.

**Recommendation**

CDO08 nên giữ kiến trúc ECS Fargate chạy containerized k6 generator.

Giải pháp này được lựa chọn vì ba lý do chính:

1. **Đáp ứng đầy đủ requirement của TF4**: workload có thể chạy liên tục trên 2 giờ, hỗ trợ nhiều scenario và tạo ground truth để đo lead time.

2. **Bảo đảm reliability và reproducibility**: workload được đóng gói trong container nên mọi thành viên và mentor đều có thể chạy lại cùng một kịch bản và nhận được kết quả tương tự.

3. **Giảm operational overhead**: nhóm không cần quản lý máy chủ, patch hệ điều hành hoặc phụ thuộc vào laptop cá nhân, từ đó tập trung nhiều hơn vào việc xây dựng telemetry pipeline và AI component.

### 6.2 Lý do quyết định

* **Reliability:** ECS Fargate chạy độc lập trên AWS, không phụ thuộc môi trường cá nhân và có thể chạy ổn định trong toàn bộ test window ≥2 giờ.

* **Security:** Generator sử dụng IAM Task Role, không có public inbound, không dùng static credential, image được lưu trong private ECR và chỉ deploy image đã được scan.

* **Cost:** Chi phí chủ yếu phát sinh theo thời gian chạy task. Vì generator chỉ chạy theo test window và được stop ngay sau khi test nên chi phí vẫn nằm trong ngân sách capstone.

* **Delivery timeline:** ECS Fargate là managed service nên nhóm có thể triển khai nhanh trong W11/W12 mà không phải dành thời gian quản trị hạ tầng.

* **Evidence:** Hệ thống có thể cung cấp đầy đủ bằng chứng cho W12 như ECS task log, k6 report, scenario timestamp và dashboard screenshot.

### 6.3 Điều kiện / assumption

* API Gateway ingest endpoint luôn sẵn sàng để nhận telemetry.
* Generator chỉ cần gửi telemetry và không cần quyền truy cập trực tiếp vào AMP hoặc datastore.
* Mỗi workload run sẽ ghi lại start time và breach time để phục vụ đo lead time.

## 7. Security considerations

| Security area            | Decision / requirement                                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| IAM least privilege      | Generator sử dụng IAM Task Role và chỉ được cấp quyền tối thiểu để gọi API Gateway ingest endpoint (`execute-api:Invoke`) |
| Network exposure         | ECS Fargate task chạy trong private subnet, không gán Public IP và không có public inbound                                |
| Container image security | Container image được lưu trong private Amazon ECR và chỉ deploy image đã được scan                                        |
| Image integrity          | Bật Image Tag Immutability và ưu tiên deploy bằng image digest (`sha256`) để tránh deploy nhầm image                      |
| Secrets                  | Không sử dụng static AWS credential; sử dụng AWS Secrets Manager hoặc ECS Secret Injection nếu cần                        |
| Encryption at rest       | Private ECR repository và CloudWatch Logs được mã hóa mặc định                                                            |
| Encryption in transit    | Telemetry được gửi tới API Gateway thông qua HTTPS                                                                        |
| Container hardening      | Container chạy bằng non-root user và thiết lập CPU/Memory limits để giảm blast radius                                     |
| PII/log redaction        | Không emit PII và không ghi log chứa secret hoặc authentication header                                                    |
| Tenant isolation         | Payload và header phải chứa `tenant_id` đúng theo cấu hình demo                                                           |

### Negative test đề xuất

* [x] Generator không thể ghi trực tiếp vào AMP hoặc datastore.
* [x] Generator không có public inbound port (kết quả mong đợi: không thể truy cập từ Internet).
* [x] Không tìm thấy `AWS_ACCESS_KEY_ID` hoặc `AWS_SECRET_ACCESS_KEY` trong source code, task definition hoặc log.
* [x] Kiểm tra ECS Task đang sử dụng IAM Task Role thay vì static credential.

## 8. Observability and evidence

### 8.1 Logs cần có

* ECS task start/stop log.
* Scenario started/ended log.
* Emit success/failure count.
* API invoke error log (nếu có).

### 8.2 Metrics cần có

| Metric               | Vì sao cần                                    | Alert threshold đề xuất              |
| -------------------- | --------------------------------------------- | ------------------------------------ |
| emitted_events_count | Xác nhận generator đang tạo telemetry         | =0 trong test window                 |
| emit_error_count     | Phát hiện lỗi khi gửi telemetry               | >0 liên tục                          |
| task_runtime_minutes | Chứng minh workload chạy đủ thời gian yêu cầu | <120 phút khi scenario yêu cầu 2 giờ |
| failed_send_count    | Theo dõi số lần gửi telemetry thất bại        | >5 lần liên tiếp                     |

### 8.3 W12 evidence cần attach

* [x] ECS task run log.
* [x] k6/generator scenario report.
* [x] Start time, anomaly start time và breach time của 4 scenario.
* [x] Sample telemetry payload đúng Telemetry Contract.
* [x] Screenshot hoặc evidence chứng minh không có public inbound.
* [x] Evidence chứng minh không sử dụng static AWS credential.
* [x] Screenshot ECS Task sử dụng IAM Task Role.


---

## 9. Cost impact

| Cost driver        | Estimate / risk                                                          | Guardrail                                                            |
| ------------------ | ------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| Compute/runtime    | Chi phí phụ thuộc vào số vCPU, memory và thời gian chạy ECS Fargate task | Chỉ chạy generator trong test window và stop task sau khi hoàn thành |
| Requests/messages  | Khoảng 3 services × 7 metrics × mỗi 60 giây                              | Giữ emit interval cố định 60 giây                                    |
| Storage/retention  | Telemetry và metric được lưu phục vụ AI analysis                         | Không chạy workload 24/7 nếu không cần                               |
| Logs/observability | CloudWatch Logs có thể phát sinh chi phí theo dung lượng log             | Thiết lập log retention từ 14–30 ngày                                |
| Fixed cost risk    | Nếu generator chạy liên tục sẽ làm tăng chi phí Fargate                  | Chạy task theo nhu cầu (run task on demand)                          |

