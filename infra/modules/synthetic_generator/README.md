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
| ECS task definition | `cdo08-sandbox-generator` | Chỉ tạo khi `generator_image_uri` khác rỗng |
| IAM task execution role | `cdo08-sandbox-generator-execution-role` | ECR pull + CW Logs write |
| IAM task role | `module.security_baseline.generator_role_arn` | Runtime role do Quyết owner; không tạo role trùng trong module này |
| IAM EventBridge role | `cdo08-sandbox-generator-events-role` | Chỉ tạo khi có task definition |
| CloudWatch log group | `/ecs/cdo08-sandbox-generator` | Retention 14 ngày (configurable) |
| EventBridge rule | `cdo08-sandbox-generator-schedule` | Chỉ tạo khi có image; **DISABLED by default** |

## Tài nguyên KHÔNG tạo ở đây

- VPC / subnet / security group → `module.networking`
- API Gateway / SQS / AMP → `module.telemetry_ingest` / `module.telemetry_store`
- KMS / Secrets Manager / runtime IAM role → `module.security_baseline`

## Cách kích hoạt generator task

> Chỉ chạy các lệnh dưới đây sau khi đã build/push image và set `generator_image_uri`.

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
| `generator_image_uri` | `""` | URI image ECR. Để trống thì chỉ tạo ECR/cluster scaffold, chưa tạo task definition/schedule. |
| `ingest_api_endpoint` | required | URL ingest API, wire từ `module.telemetry_ingest.api_endpoint`. |
| `task_role_arn` | required | Runtime role từ `module.security_baseline.generator_role_arn`. |
| `tenant_id` | `tenant-cdo08-demo` | Tenant ID cho mọi event |
| `service_list` | `payment-api,queue-worker,gateway-api` | Danh sách service |
| `scenario_list` | `gradual_drift,sudden_spike,slow_leak,noisy_baseline` | Các scenario test |
| `emit_interval_seconds` | `60` | Tần suất emit (giây) |

## Dependency wiring

`sandbox/main.tf` phải wire:

```hcl
ingest_api_endpoint = module.telemetry_ingest.api_endpoint
task_role_arn       = module.security_baseline.generator_role_arn
```

## Security

- Task role do `security_baseline` quản lý; module này không tạo IAM role runtime riêng.
- Generator role **không có** quyền `aps:RemoteWrite` hay bất kỳ AMP action nào.
- Không có static AWS credential trong container — IAM role via ECS task metadata.
- Không có public inbound port trên task.
- Image scan enabled; ECR lifecycle giữ tối đa 5 images.
- Container chạy với `user: 1000` (non-root) và `readonlyRootFilesystem: true`.
