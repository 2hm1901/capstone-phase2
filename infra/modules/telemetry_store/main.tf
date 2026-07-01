locals {
  writer_function_name = "${var.name_prefix}-telemetry-writer"
  writer_log_group     = "/aws/lambda/${local.writer_function_name}"
  telemetry_queue_name = element(split(":", var.telemetry_queue_arn), 5)

  amp_remote_write_endpoint = "https://aps-workspaces.${data.aws_region.current.name}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}/api/v1/remote_write"
  amp_query_endpoint        = "https://aps-workspaces.${data.aws_region.current.name}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}/api/v1/query"

  writer_allowed_labels = "region,db_type,queue_name,cache_type,environment,instance_id,scenario"
  writer_blocked_labels = "correlation_id,request_id,event_id,trace_id,session_id,user_id"
}

data "aws_region" "current" {}

data "archive_file" "writer" {
  type        = "zip"
  source_dir  = var.writer_source_dir
  output_path = coalesce(var.writer_archive_output_path, "${path.root}/.terraform/telemetry-writer.zip")
}

resource "aws_prometheus_workspace" "this" {
  alias = var.amp_workspace_alias

  tags = merge(var.tags, {
    Name      = var.amp_workspace_alias
    Component = "telemetry-store"
  })
}

resource "aws_cloudwatch_log_group" "writer" {
  name              = local.writer_log_group
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name      = local.writer_log_group
    Component = "telemetry-writer"
  })
}

resource "aws_lambda_function" "writer" {
  function_name = local.writer_function_name
  description   = "Telemetry Writer: consumes validated telemetry events from SQS and remote-writes metrics into AMP."
  role          = var.writer_role_arn
  runtime       = var.writer_runtime
  handler       = var.writer_handler

  filename         = data.archive_file.writer.output_path
  source_code_hash = data.archive_file.writer.output_base64sha256

  timeout                        = var.writer_timeout_seconds
  memory_size                    = var.writer_memory_size
  reserved_concurrent_executions = var.writer_reserved_concurrency

  environment {
    variables = {
      AMP_WORKSPACE_ID          = aws_prometheus_workspace.this.id
      AMP_REMOTE_WRITE_ENDPOINT = local.amp_remote_write_endpoint
      AMP_QUERY_ENDPOINT        = local.amp_query_endpoint
      TELEMETRY_QUEUE_URL       = var.telemetry_queue_url
      ENVIRONMENT               = var.environment
      ALLOWED_PROMETHEUS_LABELS = local.writer_allowed_labels
      BLOCKED_PROMETHEUS_LABELS = local.writer_blocked_labels
    }
  }

  tags = merge(var.tags, {
    Name      = local.writer_function_name
    Component = "telemetry-writer"
  })

  depends_on = [
    aws_cloudwatch_log_group.writer
  ]
}

resource "aws_lambda_event_source_mapping" "telemetry_queue" {
  count = var.enable_writer_event_source_mapping ? 1 : 0

  event_source_arn                   = var.telemetry_queue_arn
  function_name                      = aws_lambda_function.writer.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = var.maximum_batching_window_in_seconds
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_cloudwatch_metric_alarm" "writer_errors" {
  alarm_name          = "${local.writer_function_name}-errors"
  alarm_description   = "Telemetry Writer Lambda reported errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.writer_error_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.writer.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "writer_duration" {
  alarm_name          = "${local.writer_function_name}-duration-near-timeout"
  alarm_description   = "Telemetry Writer Lambda duration is close to timeout."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.writer_duration_alarm_threshold_ms
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.writer.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  alarm_name          = "${var.name_prefix}-writer-telemetry-queue-backlog"
  alarm_description   = "Telemetry queue has visible backlog."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.sqs_backlog_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = local.telemetry_queue_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "sqs_queue_age" {
  alarm_name          = "${var.name_prefix}-writer-telemetry-queue-age"
  alarm_description   = "Oldest telemetry queue message age threatens prediction lead time."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.sqs_queue_age_alarm_threshold_seconds
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = local.telemetry_queue_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  count = var.telemetry_dlq_name == null ? 0 : 1

  alarm_name          = "${var.name_prefix}-writer-telemetry-dlq-visible-messages"
  alarm_description   = "Telemetry DLQ has messages requiring triage."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.dlq_visible_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.telemetry_dlq_name
  }

  tags = var.tags
}
