locals {
  prediction_lambda_name      = "${var.name_prefix}-prediction-lambda"
  serving_adapter_lambda_name = "${var.name_prefix}-serving-adapter-lambda"
  fallback_lambda_name        = "${var.name_prefix}-fallback-lambda"
}
data "aws_caller_identity" "current" {}

data "archive_file" "prediction_lambda" {
  count       = var.enable_prediction ? 1 : 0
  type        = "zip"
  source_dir  = var.prediction_source_dir
  output_path = "${path.root}/.terraform/prediction.zip"
}

data "archive_file" "serving_adapter_lambda" {
  count       = var.enable_prediction ? 1 : 0
  type        = "zip"
  source_dir  = var.serving_adapter_source_dir
  output_path = "${path.root}/.terraform/serving-adapter.zip"
}

data "archive_file" "fallback_lambda" {
  count       = var.enable_prediction ? 1 : 0
  type        = "zip"
  source_dir  = var.fallback_source_dir
  output_path = "${path.root}/.terraform/fallback.zip"
}

# CloudWatch log groups
resource "aws_cloudwatch_log_group" "prediction_lambda_logs" {
  count             = var.enable_prediction ? 1 : 0
  name              = "/aws/lambda/${local.prediction_lambda_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "serving_adapter_lambda_logs" {
  count             = var.enable_prediction ? 1 : 0
  name              = "/aws/lambda/${local.serving_adapter_lambda_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "fallback_lambda_logs" {
  count             = var.enable_prediction ? 1 : 0
  name              = "/aws/lambda/${local.fallback_lambda_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

#Prediction Lambda
resource "aws_lambda_function" "prediction_lambda" {
  count = var.enable_prediction ? 1 : 0

  filename         = data.archive_file.prediction_lambda[0].output_path
  source_code_hash = data.archive_file.prediction_lambda[0].output_base64sha256
  function_name    = local.prediction_lambda_name
  role             = var.prediction_role_arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = var.prediction_lambda_timeout_seconds
  memory_size      = var.prediction_lambda_memory_size

  environment {
    variables = {
      AMP_WORKSPACE_ID            = var.amp_workspace_id != null ? var.amp_workspace_id : "placeholder"
      AMP_QUERY_ENDPOINT          = var.amp_query_endpoint != null ? var.amp_query_endpoint : "placeholder"
      AUDIT_TABLE_NAME            = var.audit_table_name != null ? var.audit_table_name : "placeholder-audit"
      SERVING_ADAPTER_LAMBDA_NAME = local.serving_adapter_lambda_name
      LOOKBACK_MINUTES            = tostring(var.lookback_minutes)
      PREDICTION_INTERVAL_MINUTES = tostring(var.prediction_interval_minutes)
      LOG_LEVEL                   = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.prediction_lambda_logs
  ]

  tags = var.tags
}

# Lambda Serving Adapter
resource "aws_lambda_function" "serving_adapter_lambda" {
  count = var.enable_prediction ? 1 : 0

  filename         = data.archive_file.serving_adapter_lambda[0].output_path
  source_code_hash = data.archive_file.serving_adapter_lambda[0].output_base64sha256
  function_name    = local.serving_adapter_lambda_name
  role             = var.serving_adapter_role_arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = var.serving_adapter_lambda_timeout_seconds
  memory_size      = var.serving_adapter_lambda_memory_size

  environment {
    variables = {
      AI_ENGINE_ENDPOINT   = var.ai_engine_endpoint != null ? var.ai_engine_endpoint : "placeholder"
      FALLBACK_LAMBDA_NAME = local.fallback_lambda_name
      LOG_LEVEL            = "INFO"
      ADAPTER_MODE         = "separate-lambda"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.serving_adapter_lambda_logs
  ]

  tags = var.tags
}

# Lambda FallBack
resource "aws_lambda_function" "fallback_lambda" {
  count = var.enable_prediction ? 1 : 0

  filename         = data.archive_file.fallback_lambda[0].output_path
  source_code_hash = data.archive_file.fallback_lambda[0].output_base64sha256
  function_name    = local.fallback_lambda_name
  role             = var.fallback_role_arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = var.fallback_lambda_timeout_seconds
  memory_size      = var.fallback_lambda_memory_size

  environment {
    variables = {
      AMP_WORKSPACE_ID   = var.amp_workspace_id != null ? var.amp_workspace_id : "placeholder"
      AMP_QUERY_ENDPOINT = var.amp_query_endpoint != null ? var.amp_query_endpoint : "placeholder"
      AUDIT_TABLE_NAME   = var.audit_table_name != null ? var.audit_table_name : "placeholder-audit"
      LOOKBACK_MINUTES   = tostring(var.lookback_minutes)
      LOG_LEVEL          = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.fallback_lambda_logs
  ]

  tags = var.tags
}

# EventBridge Scheduler
resource "aws_scheduler_schedule" "prediction_schedule" {
  for_each = var.enable_prediction ? {
    for service in var.service_list : service.service_id => service
    if service.enabled
  } : {}

  name                         = "${var.name_prefix}-predict-${each.value.service_id}"
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.prediction_lambda[0].arn
    role_arn = var.scheduler_role_arn

    input = jsonencode({
      service_id       = each.value.service_id
      tenant_id        = each.value.tenant_id
      lookback_minutes = var.lookback_minutes
      scheduled_at     = "$${aws:ScheduledTime}"
    })
  }
}

resource "aws_lambda_permission" "allow_scheduler_invoke" {
  count         = var.enable_prediction ? 1 : 0
  statement_id  = "${var.name_prefix}-allow-scheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.prediction_lambda[0].function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/default/${var.name_prefix}-predict-*"
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "prediction_lambda_errors" {
  count               = var.enable_prediction ? 1 : 0
  alarm_name          = "${var.name_prefix}-prediction-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when Prediction Lambda has errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.prediction_lambda[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "serving_adapter_lambda_errors" {
  count               = var.enable_prediction ? 1 : 0
  alarm_name          = "${var.name_prefix}-serving-adapter-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when Serving Adapter Lambda has errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.serving_adapter_lambda[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "fallback_lambda_errors" {
  count               = var.enable_prediction ? 1 : 0
  alarm_name          = "${var.name_prefix}-fallback-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when Fallback Lambda has errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.fallback_lambda[0].function_name
  }

  tags = var.tags
}
