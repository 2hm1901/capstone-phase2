# Terraform – CDO08

CDO08 có đúng **một môi trường deployable**: `sandbox`, chạy chung trong AWS account `894597652722` tại region `us-west-2`. Không tạo `prod`, `staging`, Terraform workspace hay state key khác cho project này.

Mỗi thành viên dùng IAM user AWS riêng, nhưng tất cả cùng đọc/ghi **một** remote state trong bucket `cdo08-tf-state-894597652722-us-west-2` tại key `cdo08/sandbox/terraform.tfstate`. S3 native locking được bật bằng `use_lockfile = true`; Terraform tự tạo và xóa object `cdo08/sandbox/terraform.tfstate.tflock` trong lúc `plan`, `apply` hoặc thao tác có thể ghi state. Không tạo DynamoDB lock table: cơ chế locking đó đã deprecated.

## Cấu trúc

```text
infra/
├── bootstrap/              # Tạo S3 bucket state một lần
├── environments/
│   └── sandbox/            # Root module deploy platform duy nhất
└── modules/                # Reusable platform modules
```

`bootstrap` là administrative setup, không phải một môi trường ứng dụng. State local của bootstrap chỉ dùng để tạo state bucket lần đầu; không commit file state này.

## Bước 0: kiểm tra AWS user (mọi thành viên)

Yêu cầu: AWS CLI đã cấu hình user IAM riêng của bạn và Terraform `>= 1.10.0`.

Chạy lệnh sau. Kết quả phải là account `894597652722` và region `us-west-2`; nếu khác, dừng lại và sửa AWS profile trước khi tiếp tục.

```bash
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
aws configure get region
terraform version
```

## Bước 1: tạo shared state bucket (chỉ một người thực hiện một lần)

> Chỉ một người trong team chạy bước này để tạo bucket state tại `us-west-2`. Sau khi bucket đã tồn tại, các thành viên khác không chạy lại `terraform apply` trong `infra/bootstrap`.

Người được team phân công chạy đúng các lệnh này một lần:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan
terraform -chdir=infra/bootstrap apply
```

Bootstrap cấu hình versioning, SSE-S3 encryption, public-access block, TLS-only bucket policy, lifecycle cho noncurrent version và `prevent_destroy`.

## Bước 2: kết nối shared sandbox state (mọi thành viên, một lần mỗi máy)

Backend S3 đã được versioned trong Terraform với đúng shared bucket, key, region và S3 lockfile. Chạy nguyên khối lệnh sau từ repository clone:

```bash
make tf-init
make tf-validate
make tf-plan
```

Các lệnh Terraform của team được gom trong [`Makefile`](../Makefile). Chạy `make` để xem danh sách lệnh. Chỉ chạy `make tf-apply` sau khi team review plan. Nếu state đang bị lock, chờ thao tác đang chạy hoàn tất. Chỉ dùng `terraform force-unlock LOCK_ID` khi đã xác nhận không còn process Terraform nào đang dùng state đó.

## Bước 3: vòng lặp thiết kế hạ tầng

Sau khi thêm hoặc sửa module/resource, chạy các lệnh sau trước khi gửi review:

```bash
make tf-fmt
make tf-validate
make tf-plan
```

Sau khi plan được team review:

```bash
make tf-apply
```

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
