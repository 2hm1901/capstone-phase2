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

variable "telemetry_queue_arn" {
  description = "Temporary telemetry queue ARN placeholder. Replace with module.telemetry_ingest output after that module is merged."
  type        = string
  default     = "arn:aws:sqs:us-west-2:894597652722:cdo08-sandbox-telemetry-queue-placeholder"
}

variable "telemetry_queue_url" {
  description = "Temporary telemetry queue URL placeholder. Replace with module.telemetry_ingest output after that module is merged."
  type        = string
  default     = "https://sqs.us-west-2.amazonaws.com/894597652722/cdo08-sandbox-telemetry-queue-placeholder"
}

variable "telemetry_dlq_name" {
  description = "Temporary telemetry DLQ name placeholder for alarm wiring. Replace with module.telemetry_ingest output after that module is merged."
  type        = string
  default     = "cdo08-sandbox-telemetry-dlq-placeholder"
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
  description = "Telemetry Writer Lambda reserved concurrency."
  type        = number
  default     = 3
}

variable "writer_log_retention_days" {
  description = "Telemetry Writer CloudWatch log retention in days."
  type        = number
  default     = 14
}
