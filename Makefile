TF_DIR := infra/environments/sandbox

.DEFAULT_GOAL := help

.PHONY: help tf-init tf-fmt tf-fmt-check tf-validate tf-plan tf-apply tf-check

help: ## Show available Terraform commands.
	@awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tf-init: ## Initialize the shared sandbox S3 backend.
	terraform -chdir=$(TF_DIR) init

tf-fmt: ## Format Terraform files in the sandbox root module.
	terraform -chdir=$(TF_DIR) fmt -recursive

tf-fmt-check: ## Check Terraform formatting without changing files.
	terraform -chdir=$(TF_DIR) fmt -check -recursive

tf-validate: tf-init ## Validate the sandbox Terraform configuration.
	terraform -chdir=$(TF_DIR) validate

tf-plan: tf-init ## Preview sandbox infrastructure changes.
	terraform -chdir=$(TF_DIR) plan

tf-apply: tf-init ## Apply reviewed changes to the shared sandbox.
	terraform -chdir=$(TF_DIR) apply

tf-check: tf-init tf-fmt-check ## Run initialization, formatting checks, and validation.
	terraform -chdir=$(TF_DIR) validate
