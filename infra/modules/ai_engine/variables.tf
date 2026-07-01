variable "name_prefix" {
  type        = string
  description = "Prefix cho tên resources"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "vpc_id" {
  type        = string
  description = "ID của AI VPC"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Reserved public subnets. The current AI Engine ALB is internal and uses private_subnet_ids."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets cho internal ALB và ECS tasks"
}

variable "alb_security_group_id" {
  type        = string
  description = "Security Group ID cho internal ALB"
}

variable "task_security_group_id" {
  type        = string
  description = "Security Group ID cho ECS tasks"
}

variable "api_vpc_link_security_group_id" {
  type        = string
  description = "Security Group ID for API Gateway VPC Link to the internal AI Engine ALB"
}

variable "ai_engine_role_arn" {
  type        = string
  description = "IAM task role ARN cho AI Engine ECS task runtime permissions"
}

variable "ai_engine_ecr_repo_url" {
  type        = string
  description = "ECR repo URL cho AI engine image"
}

variable "ai_engine_image_tag" {
  type        = string
  description = "Tag của AI engine image"
  default     = "latest"
}

variable "ai_engine_image_digest" {
  type        = string
  description = "AI Engine image digest (optional, for immutable tags)"
  default     = null
}

variable "baseline_bucket_name" {
  type        = string
  description = "Tên S3 bucket chứa baselines"
}

variable "app_log_group_name" {
  type        = string
  description = "Tên CloudWatch log group cho app logs"
}

variable "audit_log_group_name" {
  type        = string
  description = "Tên CloudWatch log group cho audit logs"
}

variable "tags" {
  type        = map(string)
  description = "Tags chung"
  default     = {}
}
