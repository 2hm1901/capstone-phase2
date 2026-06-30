variable "aws_region" {
  description = "AWS Region for the single CDO08 sandbox environment."
  type        = string
  default     = "us-east-1"
}

variable "workload_vpc_cidr" {
  description = "CIDR block for the synthetic workload/services VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "ai_engine_vpc_cidr" {
  description = "CIDR block for the AI Engine runtime VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "private_subnet_count" {
  description = "Number of private subnets to create per VPC."
  type        = number
  default     = 2

  validation {
    condition     = var.private_subnet_count >= 2 && var.private_subnet_count <= 3
    error_message = "private_subnet_count must be between 2 and 3."
  }
}

variable "ai_engine_alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the AI Engine public ALB on HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# Synthetic Generator variables (Owner: Thuy)
# ---------------------------------------------------------------------------

variable "generator_image_uri" {
  description = "Full ECR URI for the synthetic generator image. Leave empty to create only ECR/cluster scaffolding."
  type        = string
  default     = ""
}

variable "generator_tenant_id" {
  description = "Tenant ID injected into every synthetic telemetry event."
  type        = string
  default     = "tenant-cdo08-demo"
}

variable "generator_service_list" {
  description = "Comma-separated list of service_id values the generator emits for."
  type        = string
  default     = "payment-api,queue-worker,gateway-api"
}

variable "generator_scenario_list" {
  description = "Comma-separated list of test scenarios."
  type        = string
  default     = "gradual_drift,sudden_spike,slow_leak,noisy_baseline"
}

variable "generator_emit_interval_seconds" {
  description = "Interval in seconds between telemetry emits per service/metric."
  type        = number
  default     = 60
}

variable "generator_log_retention_days" {
  description = "CloudWatch log retention in days for generator task logs."
  type        = number
  default     = 14
}

variable "enable_prediction" {
  description = "Enable Prediction/Scheduler/Fail-open resources. Keep false until Lambda packages and AI endpoint are ready."
  type        = bool
  default     = false
}

variable "enable_writer_event_source_mapping" {
  description = "Enable SQS to Writer Lambda event source mapping only after the real telemetry queue output is available."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# observability_audit module variables
# ---------------------------------------------------------------------------

variable "audit_table_name" {
  description = "Name of the DynamoDB audit table. Defaults to <name_prefix>-audit."
  type        = string
  default     = null
}

variable "audit_retention_days" {
  description = "Audit record retention in days. Used for the TTL attribute and PR documentation."
  type        = number
  default     = 90
}

variable "audit_ttl_enabled" {
  description = "Enable DynamoDB TTL on the expires_at attribute. Set false to defer TTL activation."
  type        = bool
  default     = true
}

variable "create_grafana_workspace" {
  description = "Set true to create a new Amazon Managed Grafana workspace. Requires IAM Identity Center (AWS_SSO) enabled in the account. Default false to avoid unintended billing; enable explicitly via -var='create_grafana_workspace=true' when ready. Set false to use reference mode with an existing workspace ID."
  type        = bool
  default     = false
}

variable "prediction_service_list" {
  description = "Services scheduled for prediction."
  type = list(object({
    service_id          = string
    tenant_id           = string
    schedule_expression = optional(string, "rate(5 minutes)")
    enabled             = optional(bool, true)
  }))
  default = [
    { service_id = "payment-api", tenant_id = "tenant-cdo08-demo" },
    { service_id = "queue-worker", tenant_id = "tenant-cdo08-demo" },
    { service_id = "gateway-api", tenant_id = "tenant-cdo08-demo" },
  ]
}

variable "prediction_source_dir" {
  description = "Source directory for Prediction Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
  default     = "../../../src/prediction"
}

variable "serving_adapter_source_dir" {
  description = "Source directory for Serving Adapter Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
  default     = "../../../src/serving_adapter"
}

variable "fallback_source_dir" {
  description = "Source directory for Fallback Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
  default     = "../../../src/fallback"
}

variable "writer_batch_size" {
  description = "Telemetry Writer SQS batch size."
  type        = number
  default     = 50
}

variable "writer_maximum_batching_window_seconds" {
  description = "Telemetry Writer maximum SQS batching window in seconds."
  type        = number
  default     = 5
}

variable "writer_timeout_seconds" {
  description = "Telemetry Writer Lambda timeout in seconds."
  type        = number
  default     = 30
}

variable "writer_memory_size" {
  description = "Telemetry Writer Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "writer_reserved_concurrency" {
  description = "Telemetry Writer Lambda reserved concurrency. Set null to use unreserved account concurrency."
  type        = number
  default     = null
}

variable "writer_log_retention_days" {
  description = "Telemetry Writer CloudWatch log retention in days."
  type        = number
  default     = 14
}

variable "grafana_workspace_id" {
  description = "Existing Amazon Managed Grafana workspace ID for reference mode. Set null to create a new workspace."
  type        = string
  default     = null
}

variable "grafana_workspace_name" {
  description = "Name for the new Amazon Managed Grafana workspace when grafana_workspace_id is null."
  type        = string
  default     = null
}

variable "grafana_datasource_uid" {
  description = "Existing Grafana datasource UID for the AMP workspace. Set null to defer datasource wiring until the AMP module merges."
  type        = string
  default     = null
}

variable "alarm_audit_write_error_threshold" {
  description = "Threshold for the audit write error alarm (number of errors in the evaluation period)."
  type        = number
  default     = 0
}

variable "alarm_annotation_error_period_secs" {
  description = "Evaluation period in seconds for the annotation error alarm."
  type        = number
  default     = 300
}

variable "alarm_annotation_error_threshold" {
  description = "Threshold for the annotation error alarm (number of errors in the evaluation period)."
  type        = number
  default     = 0
}

variable "alarm_fallback_count_threshold" {
  description = "Threshold for the fallback annotation count alarm over the evaluation period."
  type        = number
  default     = 5
}

variable "alarm_fallback_count_period_secs" {
  description = "Evaluation period in seconds for the fallback annotation count alarm."
  type        = number
  default     = 300
}

variable "reviewer_principal_arns" {
  description = "List of IAM User/Role ARNs allowed to assume the reviewer role"
  type        = list(string)
  default     = []
}
