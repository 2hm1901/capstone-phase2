variable "aws_region" {
  description = "AWS Region used to build regional VPC endpoint service names."
  type        = string
}

variable "name_prefix" {
  description = "Name prefix for networking resources."
  type        = string
}

variable "workload_vpc_cidr" {
  description = "CIDR block for the synthetic workload/services VPC."
  type        = string
}

variable "ai_engine_vpc_cidr" {
  description = "CIDR block for the AI Engine runtime VPC."
  type        = string
}

variable "private_subnet_count" {
  description = "Number of private subnets to create per VPC."
  type        = number
}

variable "tags" {
  description = "Common tags applied to all networking resources."
  type        = map(string)
  default     = {}
}
