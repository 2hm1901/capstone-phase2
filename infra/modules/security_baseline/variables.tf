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

variable "enable_email_alerts" {
  description = "Create SNS email alert topic/subscriptions and allow Prediction/Fallback Lambdas to publish alerts."
  type        = bool
  default     = true
}

variable "alert_email_subscribers" {
  description = "Email addresses subscribed to prediction/fallback SNS alerts. Recipients must confirm the SNS subscription email."
  type        = list(string)
  default     = ["2hm1901dev@gmail.com"]
}
