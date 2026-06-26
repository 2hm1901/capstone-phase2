
# Telemetry Dead Letter Queue

resource "aws_sqs_queue" "telemetry_dlq" {

  name = "${var.name_prefix}-telemetry-dlq"

  message_retention_seconds = var.queue_retention_seconds

  sqs_managed_sse_enabled = true

}


# Telemetry Queue


resource "aws_sqs_queue" "telemetry_queue" {

  name = "${var.name_prefix}-telemetry"

  visibility_timeout_seconds = var.visibility_timeout_seconds

  message_retention_seconds = var.queue_retention_seconds

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({

    deadLetterTargetArn = aws_sqs_queue.telemetry_dlq.arn

    maxReceiveCount = var.max_receive_count

  })

}


# Lambda Ingest IAM Role

resource "aws_iam_role" "ingest_lambda_role" {
  name = "${var.name_prefix}-ingest-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Lambda Ingest IAM Policy
# Least privilege:
# - SendMessage only to telemetry queue
# - Write CloudWatch Logs
# - No ReceiveMessage
# - No DeleteMessage
# - No AMP/DynamoDB/Secrets/Grafana/AI permission

resource "aws_iam_role_policy" "ingest_lambda_policy" {
  name = "${var.name_prefix}-ingest-lambda-policy"
  role = aws_iam_role.ingest_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSendMessageToTelemetryQueue"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.telemetry_queue.arn
      },
      {
        Sid    = "AllowCreateLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowWriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.ingest_lambda.arn}:*"
        ]
      }
    ]
  })
}


# CloudWatch Log Group for Lambda Ingest

resource "aws_cloudwatch_log_group" "ingest_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-ingest"
  retention_in_days = var.log_retention_days
}

# Lambda Ingest Function

resource "aws_lambda_function" "ingest" {
  function_name = "${var.name_prefix}-ingest"

  role    = aws_iam_role.ingest_lambda_role.arn
  handler = "index.handler"
  runtime = "python3.11"

  filename         = var.lambda_package_path
  source_code_hash = filebase64sha256(var.lambda_package_path)

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory

  environment {
    variables = {
      TELEMETRY_QUEUE_URL  = aws_sqs_queue.telemetry_queue.url
      AUTH_MODE            = var.auth_mode
      ALLOWED_METRIC_TYPES = var.allowed_metric_types
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ingest_lambda,
    aws_iam_role_policy.ingest_lambda_policy
  ]
}


# API Gateway HTTP API

resource "aws_apigatewayv2_api" "telemetry" {
  name          = "${var.name_prefix}-telemetry-api"
  protocol_type = "HTTP"
}

# Lambda integration for API Gateway

resource "aws_apigatewayv2_integration" "ingest_lambda" {
  api_id = aws_apigatewayv2_api.telemetry.id

  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingest.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# POST /v1/telemetry route

resource "aws_apigatewayv2_route" "telemetry_post" {
  api_id = aws_apigatewayv2_api.telemetry.id

  route_key = "POST /v1/telemetry"
  target    = "integrations/${aws_apigatewayv2_integration.ingest_lambda.id}"

  authorization_type = var.auth_mode == "IAM" ? "AWS_IAM" : "NONE"
}

# API Gateway stage

resource "aws_apigatewayv2_stage" "telemetry" {
  api_id = aws_apigatewayv2_api.telemetry.id
  name   = var.api_stage

  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_throttling_burst_limit
    throttling_rate_limit  = var.api_throttling_rate_limit
  }
}

# Permission for API Gateway to invoke Lambda

resource "aws_lambda_permission" "allow_apigw_invoke_ingest" {
  statement_id  = "AllowAPIGatewayInvokeIngest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.telemetry.execution_arn}/*/*"
}


# CloudWatch Alarm - Lambda Ingest Errors

resource "aws_cloudwatch_metric_alarm" "ingest_lambda_errors" {
  alarm_name          = "${var.name_prefix}-ingest-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alarm when Lambda Ingest has errors"

  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
  }
}

# CloudWatch Alarm - SQS Queue Age

resource "aws_cloudwatch_metric_alarm" "telemetry_queue_age" {
  alarm_name          = "${var.name_prefix}-telemetry-queue-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.alarm_queue_age_threshold_seconds
  alarm_description   = "Alarm when telemetry queue oldest message age is too high"

  dimensions = {
    QueueName = aws_sqs_queue.telemetry_queue.name
  }
}

# CloudWatch Alarm - DLQ Visible Messages

resource "aws_cloudwatch_metric_alarm" "telemetry_dlq_visible_messages" {
  alarm_name          = "${var.name_prefix}-telemetry-dlq-visible-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alarm when telemetry DLQ has visible messages"

  dimensions = {
    QueueName = aws_sqs_queue.telemetry_dlq.name
  }
}