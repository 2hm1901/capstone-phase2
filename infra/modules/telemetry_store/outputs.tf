output "amp_workspace_id" {
  description = "AMP workspace ID for the primary telemetry store."
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "AMP workspace ARN for IAM scoping."
  value       = aws_prometheus_workspace.this.arn
}

output "amp_workspace_alias" {
  description = "AMP workspace alias."
  value       = aws_prometheus_workspace.this.alias
}

output "amp_remote_write_endpoint" {
  description = "AMP remote-write endpoint for telemetry writer or POC clients."
  value       = local.amp_remote_write_endpoint
}

output "amp_query_endpoint" {
  description = "AMP query endpoint for Prediction Lambda and Grafana."
  value       = local.amp_query_endpoint
}

output "writer_lambda_name" {
  description = "Telemetry Writer Lambda function name."
  value       = aws_lambda_function.writer.function_name
}

output "writer_lambda_arn" {
  description = "Telemetry Writer Lambda function ARN."
  value       = aws_lambda_function.writer.arn
}

output "writer_role_arn" {
  description = "Telemetry Writer Lambda IAM role ARN."
  value       = aws_iam_role.writer.arn
}

output "writer_log_group_name" {
  description = "Telemetry Writer CloudWatch log group name."
  value       = aws_cloudwatch_log_group.writer.name
}
