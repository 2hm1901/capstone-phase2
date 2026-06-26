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

variable "audit_kms_key_arn" {
  description = "Customer-managed KMS key ARN for DynamoDB SSE-KMS. Set null to use AWS-owned key (defer CMK wiring until the security module merges)."
  type        = string
  default     = null
}

variable "audit_reader_principal_arns" {
  description = "List of IAM principal ARNs allowed to assume the audit-reader role. Leave empty to skip creating the reader role."
  type        = list(string)
  default     = []
}

variable "create_grafana_workspace" {
  description = "Set false to use reference mode (existing workspace). Set true to attempt creating an Amazon Managed Grafana workspace."
  type        = bool
  default     = false
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

variable "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID consumed to configure a Grafana AMP datasource. Set null to defer datasource wiring until the AMP module merges."
  type        = string
  default     = null
}

variable "grafana_secret_arn" {
  description = "Secrets Manager secret ARN holding the Grafana service-account token, owned by the security module. Set null to defer until the security module merges."
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
