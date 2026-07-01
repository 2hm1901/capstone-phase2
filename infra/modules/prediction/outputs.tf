output "prediction_lambda_name" {
  description = "Name of the Prediction Lambda function"
  value       = try(aws_lambda_function.prediction_lambda[0].function_name, null)
}

output "prediction_lambda_arn" {
  description = "ARN of the Prediction Lambda function"
  value       = try(aws_lambda_function.prediction_lambda[0].arn, null)
}

output "prediction_lambda_role_arn" {
  description = "ARN of the Prediction Lambda IAM role"
  value       = var.enable_prediction ? var.prediction_role_arn : null
}

output "serving_adapter_lambda_name" {
  description = "Name of the Serving Adapter Lambda function"
  value       = try(aws_lambda_function.serving_adapter_lambda[0].function_name, null)
}

output "serving_adapter_lambda_arn" {
  description = "ARN of the Serving Adapter Lambda function"
  value       = try(aws_lambda_function.serving_adapter_lambda[0].arn, null)
}

output "serving_adapter_lambda_role_arn" {
  description = "ARN of the Serving Adapter Lambda IAM role"
  value       = var.enable_prediction ? var.serving_adapter_role_arn : null
}

output "fallback_lambda_name" {
  description = "Name of the Fallback Lambda function"
  value       = try(aws_lambda_function.fallback_lambda[0].function_name, null)
}

output "fallback_lambda_arn" {
  description = "ARN of the Fallback Lambda function"
  value       = try(aws_lambda_function.fallback_lambda[0].arn, null)
}

output "fallback_lambda_role_arn" {
  description = "ARN of the Fallback Lambda IAM role"
  value       = var.enable_prediction ? var.fallback_role_arn : null
}

output "scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler IAM role"
  value       = var.enable_prediction ? var.scheduler_role_arn : null
}

output "prediction_schedule_names" {
  description = "Names of EventBridge Scheduler schedules"
  value = var.enable_prediction ? [
    for sched in aws_scheduler_schedule.prediction_schedule : sched.name
  ] : []
}

output "prediction_schedule_arns" {
  description = "ARNs of EventBridge Scheduler schedules"
  value = var.enable_prediction ? [
    for sched in aws_scheduler_schedule.prediction_schedule : sched.arn
  ] : []
}

output "prediction_log_group_name" {
  description = "CloudWatch log group for Prediction Lambda"
  value       = try(aws_cloudwatch_log_group.prediction_lambda_logs[0].name, null)
}

output "serving_adapter_log_group_name" {
  description = "CloudWatch log group for Serving Adapter Lambda"
  value       = try(aws_cloudwatch_log_group.serving_adapter_lambda_logs[0].name, null)
}

output "fallback_log_group_name" {
  description = "CloudWatch log group for Fallback Lambda"
  value       = try(aws_cloudwatch_log_group.fallback_lambda_logs[0].name, null)
}
