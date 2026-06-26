# CDO08 - Security Baseline Implementation Summary (by Quyết)

Tài liệu này tổng hợp toàn bộ các nội dung bảo mật đã được triển khai bằng Terraform và kết quả chạy lệnh `terraform plan` sau khi đã tiếp thu ý kiến đóng góp từ quá trình review.

---

## 1. Các hạng mục đã thực hiện

Tôi đã xây dựng module mới **`security_baseline`** tại thư mục [infra/modules/security_baseline](file:///d:/xbrain/capstone-phase2/infra/modules/security_baseline) và tích hợp nó vào môi trường [sandbox](file:///d:/xbrain/capstone-phase2/infra/environments/sandbox/main.tf).

### 1.1. Hạ tầng Mã hóa & Lưu trữ
- **KMS Customer Managed Key (CMK)**:
  - Khởi tạo key `alias/cdo08-sandbox-kms-key` phục vụ mã hóa tại chỗ (at rest) cho DynamoDB audit logs, CloudWatch Log groups và S3 baseline bucket.
  - Thiết lập Key Policy phân quyền chặt chẽ cho tài khoản root, deployer, và cấp quyền cho dịch vụ CloudWatch Logs (`logs.us-east-1.amazonaws.com`) và DynamoDB sử dụng key để thực hiện Encrypt/Decrypt.
- **S3 Baseline Storage**:
  - Tạo bucket `cdo08-sandbox-ai-baselines-894597652722` dùng để lưu trữ baseline phục vụ AI Engine.
  - Bật Block Public Access, Versioning, mã hóa bằng **KMS CMK** (`aws_kms_key.security.arn`) đúng theo yêu cầu của contract.
  - Enforce bắt buộc kết nối qua giao thức HTTPS (TLS-only bucket policy).
- **ECR Repository**:
  - Tạo repo `foresight-lens-engine` chứa Docker image của AI Engine.
  - Bật cấu hình **Image Tag Immutability** để đảm bảo không bị ghi đè phiên bản và tự động quét lỗ hổng (**Scan on Push**).
- **CloudWatch Log Groups**:
  - `/ecs/cdo08-sandbox-ai-engine-app`: Lưu logs vận hành của AI Engine (Retention: 14 ngày).
  - `/ecs/cdo08-sandbox-ai-engine-audit`: Lưu logs audit các lượt predict của AI Engine (Retention: 365 ngày, bắt buộc mã hóa bằng KMS CMK ở trên).

### 1.2. Quản lý Secrets & SSM Parameters
- **Secrets Manager**:
  - Chỉ tạo container secret cho `grafana-token`. **Không tạo version (`aws_secretsmanager_secret_version`) thông qua Terraform** để tránh lưu trữ giá trị secret trong tệp tin state.
  - Đặt cấu hình `recovery_window_in_days = 0` (force delete) để dễ dàng dọn dẹp và test trong môi trường sandbox.
  - Quyết định thiết kế: Không tạo secret cho `telemetry-ingest-key` vì hệ thống ưu tiên sử dụng IAM authorization cho ingest endpoint nhằm đảm bảo an ninh tối đa.
- **SSM Parameters**:
  - Lưu cấu hình tĩnh không nhạy cảm: `amp/workspace_id`, `ai/endpoint`, `ai/baseline_bucket`, `ai/baseline_prefix`, `ai/otel_endpoint`.
  - **Quy định Ownership**: Module `security_baseline` là **Owner chính thức** của namespace cấu hình này (được khởi tạo với giá trị placeholder). Các module khác (ví dụ: Lambda của Nam/Nhân) sẽ đóng vai trò **Consumer** (đọc giá trị cấu hình qua parameter store hoặc output từ module này) và chỉ thực hiện cập nhật giá trị runtime thông qua outputs/parameters mà không tự ý khởi tạo/khai báo lại các resource này để tránh xung đột ownership.

### 1.3. Cơ chế phân tách 8 IAM Roles độc lập (Least Privilege)
Tôi đã chia tách và phân quyền riêng biệt cho 8 vai trò runtime trong hệ thống để giảm thiểu phạm vi ảnh hưởng (blast radius) khi có sự cố.

Đặc biệt, **assume role trust policies đã được phân tách rõ rệt**:
- Generator và AI Engine: chỉ tin tưởng (`Service: ecs-tasks.amazonaws.com`).
- Ingest, Writer, Prediction, Fallback: chỉ tin tưởng (`Service: lambda.amazonaws.com`).
- Scheduler: chỉ tin tưởng (`Service: scheduler.amazonaws.com`).
- Reviewer: Trust policy được cấu hình linh động thông qua danh sách IAM ARNs chỉ định sẵn (`reviewer_principal_arns`). **Nếu danh sách này trống (`[]`), vai trò `reviewer` cùng các policy tương ứng sẽ không được khởi tạo** để đảm bảo tuyệt đối không mở trust policy ra toàn bộ account root.

Cụ thể 8 roles:
1. **`generator`**: Chỉ được phép thực hiện `execute-api:Invoke` (chỉ gọi POST gửi dữ liệu lên Ingest API).
2. **`ingest`**: Chỉ được phép gửi message (`sqs:SendMessage`) vào hàng đợi SQS telemetry.
3. **`writer`**: Chỉ có quyền đọc/xóa message trong SQS và thực hiện `aps:RemoteWrite` ghi metric vào Prometheus (AMP).
4. **`prediction`**: Đọc dữ liệu từ AMP, gọi AI Engine (SigV4), ghi log audit vào DynamoDB, và đọc secret Grafana token.
5. **`ai-engine`**: ECS Task role chỉ có quyền đọc file baseline từ S3 bucket và ghi metric/logs. **Không có bất kỳ quyền quản trị hay quyền ghi/xóa dữ liệu nào khác.**
6. **`fallback`**: Có quyền đọc AMP, ghi log audit vào DynamoDB khi xảy ra fail-open và đọc secret Grafana.
7. **`scheduler`**: Chỉ được phép `lambda:InvokeFunction` gọi Prediction Lambda.
8. **`reviewer`**: Cấp cho người đánh giá/quản trị với quyền Read-Only (xem CloudWatch logs/metrics, query DynamoDB audit). Được áp dụng chính sách **Explicit Deny** ngăn chặn việc xem giá trị secrets động (Grafana token) và xóa/sửa dữ liệu logs audit. (Chỉ được tạo khi `reviewer_principal_arns` không rỗng).

---

## 2. Kết quả khi chạy `terraform plan`

Khi chạy lệnh `terraform -chdir=infra/environments/sandbox plan` trên tài khoản `894597652722` (Region: `us-east-1`), Terraform sẽ đề xuất tạo mới **67 tài nguyên** (bao gồm cả các tài nguyên networking chưa được tạo ở vùng này) và cập nhật các Output đầu ra sau:

### 2.1. Danh sách Tài nguyên được tạo mới (41 tài nguyên)
- `aws_kms_key.security` và `aws_kms_alias.security` (KMS CMK).
- `aws_s3_bucket.ai_baselines`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_ownership_controls`, `aws_s3_bucket_server_side_encryption_configuration` (sử dụng khóa KMS CMK), `aws_s3_bucket_versioning` và `aws_s3_bucket_policy` (S3).
- `aws_secretsmanager_secret` cho Grafana token.
- `aws_ssm_parameter` (5 tham số cấu hình hệ thống).
- `aws_cloudwatch_log_group.ai_engine_app` & `aws_cloudwatch_log_group.ai_engine_audit`.
- `aws_ecr_repository.ai_engine`.
- `aws_iam_role` & `aws_iam_role_policy` (8 roles tách biệt kèm theo inline policies gán quyền chi tiết).

### 2.2. Danh sách Outputs xuất ra (Outputs changes)
Sau khi thực hiện `terraform apply`, các Outputs dưới đây sẽ được trả về để các module ứng dụng khác của nhóm consume:

- `kms_key_arn` / `kms_key_id`: Thông tin khóa KMS CMK để mã hóa bảng dữ liệu.
- `baseline_bucket_name` / `baseline_bucket_arn`: Tên bucket baseline (`cdo08-sandbox-ai-baselines-894597652722`).
- `grafana_secret_arn`: ARN của Grafana secret để Lambda lấy token.
- `ai_engine_ecr_repo_url`: URL đẩy docker image của AI Engine.
- `ai_engine_app_log_group_name` / `ai_engine_audit_log_group_name`: Tên các Log Groups cho AI Engine.
- ARNs của 8 IAM Roles độc lập:
  - `generator_role_arn`
  - `ingest_role_arn`
  - `writer_role_arn`
  - `prediction_role_arn`
  - `ai_engine_role_arn`
  - `fallback_role_arn`
  - `scheduler_role_arn`
  - `reviewer_role_arn`
