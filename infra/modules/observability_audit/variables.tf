variable "name_prefix" {
  description = "Name prefix for observability and audit resources."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all observability and audit resources."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS Region for regional resource names (e.g. CloudWatch dashboard)."
  type        = string
}

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
  description = "List of IAM principal ARNs allowed to assume the audit-reader role. Leave empty to skip creating the reader role (fail-safe: no implicit account-root access)."
  type        = list(string)
  default     = []
}

variable "grafana_secret_arn" {
  description = "Secrets Manager secret ARN holding the Grafana service-account token, owned by the security module. Set null to defer until the security module merges. This module never creates or stores the token."
  type        = string
  default     = null
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

variable "create_grafana_workspace" {
  description = "Set false to use reference mode (existing workspace). Set true to attempt creating an Amazon Managed Grafana workspace; requires the account to have the necessary permissions and Grafana service role."
  type        = bool
  default     = false
}