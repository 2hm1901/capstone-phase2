# Terraform – CDO08

CDO08 có đúng **một môi trường deployable**: `sandbox`, chạy chung trong AWS account `894597652722` tại region `us-east-1`. Không tạo `prod`, `staging`, Terraform workspace hay state key khác cho project này.

Mỗi thành viên dùng IAM user AWS riêng, nhưng tất cả cùng đọc/ghi **một** remote state trong bucket `cdo08-tf-state-894597652722-us-east-1` tại key `cdo08/sandbox/terraform.tfstate`. S3 native locking được bật bằng `use_lockfile = true`; Terraform tự tạo và xóa object `cdo08/sandbox/terraform.tfstate.tflock` trong lúc `plan`, `apply` hoặc thao tác có thể ghi state. Không tạo DynamoDB lock table: cơ chế locking đó đã deprecated.

## Cấu trúc

```text
infra/
├── bootstrap/              # Tạo S3 bucket state một lần
├── environments/
│   └── sandbox/            # Root module deploy platform duy nhất
└── modules/                # Reusable platform modules
```

`bootstrap` là administrative setup, không phải một môi trường ứng dụng. State local của bootstrap chỉ dùng để tạo state bucket lần đầu; không commit file state này.

Module Terraform chỉ được thêm hoặc sửa khi có Jira task/PR tương ứng, để tránh nhiều người tạo trùng cùng một resource. Các module app dùng chung IAM/KMS/secret/network output từ module nền tảng thay vì tự tạo lại.

## Quy chuẩn Lambda source code

Source code Lambda nằm trong `src/<lambda-name>/`, không nằm trong `infra/` và không commit file `.zip`.

```text
src/
├── ingest/             # Lambda Telemetry Ingest, handler index.handler
├── writer/             # Lambda Telemetry Writer, handler handler.handler
├── prediction/         # Lambda Prediction, handler index.handler
├── serving_adapter/    # Lambda Serving Adapter, handler index.handler
└── fallback/           # Lambda Fallback, handler index.handler
```

Terraform package Lambda bằng `archive_file` khi chạy `plan/apply`:

- Ingest: package từ `src/ingest`.
- Writer: package từ `src/writer`.
- Prediction/Serving Adapter/Fallback: package từ `src/prediction`, `src/serving_adapter`, `src/fallback` khi `enable_prediction=true`.

Quy tắc khi sửa hoặc thêm Lambda:

- Sửa code trong `src/<lambda-name>/`, không sửa trực tiếp trong `.terraform/` hoặc AWS Console.
- Không commit `build/`, `.terraform/`, `*.zip`, `*.tfplan`.
- Handler phải khớp file code: `index.py` dùng `index.handler`, `handler.py` dùng `handler.handler`.
- IAM role lấy từ `infra/modules/security_baseline`; không tự tạo role riêng trong module Lambda nếu không có task/security review.
- Secret value không được để trong source, Terraform variable, Lambda environment plaintext hoặc log. Chỉ truyền secret ARN/name rồi đọc từ Secrets Manager khi runtime cần.
- Nếu Lambda cần dependency ngoài chuẩn library, thêm bước build rõ trong PR. Artifact build vẫn không được commit; source và lockfile/config build mới là source of truth.

## Bước 0: kiểm tra AWS user (mọi thành viên)

Yêu cầu: AWS CLI đã cấu hình user IAM riêng của bạn và Terraform `>= 1.10.0`.

Chạy lệnh sau. Kết quả phải là account `894597652722` và region `us-east-1`; nếu khác, dừng lại và sửa AWS profile trước khi tiếp tục.

```bash
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
aws configure get region
terraform version
```

## Bước 1: tạo shared state bucket (chỉ một người thực hiện một lần)

> Chỉ một người trong team chạy bước này để tạo bucket state tại `us-east-1`. Sau khi bucket đã tồn tại, các thành viên khác không chạy lại `terraform apply` trong `infra/bootstrap`.

Người được team phân công chạy đúng các lệnh này một lần:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan
terraform -chdir=infra/bootstrap apply
```

Bootstrap cấu hình versioning, SSE-S3 encryption, public-access block, TLS-only bucket policy, lifecycle cho noncurrent version và `prevent_destroy`.

## Bước 2: kết nối shared sandbox state (mọi thành viên, một lần mỗi máy)

Backend S3 đã được versioned trong Terraform với đúng shared bucket, key, region và S3 lockfile.

Nếu máy có `make`:

```bash
make tf-init
make tf-validate
make tf-plan
```

Nếu dùng Windows/PowerShell hoặc máy không có `make`, copy lệnh thô này:

```bash
terraform -chdir=infra/environments/sandbox init
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan
```

Các lệnh Terraform của team được gom trong [`Makefile`](../Makefile). Chạy `make` để xem danh sách lệnh nếu máy hỗ trợ. Chỉ apply sau khi team review plan. Nếu state đang bị lock, chờ thao tác đang chạy hoàn tất. Chỉ dùng `terraform force-unlock LOCK_ID` khi đã xác nhận không còn process Terraform nào đang dùng state đó.

## Bước 3: vòng lặp thiết kế hạ tầng

Sau khi thêm hoặc sửa module/resource, chạy các lệnh sau trước khi gửi review.

Nếu máy có `make`:

```bash
make tf-fmt
make tf-validate
make tf-plan
```

Nếu dùng Windows/PowerShell hoặc máy không có `make`, copy lệnh thô này:

```bash
terraform -chdir=infra/environments/sandbox fmt -recursive
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan
```

Sau khi plan được team review:

```bash
make tf-apply
```

Hoặc lệnh thô tương đương:

```bash
terraform -chdir=infra/environments/sandbox apply
```

Không chạy `make tf-apply` hoặc `terraform apply` từ feature branch khi chưa có review plan. Nếu task phụ thuộc resource của người khác chưa merge, dùng `terraform output`, data source hoặc biến input rõ ràng sau khi PR phụ thuộc đã merge; không tạo lại resource thuộc owner khác.

## Runbook W12: chạy k6 ECS và AI Engine

AI Engine dùng API Gateway `AWS_IAM` làm SigV4 edge, VPC Link tới internal ALB và ECS task trong private subnet. K6 generator chạy bằng ECS Fargate trong workload private subnet; workload VPC có NAT Gateway để task pull ECR image, ghi CloudWatch Logs và gọi API Gateway ingest.

Deploy base runtime và tạo k6 task definition:

```bash
terraform -chdir=infra/environments/sandbox plan \
  -var='generator_image_uri=894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:k6-phased-scenarios-20260702-1'

terraform -chdir=infra/environments/sandbox apply \
  -var='generator_image_uri=894597652722.dkr.ecr.us-east-1.amazonaws.com/cdo08-sandbox-generator:k6-phased-scenarios-20260702-1'
```

Smoke test AI Engine qua SigV4 API Gateway:

```bash
AI_ENGINE_ENDPOINT="$(terraform -chdir=infra/environments/sandbox output -raw ai_engine_endpoint)" \
python3 scripts/smoke-ai-engine.py
```

Chạy k6 ECS theo phased scenario:

- Mặc định `ANOMALY_START_SECONDS=7200`: 2 giờ đầu emit baseline-aligned telemetry.
- Sau 2 giờ, scenario được chọn mới bắt đầu drift/spike/leak.
- Với W12 evidence, nên chạy 3 services + 1 scenario trong cùng một ECS task để Grafana hiển thị line liền mạch và Prediction Lambda có 120 phút lookback sạch.

Lệnh dưới đây cần `jq` để format subnet output. Nếu máy chưa có `jq`, copy `workload_private_subnet_ids` từ `terraform output` rồi điền thủ công vào `subnets=[...]`.

```bash
CLUSTER_NAME="$(terraform -chdir=infra/environments/sandbox output -raw generator_cluster_name)"
SUBNET_IDS="$(terraform -chdir=infra/environments/sandbox output -json workload_private_subnet_ids | jq -r 'join(",")')"
SG_ID="$(terraform -chdir=infra/environments/sandbox output -raw generator_security_group_id)"

OVERRIDES='{"containerOverrides":[{"name":"generator","environment":[{"name":"BACKFILL_MODE","value":"false"},{"name":"SCENARIO","value":"sudden_spike"},{"name":"ANOMALY_START_SECONDS","value":"7200"},{"name":"RUN_DURATION_SECONDS","value":"10800"},{"name":"EMIT_INTERVAL_SECONDS","value":"60"},{"name":"SERVICE_LIST","value":"payment-gw,ledger,fraud-detector"},{"name":"TENANT_ID","value":"tenant-cdo08-demo"}]}]}'

aws ecs run-task \
  --region us-east-1 \
  --cluster "$CLUSTER_NAME" \
  --task-definition cdo08-sandbox-generator \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SG_ID],assignPublicIp=DISABLED}" \
  --overrides "$OVERRIDES"
```

Sau khi AMP có đủ tối thiểu 120 phút baseline data, bật prediction:

```bash
terraform -chdir=infra/environments/sandbox plan \
  -var='enable_prediction=true'

terraform -chdir=infra/environments/sandbox apply \
  -var='enable_prediction=true'
```

Để tạo Amazon Managed Grafana workspace cùng lúc:

```bash
terraform -chdir=infra/environments/sandbox plan \
  -var='enable_prediction=true' \
  -var='create_grafana_workspace=true'

terraform -chdir=infra/environments/sandbox apply \
  -var='enable_prediction=true' \
  -var='create_grafana_workspace=true'
```

Sau khi workspace tạo xong, tạo Grafana service-account token trong UI và lưu vào Secrets Manager:

```bash
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id cdo08-sandbox-grafana-token \
  --secret-string '{"url":"https://<grafana-workspace-endpoint>","token":"<grafana-service-account-token>"}'
```

Provision AMP datasource và dashboard:

```bash
python scripts/provision_grafana.py
```

Email alert qua SNS:

- Terraform tạo SNS topic `cdo08-sandbox-prediction-alerts`.
- Email mặc định: `2hm1901dev@gmail.com`.
- Sau `terraform apply`, người nhận phải mở email từ AWS SNS và bấm **Confirm subscription**. Nếu chưa confirm thì Lambda publish thành công nhưng email không được gửi tới inbox.
- Prediction Lambda chỉ gửi email khi `anomaly=true`, severity >= `email_alert_min_severity`, và không bị cooldown duplicate service/action.
- Fallback Lambda gửi email khi static fallback phát hiện anomaly.

Kiểm tra subscription:

```bash
aws sns list-subscriptions-by-topic \
  --region us-east-1 \
  --topic-arn "$(terraform -chdir=infra/environments/sandbox output -raw email_alert_topic_arn)"
```

NAT Gateway phát sinh hourly cost. Nếu không chạy k6 ECS dài hạn, review plan/destroy cleanup sau test window theo quyết định PM.

## Quy ước làm việc

- Chỉ thay đổi resources qua `infra/environments/sandbox/` và module được gọi từ đó.
- Luôn chạy `fmt`, `validate` và `plan` trước khi gửi review hoặc apply.
- Không dùng `terraform workspace`; namespace môi trường đã cố định là `sandbox`.
- Không commit `.terraform/`, state hoặc plan file.
- IAM role/user chạy Terraform phải có quyền đọc/ghi state object và đọc/ghi/xóa object `.tflock`.

```bash
make tf-check
make tf-plan
```
