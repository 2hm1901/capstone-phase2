# Hướng dẫn chạy & Cung cấp bằng chứng (Evidence) cho Synthetic Generator

Tài liệu này hướng dẫn cách build/push Docker image, lập kế hoạch Terraform, chạy thử nghiệm (smoke test / ECS task), và trích xuất bằng chứng (evidence) để đính kèm vào PR của nhiệm vụ **[TF4][W12]**.

---

## 1. Hướng dẫn Build & Push Image vào ECR

Trước khi chạy generator trên ECS Fargate, bạn cần build Docker image local và push lên AWS ECR Repository đã được tạo sẵn (`cdo08-sandbox-generator`).

Chạy các lệnh sau tại thư mục root của dự án (yêu cầu Docker đang chạy và AWS CLI đã được cấu hình):

```bash
# 1. Đăng nhập vào ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 894597652722.dkr.ecr.us-east-1.amazonaws.com

# 2. Build Docker Image (Chạy tại thư mục root hoặc trỏ vào src/generator)
docker build -t cdo08-sandbox-generator:v1.0 ./src/generator

# 3. Gắn tag cho image khớp với ECR repo
docker tag cdo08-sandbox-generator:v1.0 894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:v1.0

# 4. Push image lên ECR
docker push 894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:v1.0
```

---

## 2. Cấu hình Terraform & Kiểm tra (Plan)

> [!WARNING]  
> Theo quy định của Branch/PR workflow: **KHÔNG** chạy `terraform apply` trực tiếp trên nhánh tính năng (`feature/post-apply-generator-thuy`). Bạn chỉ được chạy plan và validate.

1. Xác nhận biến `generator_image_uri` trong file `infra/environments/sandbox/variables.tf` trỏ đúng về ECR tag vừa push:
   ```hcl
   variable "generator_image_uri" {
     type        = string
     default     = "894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:v1.0"
   }
   ```

2. Kiểm tra định dạng và tính hợp lệ của Terraform:
   ```bash
   # Định dạng code
   terraform -chdir=infra/environments/sandbox fmt -check -recursive
   
   # Xác thực cấu hình
   terraform -chdir=infra/environments/sandbox validate
   ```

3. Xuất file plan để review và làm bằng chứng:
   ```bash
   terraform -chdir=infra/environments/sandbox plan -out=tfplan.binary
   
   # Xuất dạng text để attach vào PR
   terraform -chdir=infra/environments/sandbox show tfplan.binary > tfplan.txt
   ```

---

## 3. Chạy Smoke Test & Kiểm tra E2E Telemetry Ingest

Để kiểm tra đường truyền dữ liệu E2E hoạt động ổn định qua API Gateway -> SQS Queue -> Telemetry Writer -> AMP Workspace:

### Cách 1: Gửi sample event cục bộ (Smoke Test)
Chạy script smoke test trên máy local (nó sẽ tự động lấy API endpoint từ Terraform output và thực hiện SigV4 signing):
```bash
python scripts/smoke-test.py
```
**Kết quả mong đợi:** Nhận được HTTP Status `202` kèm thông tin `accepted`.

### Cách 2: Chạy Task định kỳ trên ECS Fargate
Sau khi PR được merge vào `main` và Terraform apply chạy xong, bạn có thể trigger Fargate task thủ công bằng CLI (qua công cụ `run-scenario.py`):
```bash
# Chạy kịch bản gradual_drift cho payment-api
python scripts/run-scenario.py gradual_drift payment-api
```

---

## 4. Cách lấy bằng chứng (Evidence) để đính kèm vào PR

Jira yêu cầu đính kèm bằng chứng gồm: **log generator + API response + CloudWatch/SQS signal**. Bạn hãy thực hiện các lệnh sau để trích xuất:

### Bằng chứng 1: API Response & Smoke Test Output
Chạy `python scripts/smoke-test.py` và copy toàn bộ output của terminal, ví dụ:
```text
Sending smoke test payload...
HTTP Response Status: 202
HTTP Response Body: {"status": "accepted", "correlation_id": "6ac34466-7a4b-4eb4-9a8b-1288b520615e"}
Smoke test successfully processed!
```

### Bằng chứng 2: Ingest Lambda logs (CloudWatch)
Tìm log stream mới nhất của log group `/aws/lambda/cdo08-sandbox-ingest` và copy dòng log validation pass khớp với `correlation_id` ở trên:
```bash
aws logs describe-log-streams --log-group-name /aws/lambda/cdo08-sandbox-ingest --order-by LastEventTime --descending --max-items 1

# Lấy log events từ stream tìm được (ví dụ stream name là '2026/06/29/[$LATEST]0456...')
aws logs get-log-events --log-group-name /aws/lambda/cdo08-sandbox-ingest --log-stream-name '2026/06/29/[$LATEST]0456d6ed8a4a42c2a2112b471e504366'
```
**Nội dung log cần chụp:**
`{"event": "telemetry_validation_passed", "correlation_id": "6ac34466-7a4b-4eb4-9a8b-1288b520615e", ...}`

### Bằng chứng 3: Telemetry Writer logs (AMP remote-write success)
Lấy log events từ log group `/aws/lambda/cdo08-sandbox-telemetry-writer` để chứng minh message được remote-write thành công vào AMP:
```bash
aws logs describe-log-streams --log-group-name /aws/lambda/cdo08-sandbox-telemetry-writer --order-by LastEventTime --descending --max-items 1

aws logs get-log-events --log-group-name /aws/lambda/cdo08-sandbox-telemetry-writer --log-stream-name '2026/06/29/[$LATEST]172de9f5637045e6a9b8b4df1a936cd5'
```
**Nội dung log cần chụp:**
`{"amp_workspace_id": "ws-eb0a1...", "batch_size": 1, "event": "batch_processed", "remote_write_status": "success"}`
