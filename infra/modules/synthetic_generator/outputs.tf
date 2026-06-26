
# -----------------------------------------------------------------------------
# Outputs — synthetic_generator module
# -----------------------------------------------------------------------------

output "cluster_arn" {
  description = "ARN of the ECS cluster running the synthetic generator."
  value       = aws_ecs_cluster.generator.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster running the synthetic generator."
  value       = aws_ecs_cluster.generator.name
}

output "task_definition_arn" {
  description = "ARN of the latest ECS task definition revision for the generator."
  value       = try(aws_ecs_task_definition.generator[0].arn, null)
}

output "task_role_arn" {
  description = "ARN of the IAM task role attached to the generator container. Has execute-api:Invoke on telemetry ingest only — no AMP write, no admin."
  value       = var.task_role_arn
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution role (ECR pull + CloudWatch Logs write)."
  value       = aws_iam_role.task_execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group name for generator task logs."
  value       = aws_cloudwatch_log_group.generator.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN for generator task logs."
  value       = aws_cloudwatch_log_group.generator.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for the generator image."
  value       = aws_ecr_repository.generator.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN for the generator image."
  value       = aws_ecr_repository.generator.arn
}

output "schedule_rule_name" {
  description = "Name of the EventBridge schedule rule (DISABLED by default; enable manually for test windows)."
  value       = try(aws_cloudwatch_event_rule.generator_schedule[0].name, null)
}

output "generator_security_group_id" {
  description = "Security group ID used by generator tasks (sourced from module.networking; exposed here for convenience)."
  value       = var.generator_security_group_id
}
