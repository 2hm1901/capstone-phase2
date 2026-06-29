# Basic configuration
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "sandbox"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "cdo08-sandbox"
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "enable_prediction" {
  description = "Enable prediction module. Keep false until dependencies/artifacts are ready."
  type        = bool
  default     = false
}

# Service list
variable "service_list" {
  description = "List of services for scheduled prediction"
  type = list(object({
    service_id          = string
    tenant_id           = string
    schedule_expression = optional(string, "rate(5 minutes)")
    enabled             = optional(bool, true)
  }))
  default = [
    {
      service_id = "payment-api"
      tenant_id  = "tenant-cdo08-demo"
      enabled    = true
    },
    {
      service_id = "queue-worker"
      tenant_id  = "tenant-cdo08-demo"
      enabled    = true
    },
    {
      service_id = "gateway-api"
      tenant_id  = "tenant-cdo08-demo"
      enabled    = true
    },
  ]
}

# Prediction config
variable "prediction_interval_minutes" {
  description = "Prediction cadence in minutes"
  type        = number
  default     = 5
}

variable "lookback_minutes" {
  description = "AMP query lookback window. Contract requires >=120 minutes."
  type        = number
  default     = 120

  validation {
    condition     = var.lookback_minutes >= 120
    error_message = "lookback_minutes must be >= 120"
  }
}

# Dependency inputs from Nam telemetry_store module
variable "amp_workspace_id" {
  description = "AMP workspace ID from telemetry_store module"
  type        = string
  default     = null
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN from telemetry_store module. Used to scope APS query IAM permissions."
  type        = string
  default     = null
}

variable "amp_query_endpoint" {
  description = "AMP query endpoint from telemetry_store module"
  type        = string
  default     = null
}

# Dependency inputs from AI Engine module / runtime owner
variable "ai_engine_endpoint" {
  description = "AI Engine HTTPS endpoint. Example: https://internal-ai-alb/... or API endpoint"
  type        = string
  default     = null
}

variable "ai_engine_invoke_arn" {
  description = "Optional ARN used for invoke IAM if AI Engine is behind API Gateway/Lambda. Leave null for ALB HTTPS + SigV4 handled in code."
  type        = string
  default     = null
}

# Dependency inputs from audit/Grafana module
variable "audit_table_arn" {
  description = "DynamoDB audit table ARN"
  type        = string
  default     = null
}

variable "audit_table_name" {
  description = "DynamoDB audit table name"
  type        = string
  default     = null
}

variable "grafana_api_token_secret_arn" {
  description = "Grafana service account token secret ARN"
  type        = string
  default     = null
}

# Lambda source inputs
variable "prediction_source_dir" {
  description = "Source directory for Prediction Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
}

variable "serving_adapter_source_dir" {
  description = "Source directory for Serving Adapter Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
}

variable "fallback_source_dir" {
  description = "Source directory for Fallback Lambda code. Terraform packages this directory when enable_prediction=true."
  type        = string
}

# IAM roles are owned by infra/modules/security_baseline.
variable "prediction_role_arn" {
  description = "IAM role ARN for Prediction Lambda from security_baseline."
  type        = string
}

variable "serving_adapter_role_arn" {
  description = "IAM role ARN for Serving Adapter Lambda from security_baseline."
  type        = string
}

variable "fallback_role_arn" {
  description = "IAM role ARN for Fallback Lambda from security_baseline."
  type        = string
}

variable "scheduler_role_arn" {
  description = "IAM role ARN for EventBridge Scheduler from security_baseline."
  type        = string
}

# Lambda runtime config
variable "prediction_lambda_timeout_seconds" {
  description = "Prediction Lambda timeout"
  type        = number
  default     = 60
}

variable "prediction_lambda_memory_size" {
  description = "Prediction Lambda memory in MB"
  type        = number
  default     = 512
}

variable "serving_adapter_lambda_timeout_seconds" {
  description = "Serving Adapter Lambda timeout. Should include bounded AI retry budget."
  type        = number
  default     = 30
}

variable "serving_adapter_lambda_memory_size" {
  description = "Serving Adapter Lambda memory in MB"
  type        = number
  default     = 256
}

variable "fallback_lambda_timeout_seconds" {
  description = "Fallback Lambda timeout"
  type        = number
  default     = 30
}

variable "fallback_lambda_memory_size" {
  description = "Fallback Lambda memory in MB"
  type        = number
  default     = 256
}

# Logs
variable "log_retention_days" {
  description = "CloudWatch log retention"
  type        = number
  default     = 30
}

# Tags
variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    Project     = "CDO08"
    Environment = "sandbox"
    Owner       = "Nhan"
  }
}
