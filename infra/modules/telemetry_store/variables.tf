variable "name_prefix" {
  description = "Name prefix for telemetry store resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "telemetry_queue_arn" {
  description = "ARN of the telemetry SQS queue owned by the telemetry ingest module."
  type        = string
}

variable "telemetry_queue_url" {
  description = "URL of the telemetry SQS queue owned by the telemetry ingest module."
  type        = string
}

variable "telemetry_dlq_name" {
  description = "Optional telemetry DLQ queue name for CloudWatch alarm wiring."
  type        = string
  default     = null
}

variable "writer_role_arn" {
  description = "IAM role ARN for Telemetry Writer. Owned by the security_baseline module."
  type        = string
}

variable "enable_writer_event_source_mapping" {
  description = "Whether to create the SQS event source mapping from the real telemetry queue to Writer Lambda."
  type        = bool
  default     = false
}

variable "amp_workspace_alias" {
  description = "Alias for the AMP workspace used as the primary telemetry store."
  type        = string
}

variable "writer_source_dir" {
  description = "Path to telemetry writer Lambda source directory."
  type        = string
}

variable "writer_archive_output_path" {
  description = "Path for the generated telemetry writer Lambda zip archive."
  type        = string
  default     = null
}

variable "writer_runtime" {
  description = "Runtime for the telemetry writer Lambda package."
  type        = string
  default     = "python3.12"
}

variable "writer_handler" {
  description = "Handler for the telemetry writer Lambda package."
  type        = string
  default     = "handler.handler"
}

variable "batch_size" {
  description = "SQS batch size for telemetry writer event source mapping."
  type        = number
  default     = 50

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10000
    error_message = "batch_size must be between 1 and 10000."
  }
}

variable "maximum_batching_window_in_seconds" {
  description = "Maximum batching window in seconds for telemetry writer SQS polling."
  type        = number
  default     = 5

  validation {
    condition     = var.maximum_batching_window_in_seconds >= 0 && var.maximum_batching_window_in_seconds <= 300
    error_message = "maximum_batching_window_in_seconds must be between 0 and 300."
  }
}

variable "writer_timeout_seconds" {
  description = "Timeout for the telemetry writer Lambda."
  type        = number
  default     = 30
}

variable "writer_memory_size" {
  description = "Memory size for the telemetry writer Lambda."
  type        = number
  default     = 256
}

variable "writer_reserved_concurrency" {
  description = "Reserved concurrency for telemetry writer Lambda. Set null to use unreserved account concurrency."
  type        = number
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for telemetry writer logs."
  type        = number
  default     = 14
}

variable "writer_error_alarm_threshold" {
  description = "Threshold for Lambda Errors alarm."
  type        = number
  default     = 1
}

variable "writer_duration_alarm_threshold_ms" {
  description = "Threshold for Lambda Duration alarm in milliseconds."
  type        = number
  default     = 25000
}

variable "sqs_backlog_alarm_threshold" {
  description = "Threshold for visible messages in the telemetry queue."
  type        = number
  default     = 100
}

variable "sqs_queue_age_alarm_threshold_seconds" {
  description = "Threshold for oldest telemetry queue message age in seconds."
  type        = number
  default     = 300
}

variable "dlq_visible_alarm_threshold" {
  description = "Threshold for visible messages in the telemetry DLQ."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Common tags applied to telemetry store resources."
  type        = map(string)
  default     = {}
}
