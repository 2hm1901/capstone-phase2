variable "name_prefix" {
  description = "Prefix for all telemetry ingest resources"
  type        = string
}

variable "api_stage" {
  description = "API Gateway stage name"
  type        = string
  default     = "sandbox"
}

variable "auth_mode" {
  description = "Authentication mode for telemetry API. Expected: IAM"
  type        = string
  default     = "IAM"
}

variable "lambda_package_path" {
  description = "Path to Lambda ingest deployment package zip"
  type        = string
}

variable "lambda_role_arn" {
  description = "IAM role ARN for Lambda Ingest. Owned by the security_baseline module."
  type        = string
}

variable "lambda_role_name" {
  description = "IAM role name for Lambda Ingest. Owned by the security_baseline module."
  type        = string
}

variable "sqs_kms_master_key_id" {
  description = "KMS key ID or alias used for SQS SSE-KMS encryption. Defaults to AWS managed SQS key."
  type        = string
  default     = "alias/aws/sqs"
}

variable "lambda_timeout" {
  description = "Lambda ingest timeout in seconds"
  type        = number
  default     = 10
}

variable "lambda_memory" {
  description = "Lambda ingest memory in MB"
  type        = number
  default     = 256
}

variable "queue_retention_seconds" {
  description = "Telemetry SQS queue retention seconds"
  type        = number
  default     = 345600
}

variable "visibility_timeout_seconds" {
  description = "Telemetry SQS visibility timeout seconds"
  type        = number
  default     = 60
}

variable "max_receive_count" {
  description = "Number of failed receives before moving message to DLQ"
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "CloudWatch log retention for ingest Lambda"
  type        = number
  default     = 14
}

variable "alarm_queue_age_threshold_seconds" {
  description = "Alarm threshold for SQS oldest message age"
  type        = number
  default     = 300
}

variable "allowed_metric_types" {
  description = "Comma-separated allowed telemetry metric types"
  type        = string

  default = "cpu_usage_percent,memory_usage_percent,active_connections,db_connection_pool_pct,queue_depth,cache_hit_rate_pct,api_latency_ms"
}


variable "api_throttling_burst_limit" {
  description = "API Gateway throttling burst limit"
  type        = number
  default     = 1000
}

variable "api_throttling_rate_limit" {
  description = "API Gateway throttling rate limit"
  type        = number
  default     = 1000
}

variable "ingest_reserved_concurrency" {
  description = "Reserved concurrency for the ingest Lambda. Null leaves it unreserved."
  type        = number
  default     = null
}
