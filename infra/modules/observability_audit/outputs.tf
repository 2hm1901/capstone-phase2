output "audit_table_name" {
  description = "Name of the DynamoDB audit table."
  value       = aws_dynamodb_table.audit.name
}

output "audit_table_arn" {
  description = "ARN of the DynamoDB audit table."
  value       = aws_dynamodb_table.audit.arn
}

output "grafana_workspace_id" {
  description = "Amazon Managed Grafana workspace ID (created or referenced). Null when Grafana is deferred."
  value       = local.grafana_workspace_id
}

output "grafana_secret_arn" {
  description = "Secrets Manager secret ARN holding the Grafana service-account token, owned by the security module. Null when deferred."
  value       = var.grafana_secret_arn
}

output "annotation_audit_log_group_name" {
  description = "CloudWatch Logs log group for annotation/audit structured logs."
  value       = aws_cloudwatch_log_group.annotation_audit.name
}

output "alarm_names" {
  description = "Map of CloudWatch alarm names owned by this module."
  value = {
    audit_write_error = aws_cloudwatch_metric_alarm.audit_write_error.alarm_name
    annotation_error  = aws_cloudwatch_metric_alarm.annotation_error.alarm_name
    fallback_spike    = aws_cloudwatch_metric_alarm.fallback_count_spike.alarm_name
  }
}

output "dashboard_name" {
  description = "CloudWatch dashboard name summarizing audit/annotation/fallback health."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
