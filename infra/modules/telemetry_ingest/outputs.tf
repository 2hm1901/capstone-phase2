output "api_endpoint" {
  description = "Telemetry ingest API endpoint"
  value       = "${aws_apigatewayv2_api.telemetry.api_endpoint}/${var.api_stage}/v1/telemetry"
}

output "api_execution_arn" {
  description = "API Gateway execution ARN for IAM invoke scoping"
  value       = aws_apigatewayv2_api.telemetry.execution_arn
}

output "api_invoke_arn" {
  description = "Telemetry ingest POST route ARN for execute-api:Invoke permissions"
  value       = "${aws_apigatewayv2_api.telemetry.execution_arn}/${var.api_stage}/POST/v1/telemetry"
}

output "auth_mode" {
  description = "Telemetry API authentication mode"
  value       = var.auth_mode
}

output "queue_url" {
  description = "Telemetry SQS queue URL"
  value       = aws_sqs_queue.telemetry_queue.url
}

output "queue_arn" {
  description = "Telemetry SQS queue ARN"
  value       = aws_sqs_queue.telemetry_queue.arn
}

output "queue_name" {
  description = "Telemetry SQS queue name"
  value       = aws_sqs_queue.telemetry_queue.name
}

output "dlq_url" {
  description = "Telemetry DLQ URL"
  value       = aws_sqs_queue.telemetry_dlq.url
}

output "dlq_arn" {
  description = "Telemetry DLQ ARN"
  value       = aws_sqs_queue.telemetry_dlq.arn
}

output "dlq_name" {
  description = "Telemetry DLQ name"
  value       = aws_sqs_queue.telemetry_dlq.name
}

output "ingest_lambda_name" {
  description = "Lambda Ingest function name"
  value       = aws_lambda_function.ingest.function_name
}

output "ingest_lambda_arn" {
  description = "Lambda Ingest function ARN"
  value       = aws_lambda_function.ingest.arn
}
