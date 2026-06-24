variable "aws_region" {
  description = "AWS Region that hosts the Terraform state bucket."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for CDO08 Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid 3-63 character S3 bucket name."
  }
}
