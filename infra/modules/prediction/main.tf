locals {
  prediction_lambda_name      = "${var.name_prefix}-prediction-lambda"
  serving_adapter_lambda_name = "${var.name_prefix}-serving-adapter-lambda"
  fallback_lambda_name        = "${var.name_prefix}-fallback-lambda"

  amp_workspace_resource = var.amp_workspace_arn != null ? var.amp_workspace_arn : "arn:aws:aps:${var.aws_region}:*:workspace/placeholder"
  audit_table_resource   = var.audit_table_arn != null ? var.audit_table_arn : "arn:aws:dynamodb:${var.aws_region}:*:table/placeholder-audit"
}
# IAM EventBridge
resource "aws_iam_role" "scheduler_role" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler_policy" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-scheduler-policy"
  role  = aws_iam_role.scheduler_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunction"
      ]
      Resource = aws_lambda_function.prediction_lambda[0].arn
    }]
  })
}

#IAM Lambda Prediction
resource "aws_iam_role" "prediction_lambda_role" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-prediction-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "prediction_lambda_policy" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-prediction-lambda-policy"
  role  = aws_iam_role.prediction_lambda_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.prediction_lambda_name}:*"
      },
      {
        Sid    = "QueryAmpWorkspace"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = local.amp_workspace_resource
      },
      {
        Sid    = "InvokeServingAdapterOnly"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.serving_adapter_lambda[0].arn
      },
      {
        Sid    = "WriteAuditRecord"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = local.audit_table_resource
      },
      {
        Sid    = "ReadGrafanaTokenIfNeeded"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.grafana_api_token_secret_arn != null ? var.grafana_api_token_secret_arn : "arn:aws:secretsmanager:${var.aws_region}:*:secret:placeholder-grafana-*"
      }
    ]
  })
}

resource "aws_iam_role" "serving_adapter_lambda_role" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-serving-adapter-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# IAM Lambda Serving adpater
resource "aws_iam_role_policy" "serving_adapter_lambda_policy" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-serving-adapter-lambda-policy"
  role  = aws_iam_role.serving_adapter_lambda_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "WriteLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.serving_adapter_lambda_name}:*"
        },
        {
          Sid    = "InvokeFallbackLambda"
          Effect = "Allow"
          Action = [
            "lambda:InvokeFunction"
          ]
          Resource = aws_lambda_function.fallback_lambda[0].arn
        }
      ],
      var.ai_engine_invoke_arn != null ? [
        {
          Sid    = "InvokeAiEngineIfApiManaged"
          Effect = "Allow"
          Action = [
            "execute-api:Invoke"
          ]
          Resource = var.ai_engine_invoke_arn
        }
      ] : []
    )
  })
}

# IAM Lambda Fallback
resource "aws_iam_role" "fallback_lambda_role" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-fallback-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fallback_lambda_policy" {
  count = var.enable_prediction ? 1 : 0
  name  = "${var.name_prefix}-fallback-lambda-policy"
  role  = aws_iam_role.fallback_lambda_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.fallback_lambda_name}:*"
      },
      {
        Sid    = "QueryAmpWorkspace"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = local.amp_workspace_resource
      },
      {
        Sid    = "WriteAuditRecord"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = local.audit_table_resource
      },
      {
        Sid    = "ReadGrafanaTokenIfNeeded"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.grafana_api_token_secret_arn != null ? var.grafana_api_token_secret_arn : "arn:aws:secretsmanager:${var.aws_region}:*:secret:placeholder-grafana-*"
      }
    ]
  })
}

#CloudWatch log group
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

  filename         = var.prediction_lambda_package_path
  source_code_hash = filebase64sha256(var.prediction_lambda_package_path)
  function_name    = local.prediction_lambda_name
  role             = aws_iam_role.prediction_lambda_role[0].arn
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

  filename         = var.serving_adapter_lambda_package_path
  source_code_hash = filebase64sha256(var.serving_adapter_lambda_package_path)
  function_name    = local.serving_adapter_lambda_name
  role             = aws_iam_role.serving_adapter_lambda_role[0].arn
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

  filename         = var.fallback_lambda_package_path
  source_code_hash = filebase64sha256(var.fallback_lambda_package_path)
  function_name    = local.fallback_lambda_name
  role             = aws_iam_role.fallback_lambda_role[0].arn
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
    role_arn = aws_iam_role.scheduler_role[0].arn

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
  source_arn    = "arn:aws:scheduler:${var.aws_region}:*:schedule/default/${var.name_prefix}-predict-*"
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