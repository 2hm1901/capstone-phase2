# [TF4][W11] Phương - Telemetry Entry + Buffer/DLQ + Ingress Security

**Người phụ trách:** Nguyễn Thị Tiểu Phương
**Ngày:** 2026-06-25
**Loại task:** Both
**Status:** Final

---

# 1. Executive Summary

Trong TF4, CDO08 chịu trách nhiệm xây dựng telemetry pipeline để thu thập metric hạ tầng trước khi AI Engine thực hiện dự đoán. Phần nghiên cứu của Phương tập trung vào ba thành phần chính:

* **Telemetry Entry:** sử dụng Amazon API Gateway và AWS Lambda Ingest Validation để tiếp nhận telemetry, xác thực dữ liệu và loại bỏ các metric không hợp lệ trước khi đi vào hệ thống.
* **Buffer & DLQ:** sử dụng Amazon SQS Standard Queue và SQS Dead-Letter Queue nhằm đảm bảo telemetry không bị mất khi Writer Lambda hoặc AMP gặp lỗi tạm thời.
* **Ingress Security:** xây dựng lớp bảo vệ cho telemetry pipeline gồm HTTPS, IAM Authentication, throttling, request size limit, validation boundary, SQS encryption và DLQ replay security.

Telemetry phải được kiểm tra trước khi lưu vào AMP nhằm tránh dữ liệu sai, dữ liệu nhầm tenant/service hoặc dữ liệu chứa PII làm bẩn baseline của AI. Đồng thời hệ thống phải có khả năng retry, replay và audit khi xảy ra lỗi.

Sau khi đánh giá các phương án thay thế, CDO08 quyết định tiếp tục sử dụng **Amazon API Gateway + AWS Lambda Ingest + Amazon SQS Standard Queue + SQS Dead-Letter Queue** vì đáp ứng tốt nhất các yêu cầu về reliability, security, data quality, observability và chi phí của TF4.

Rủi ro còn lại là SQS Standard sử dụng cơ chế **At-Least-Once Delivery**, có thể sinh duplicate event. Rủi ro này sẽ được giảm bằng event_id và Writer Lambda được thiết kế theo hướng idempotent.

---

# 2. Requirement từ đề bài / Contract

| Nguồn yêu cầu               | Nội dung liên quan                                                           | Ý nghĩa thực tế                           |
| --------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------- |
| TF4 Learner Brief           | Telemetry 24/7, per-service baseline, không làm bẩn baseline AI              | Metric phải được validate trước khi lưu   |
| Telemetry Contract          | tenant_id, service_id, metric_type, timestamp, value, labels, không chứa PII | Payload sai phải bị reject                |
| CDO08 Infrastructure Design | API Gateway + Lambda Ingest + SQS + DLQ                                      | Kiểm chứng lựa chọn kiến trúc hiện tại    |
| CDO08 Security Design       | IAM Least Privilege, SQS Encryption, DLQ Security                            | Bổ sung security input cho tài liệu chính |

---

# 3. Component / Security Input

## 3.1 Thành phần nằm ở đâu trong hệ thống?

```text
Synthetic Generator / k6
        │
        ▼
API Gateway
        │
        ▼
Lambda Ingest Validation
        │
        ▼
SQS Standard Queue
        │
        ▼
Writer Lambda
        │
        ▼
Amazon Managed Service for Prometheus (AMP)
```

---

## 3.2 Thành phần này chịu trách nhiệm gì?

* Nhận telemetry thông qua HTTPS API.
* Kiểm tra schema telemetry.
* Kiểm tra tenant_id, service_id, metric_type.
* Kiểm tra timestamp.
* Kiểm tra dữ liệu không chứa PII.
* Đưa event hợp lệ vào SQS.
* Buffer telemetry khi Writer Lambda hoặc AMP gặp lỗi.
* Chuyển các message lỗi nhiều lần sang DLQ để điều tra và replay.

---

## 3.3 Thành phần này KHÔNG chịu trách nhiệm

* Không thực hiện anomaly detection.
* Không thực hiện AI prediction.
* Không ghi trực tiếp xuống AMP.
* Không tự sửa hoặc làm sạch metric bất thường.

---

# 4. Current CDO08 Design

| Hạng mục          | Thiết kế hiện tại                                         |
| ----------------- | --------------------------------------------------------- |
| AWS Pattern       | API Gateway + Lambda Ingest + SQS Standard + DLQ          |
| Lý do             | Validation tập trung, retry/replay, telemetry reliability |
| Input             | HTTP Telemetry Payload                                    |
| Output            | Valid Event → SQS, Invalid Event → Reject + Audit         |
| Security Boundary | IAM Authentication, HTTPS, Throttling, Lambda Validation  |
| Observability     | Reject Count, Queue Depth, Queue Age, DLQ Count           |
| Cost Driver       | API Gateway Request, Lambda Invocation, SQS Request       |

---

# 5. Các phương án đã xem xét

| Phương án                                   | Ưu điểm                                        | Nhược điểm                                             | Phù hợp với CDO08 |
| ------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------ | ----------------- |
| API Gateway + Lambda + SQS + DLQ (Hiện tại) | Validation tập trung, retry, replay, audit tốt | Thêm một bước xử lý                                    | Rất phù hợp       |
| ALB + ECS Collector                         | Collector chạy liên tục, dễ custom protocol    | Chi phí cố định, vận hành phức tạp                     | Trung bình        |
| Kinesis Data Streams                        | Throughput rất lớn, streaming realtime         | Producer phụ thuộc Kinesis, quản lý shard, chi phí cao | Overkill cho TF4  |
| Direct Write AMP                            | Đơn giản nhất                                  | Không validation, không buffer, dễ mất metric          | Không phù hợp     |

---

# 6. Recommendation

## 6.1 Quyết định cuối

✅ Giữ nguyên kiến trúc:

**Amazon API Gateway → AWS Lambda Ingest Validation → Amazon SQS Standard Queue → Amazon SQS Dead-Letter Queue**

---

## 6.2 Lý do

### Reliability

* SQS giữ telemetry khi Writer hoặc AMP gặp lỗi.
* Retry tự động.
* DLQ lưu event lỗi để replay.

### Security

* HTTPS.
* IAM Authentication.
* Lambda Validation.
* IAM Least Privilege.
* SQS Encryption.

### Cost

* Managed Services.
* Pay-per-use.
* Phù hợp ngân sách dưới 200 USD/tháng.

### Delivery Timeline

* Không cần quản lý server.
* Triển khai nhanh.
* Phù hợp thời gian capstone.

### Evidence

* Reject invalid payload.
* Queue Metrics.
* DLQ Metrics.
* Replay Evidence.

---

## 6.3 Assumptions

* Synthetic Generator chạy trong AWS.
* AMP là telemetry store chính.
* AI Endpoint tuân thủ Telemetry Contract.

---

# 7. Security Considerations

| Thành phần            | Quyết định                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------- |
| IAM Least Privilege   | Generator chỉ Invoke API Gateway; Ingest Lambda chỉ SendMessage SQS; Writer Lambda ReceiveMessage + Write AMP |
| HTTPS                 | Bắt buộc                                                                                                      |
| Authentication        | IAM Authentication                                                                                            |
| Throttling            | 1000 Request/Second                                                                                           |
| Request Size Limit    | ≤ 256 KB                                                                                                      |
| Encryption At Rest    | SQS SSE-KMS                                                                                                   |
| Encryption In Transit | HTTPS                                                                                                         |
| Tenant Isolation      | Header X-Tenant-Id phải khớp tenant_id trong Payload                                                          |
| PII Policy            | Reject và Audit                                                                                               |

### Negative Test

* Tenant Header ≠ Payload → 403 Forbidden.
* Thiếu metric_type → 400 Bad Request.
* Payload chứa Email → Reject.
* Ingest Lambda không được phép ghi AMP.

---

# 8. Observability và Evidence

## Logs

* Validation Reject Log.
* Lambda Error Log.
* SQS Send Success/Error.
* DLQ Replay Log.

---

## Metrics

| Metric                | Mục đích               | Alert       |
| --------------------- | ---------------------- | ----------- |
| ingest_success_count  | Theo dõi metric hợp lệ | Sudden Drop |
| ingest_reject_count   | Phát hiện payload lỗi  | Spike       |
| Queue Depth           | Phát hiện Writer chậm  | > 10000     |
| Age Of Oldest Message | Metric chờ quá lâu     | > 300s      |
| DLQ Message Count     | Có telemetry lỗi       | > 0         |

---

## W12 Evidence

* Valid Payload đi vào SQS.
* Invalid Payload bị Reject.
* Tenant Mismatch bị Reject.
* PII Payload bị Reject.
* Queue Alarm.
* DLQ Alarm.
* Replay từ DLQ thành công.

---

# 9. Cost Impact

| Thành phần      | Chi phí              | Biện pháp              |
| --------------- | -------------------- | ---------------------- |
| API Gateway     | Tính theo số request | Sampling 60s           |
| Lambda          | Theo số lần Invoke   | Validation nhẹ         |
| SQS             | Theo số message      | Batch Processing       |
| DLQ             | Theo số message lỗi  | Replay sau điều tra    |
| CloudWatch Logs | Theo dung lượng log  | Chỉ log metadata       |
| Fixed Cost      | Không có             | Serverless Pay-per-use |

---

# Kết luận

CDO08 tiếp tục sử dụng **Amazon API Gateway + AWS Lambda Ingest Validation + Amazon SQS Standard Queue + Amazon SQS Dead-Letter Queue** vì đây là giải pháp cân bằng tốt nhất giữa **Telemetry Reliability, Data Quality, Security, Observability và Cost**.

Kiến trúc này giúp:

* Không làm bẩn baseline AI.
* Không mất telemetry khi downstream gặp lỗi.
* Hỗ trợ retry, replay và audit.
* Dễ triển khai, dễ vận hành.
* Phù hợp với phạm vi và ngân sách của TF4 Capstone.
