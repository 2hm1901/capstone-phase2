# CDO08 chỉ có một Terraform root module deployable: sandbox.
# Mọi target bên dưới đều dùng shared S3 state và S3 lockfile đã khai báo trong
# infra/environments/sandbox/versions.tf. Không chạy Terraform từ infra/bootstrap:
# state bucket đã được tạo xong.
TF_DIR := infra/environments/sandbox

.DEFAULT_GOAL := help

.PHONY: help tf-init tf-fmt tf-fmt-check tf-validate tf-plan tf-apply tf-check

# In danh sách lệnh Make có thể sử dụng.
help: ## Show available Terraform commands.
	@awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Chạy một lần sau khi clone repository hoặc khi Terraform báo cần init lại.
# Lệnh này chỉ kết nối thư mục làm việc local với shared S3 backend; không tạo resource.
tf-init: ## Initialize the shared sandbox S3 backend.
	terraform -chdir=$(TF_DIR) init

# Tự động căn chỉnh format các file .tf trước khi commit.
tf-fmt: ## Format Terraform files in the sandbox root module.
	terraform -chdir=$(TF_DIR) fmt -recursive

# Chỉ kiểm tra format, không tự sửa file. Dùng trong CI hoặc trước khi tạo PR.
tf-fmt-check: ## Check Terraform formatting without changing files.
	terraform -chdir=$(TF_DIR) fmt -check -recursive

# Kiểm tra syntax, provider schema và cấu hình Terraform. Tự init nếu cần.
tf-validate: tf-init ## Validate the sandbox Terraform configuration.
	terraform -chdir=$(TF_DIR) validate

# Xem trước resource nào sẽ được tạo/sửa/xóa. Luôn review output trước khi apply.
tf-plan: tf-init ## Preview sandbox infrastructure changes.
	terraform -chdir=$(TF_DIR) plan

# Áp dụng thay đổi đã được team review vào shared sandbox.
# Không chạy đồng thời với một Terraform apply khác: S3 lockfile sẽ serialize thao tác.
tf-apply: tf-init ## Apply reviewed changes to the shared sandbox.
	terraform -chdir=$(TF_DIR) apply

# Kiểm tra nhanh trước PR: init, format check và validate. Không thay đổi AWS resource.
tf-check: tf-init tf-fmt-check ## Run initialization, formatting checks, and validation.
	terraform -chdir=$(TF_DIR) validate
