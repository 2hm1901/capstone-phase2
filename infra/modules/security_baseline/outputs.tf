output "kms_key_arn" {
  description = "ARN of the customer managed KMS key"
  value       = aws_kms_key.security.arn
}

output "kms_key_id" {
  description = "ID of the customer managed KMS key"
  value       = aws_kms_key.security.key_id
}

output "baseline_bucket_name" {
  description = "Name of the baseline S3 bucket"
  value       = aws_s3_bucket.ai_baselines.bucket
}

output "baseline_bucket_arn" {
  description = "ARN of the baseline S3 bucket"
  value       = aws_s3_bucket.ai_baselines.arn
}

output "grafana_secret_arn" {
  description = "ARN of the Grafana token secret"
  value       = aws_secretsmanager_secret.grafana_token.arn
}

output "email_alert_topic_arn" {
  description = "SNS topic ARN for prediction/fallback email alerts."
  value       = try(aws_sns_topic.email_alerts[0].arn, null)
}

output "email_alert_subscribers" {
  description = "Email addresses configured as SNS subscribers for prediction/fallback alerts."
  value       = var.enable_email_alerts ? var.alert_email_subscribers : []
}

output "generator_role_arn" {
  description = "ARN of the Generator role"
  value       = aws_iam_role.generator.arn
}

output "ingest_role_arn" {
  description = "ARN of the Ingest role"
  value       = aws_iam_role.ingest.arn
}

output "ingest_role_name" {
  description = "Name of the Ingest role"
  value       = aws_iam_role.ingest.name
}

output "writer_role_arn" {
  description = "ARN of the Writer role"
  value       = aws_iam_role.writer.arn
}

output "prediction_role_arn" {
  description = "ARN of the Prediction role"
  value       = aws_iam_role.prediction.arn
}

output "ai_engine_role_arn" {
  description = "ARN of the AI Engine task role"
  value       = aws_iam_role.ai_engine.arn
}

output "fallback_role_arn" {
  description = "ARN of the Fallback role"
  value       = aws_iam_role.fallback.arn
}

output "scheduler_role_arn" {
  description = "ARN of the Scheduler role"
  value       = aws_iam_role.scheduler.arn
}

output "reviewer_role_arn" {
  description = "ARN of the Reviewer role"
  value       = length(aws_iam_role.reviewer) > 0 ? aws_iam_role.reviewer[0].arn : null
}

output "ai_engine_app_log_group_name" {
  description = "Name of the AI Engine app log group"
  value       = aws_cloudwatch_log_group.ai_engine_app.name
}

output "ai_engine_audit_log_group_name" {
  description = "Name of the AI Engine audit log group"
  value       = aws_cloudwatch_log_group.ai_engine_audit.name
}

output "ai_engine_ecr_repo_url" {
  description = "ECR Repository URL for AI Engine"
  value       = aws_ecr_repository.ai_engine.repository_url
}
