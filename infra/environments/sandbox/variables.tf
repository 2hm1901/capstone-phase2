variable "aws_region" {
  description = "AWS Region for the single CDO08 sandbox environment."
  type        = string
  default     = "us-west-2"
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
  description = "Full ECR URI for the synthetic generator image. Leave empty until image is built."
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

variable "ingest_api_endpoint" {
  description = <<-EOT
    HTTPS endpoint for telemetry ingest.
    Placeholder until module.telemetry_ingest (Phuong) is merged.
    Once merged, wire module.telemetry_ingest.ingest_api_url here.
  EOT
  type        = string
  default     = "https://PLACEHOLDER.execute-api.us-west-2.amazonaws.com/v1/ingest"
}

variable "generator_log_retention_days" {
  description = "CloudWatch log retention in days for generator task logs."
  type        = number
  default     = 14
}
