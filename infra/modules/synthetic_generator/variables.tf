
# -----------------------------------------------------------------------------
# Module: synthetic_generator
# Owner:  Thuy (CDO08)
# Purpose: ECS Fargate task that emits synthetic telemetry for 3 demo services
#          across 4 test scenarios: gradual_drift, sudden_spike, slow_leak,
#          noisy_baseline.  No public inbound, no static AWS credentials.
# -----------------------------------------------------------------------------

variable "name_prefix" {
  description = "Name prefix applied to every resource created by this module."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking — consumed from module.networking outputs; no new VPC/subnet/SG
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "Workload VPC ID (output from module.networking.workload_vpc_id)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Workload private subnet IDs (output from module.networking.workload_private_subnet_ids)."
  type        = list(string)
}

variable "generator_security_group_id" {
  description = "Security group ID for the generator tasks (output from module.networking.generator_security_group_id)."
  type        = string
}

# ---------------------------------------------------------------------------
# Container image
# ---------------------------------------------------------------------------

variable "generator_image_uri" {
  description = <<-EOT
    Full ECR URI for the synthetic generator image including tag or digest,
    e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/cdo08-generator:sha256-abc.
    Leave empty during initial IaC scaffolding before the image is built; the
    module will create ECR/cluster scaffolding but skip task definition/schedule.
  EOT
  type        = string
  default     = ""
}

variable "task_role_arn" {
  description = "Runtime task role ARN for the generator from security_baseline."
  type        = string
}

# ---------------------------------------------------------------------------
# Task compute
# ---------------------------------------------------------------------------

variable "task_cpu" {
  description = "CPU units for the ECS Fargate task (256 / 512 / 1024 …)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory in MiB for the ECS Fargate task."
  type        = number
  default     = 512
}

# ---------------------------------------------------------------------------
# Generator behaviour
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Logical tenant ID injected into every telemetry event."
  type        = string
  default     = "tenant-cdo08-demo"
}

variable "service_list" {
  description = "Comma-separated list of service_id values the generator will emit for."
  type        = string
  default     = "payment-gw,ledger,fraud-detector"
}

variable "scenario_list" {
  description = "Comma-separated list of test scenarios to run."
  type        = string
  default     = "gradual_drift,sudden_spike,slow_leak,noisy_baseline"
}

variable "emit_interval_seconds" {
  description = "Interval in seconds between telemetry emits per service/metric."
  type        = number
  default     = 60
}

# ---------------------------------------------------------------------------
# Telemetry ingest endpoint (wired from module.telemetry_ingest once merged)
# ---------------------------------------------------------------------------

variable "ingest_api_endpoint" {
  description = <<-EOT
    HTTPS endpoint the generator posts telemetry to,
    e.g. https://<api-id>.execute-api.<region>.amazonaws.com/sandbox/v1/telemetry.
    This should be wired from module.telemetry_ingest.api_endpoint.
  EOT
  type        = string
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention in days for generator task logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be one of the values allowed by aws_cloudwatch_log_group."
  }
}

# ---------------------------------------------------------------------------
# AWS region — needed for log group and IAM policy ARNs
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where the module is deployed."
  type        = string
}
