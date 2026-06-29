variable "aws_region" {
  description = "AWS Region for the deployment"
  type        = string
}

variable "name_prefix" {
  description = "Prefix to be used for resource names"
  type        = string
}

variable "tags" {
  description = "A map of tags to assign to resources"
  type        = map(string)
  default     = {}
}

variable "reviewer_principal_arns" {
  description = "List of IAM User/Role ARNs allowed to assume the reviewer role"
  type        = list(string)
  default     = []
}

variable "budget_limit" {
  description = "The budget limit in USD"
  type        = string
  default     = "200"
}

variable "budget_email" {
  description = "The email address for budget alerts"
  type        = string
  default     = "2hm1901dev@gmail.com"
}

