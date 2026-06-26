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
