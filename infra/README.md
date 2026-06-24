# Terraform – CDO08

CDO08 có đúng **một môi trường deployable**: `sandbox`. Không tạo `prod`, `staging`, Terraform workspace hay state key khác cho project này.

State remote dùng Amazon S3 tại key `cdo08/sandbox/terraform.tfstate`. S3 native locking được bật bằng `use_lockfile = true`; Terraform tự tạo và xóa object `cdo08/sandbox/terraform.tfstate.tflock` trong lúc `plan`, `apply` hoặc thao tác có thể ghi state. Không tạo DynamoDB lock table: cơ chế locking đó đã deprecated.

## Cấu trúc

```text
infra/
├── bootstrap/              # Tạo S3 bucket state một lần
├── environments/
│   └── sandbox/            # Root module deploy platform duy nhất
└── modules/                # Reusable platform modules
```

`bootstrap` là administrative setup, không phải một môi trường ứng dụng. State local của bootstrap chỉ dùng để tạo state bucket lần đầu; không commit file state này.

## Khởi tạo state backend (một lần)

Yêu cầu: AWS CLI đã đăng nhập vào đúng AWS account và Terraform `>= 1.10.0`.

Chọn một tên bucket S3 duy nhất toàn cầu, ví dụ `cdo08-tf-state-<aws-account-id>`, rồi chạy:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply \
  -var='aws_region=ap-southeast-1' \
  -var='state_bucket_name=cdo08-tf-state-REPLACE_ME'
```

Bootstrap cấu hình versioning, SSE-S3 encryption, public-access block, TLS-only bucket policy, lifecycle cho noncurrent version và `prevent_destroy`.

## Khởi tạo sandbox cho từng thành viên

Không commit `backend.hcl`. Mỗi thành viên tạo file local từ template và dùng cùng bucket, region và key:

```bash
cp infra/environments/sandbox/backend.hcl.example infra/environments/sandbox/backend.hcl
# Sửa bucket và region trong backend.hcl

terraform -chdir=infra/environments/sandbox init \
  -backend-config=backend.hcl
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan \
  -var='aws_region=ap-southeast-1'
```

Chỉ chạy `apply` sau khi team review plan. Nếu state đang bị lock, chờ thao tác đang chạy hoàn tất. Chỉ dùng `terraform force-unlock LOCK_ID` khi đã xác nhận không còn process Terraform nào đang dùng state đó.

## Quy ước làm việc

- Chỉ thay đổi resources qua `infra/environments/sandbox/` và module được gọi từ đó.
- Luôn chạy `fmt`, `validate` và `plan` trước khi gửi review hoặc apply.
- Không dùng `terraform workspace`; namespace môi trường đã cố định là `sandbox`.
- Không commit `.terraform/`, state, plan file hoặc `backend.hcl`.
- IAM role/user chạy Terraform phải có quyền đọc/ghi state object và đọc/ghi/xóa object `.tflock`.

```bash
terraform -chdir=infra/environments/sandbox fmt -check -recursive
terraform -chdir=infra/environments/sandbox validate
terraform -chdir=infra/environments/sandbox plan -var='aws_region=ap-southeast-1'
```
