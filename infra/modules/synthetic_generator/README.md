# Module: synthetic_generator

**Owner:** Thuy (CDO08)  
**Branch:** `feature/terraform-synthetic-generator-thuy`

## Mục đích

Module này triển khai Synthetic Workload Generator trên ECS Fargate. Generator tạo telemetry demo cho 3 service (`payment-api`, `queue-worker`, `gateway-api`) và 4 scenario: `gradual_drift`, `sudden_spike`, `slow_leak`, `noisy_baseline`.

Telemetry được gửi tới Telemetry Entry (module của Phương) theo schema trong `contracts/telemetry-contract.md`.

## Tài nguyên được tạo

| Resource | Tên | Ghi chú |
|---|---|---|
| ECR repository | `cdo08-sandbox-generator` | Lưu generator image, scan on push, immutable tags |
| ECS cluster | `cdo08-sandbox-generator-cluster` | Dedicated cluster, FARGATE capacity provider |
| ECS task definition | `cdo08-sandbox-generator` | Fargate, awsvpc, non-root, no inbound port |
| IAM task execution role | `cdo08-sandbox-generator-execution-role` | ECR pull + CW Logs write |
| IAM task role | `cdo08-sandbox-generator-task-role` | `execute-api:Invoke` trên telemetry ingest only — **không có quyền AMP write** |
| IAM EventBridge role | `cdo08-sandbox-generator-events-role` | Chỉ `ecs:RunTask` + `iam:PassRole` cho cluster này |
| CloudWatch log group | `/ecs/cdo08-sandbox-generator` | Retention 14 ngày (configurable) |
| EventBridge rule | `cdo08-sandbox-generator-schedule` | **DISABLED by default** — chỉ bật khi cần test window |

## Tài nguyên KHÔNG tạo ở đây

- VPC / subnet / security group → `module.networking`
- API Gateway / SQS / AMP → `module.telemetry_ingest` / `module.telemetry_store`
- KMS / Secrets Manager → `module.security`

## Cách kích hoạt generator task

### Cách 1: Run-task thủ công (khuyến nghị cho test window)

```bash
aws ecs run-task \
  --cluster cdo08-sandbox-generator-cluster \
  --task-definition cdo08-sandbox-generator \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[<workload_private_subnet_id>],
    securityGroups=[<generator_sg_id>],
    assignPublicIp=DISABLED
  }" \
  --overrides '{
    "containerOverrides": [{
      "name": "generator",
      "environment": [{"name": "SCENARIO", "value": "gradual_drift"}]
    }]
  }'
```

Thay `<workload_private_subnet_id>` và `<generator_sg_id>` bằng output từ `module.networking`.

### Cách 2: Bật EventBridge schedule (cho test window tự động)

```bash
# Bật trước khi bắt đầu test window
aws events enable-rule --name cdo08-sandbox-generator-schedule

# TẮT ngay sau khi test window kết thúc để tránh phát sinh cost
aws events disable-rule --name cdo08-sandbox-generator-schedule
```

> **Lưu ý:** Rule mặc định là **DISABLED**. KHÔNG để enabled 24/7.

### Cách 3: Terraform variable (cho test window có time-bound)

Trong `infra/environments/sandbox/main.tf`, có thể thêm overrides vào module call — nhưng không thay đổi state mặc định là DISABLED.

## Variables quan trọng

| Variable | Default | Mô tả |
|---|---|---|
| `generator_image_uri` | `""` | URI image ECR. Để trống khi image chưa build. |
| `ingest_api_endpoint` | `PLACEHOLDER` | URL ingest API. Cập nhật sau khi Phương merge module. |
| `tenant_id` | `tenant-cdo08-demo` | Tenant ID cho mọi event |
| `service_list` | `payment-api,queue-worker,gateway-api` | Danh sách service |
| `scenario_list` | `gradual_drift,sudden_spike,slow_leak,noisy_baseline` | Các scenario test |
| `emit_interval_seconds` | `60` | Tần suất emit (giây) |

## Dependency wiring còn pending

`ingest_api_endpoint` hiện dùng placeholder. Sau khi Phương merge `module.telemetry_ingest`:

1. Sửa `sandbox/main.tf` để pass `module.telemetry_ingest.ingest_api_url` vào biến này.
2. Tương tự cập nhật IAM resource ARN trong task role policy từ `*` thành ARN cụ thể.
3. Chạy lại `terraform plan` và attach output vào PR update.

## Security

- Task role **không có** quyền `aps:RemoteWrite` hay bất kỳ AMP action nào.
- Không có static AWS credential trong container — IAM role via ECS task metadata.
- Không có public inbound port trên task.
- Image scan enabled; ECR lifecycle giữ tối đa 5 images.
- Container chạy với `user: 1000` (non-root) và `readonlyRootFilesystem: true`.
