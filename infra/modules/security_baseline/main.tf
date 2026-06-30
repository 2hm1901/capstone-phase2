data "aws_caller_identity" "current" {}

# ==============================================================================
# 1. KMS CUSTOMER MANAGED KEY (CMK)
# ==============================================================================

resource "aws_kms_key" "security" {
  description             = "Customer Managed Key for CDO08 platform sensitive data"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs access"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow DynamoDB access"
        Effect = "Allow"
        Principal = {
          Service = "dynamodb.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "security" {
  name          = "alias/${var.name_prefix}-kms-key"
  target_key_id = aws_kms_key.security.key_id
}

# ==============================================================================
# 2. S3 BUCKET FOR AI BASELINES
# ==============================================================================

resource "aws_s3_bucket" "ai_baselines" {
  bucket        = "${var.name_prefix}-ai-baselines-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "ai_baselines" {
  bucket = aws_s3_bucket.ai_baselines.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ai_baselines" {
  bucket = aws_s3_bucket.ai_baselines.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ai_baselines" {
  bucket = aws_s3_bucket.ai_baselines.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.security.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "ai_baselines" {
  bucket = aws_s3_bucket.ai_baselines.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "ai_baselines_tls_only" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.ai_baselines.arn,
      "${aws_s3_bucket.ai_baselines.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "ai_baselines_tls" {
  bucket = aws_s3_bucket.ai_baselines.id
  policy = data.aws_iam_policy_document.ai_baselines_tls_only.json
}

# ==============================================================================
# 3. SECRETS MANAGER PLACEHOLDERS
# ==============================================================================

resource "aws_secretsmanager_secret" "grafana_token" {
  name                    = "${var.name_prefix}-grafana-token"
  recovery_window_in_days = 0 # Force immediate deletion for development/sandbox
  tags                    = var.tags
}


# ==============================================================================
# 4. SSM PARAMETERS
# ==============================================================================

resource "aws_ssm_parameter" "amp_workspace_id" {
  name  = "/${var.name_prefix}/amp/workspace_id"
  type  = "String"
  value = "placeholder-amp-workspace-id"
  tags  = var.tags
}

resource "aws_ssm_parameter" "ai_endpoint" {
  name  = "/${var.name_prefix}/ai/endpoint"
  type  = "String"
  value = "placeholder-ai-endpoint"
  tags  = var.tags
}

resource "aws_ssm_parameter" "ai_baseline_bucket" {
  name  = "/${var.name_prefix}/ai/baseline_bucket"
  type  = "String"
  value = aws_s3_bucket.ai_baselines.bucket
  tags  = var.tags
}

resource "aws_ssm_parameter" "ai_baseline_prefix" {
  name  = "/${var.name_prefix}/ai/baseline_prefix"
  type  = "String"
  value = "baselines/"
  tags  = var.tags
}

resource "aws_ssm_parameter" "ai_otel_endpoint" {
  name  = "/${var.name_prefix}/ai/otel_endpoint"
  type  = "String"
  value = "placeholder-otel-endpoint"
  tags  = var.tags
}

# ==============================================================================
# 5. CLOUDWATCH LOG GROUPS
# ==============================================================================

resource "aws_cloudwatch_log_group" "ai_engine_app" {
  name              = "/ecs/${var.name_prefix}-ai-engine-app"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "ai_engine_audit" {
  name              = "/ecs/${var.name_prefix}-ai-engine-audit"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.security.arn
  tags              = var.tags
}

# ==============================================================================
# 6. ECR REPOSITORY FOR AI ENGINE
# ==============================================================================

resource "aws_ecr_repository" "ai_engine" {
  name                 = "foresight-lens-engine"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# ==============================================================================
# 7. IAM ROLES & POLICIES (SEPARATED WORKLOADS)
# ==============================================================================

# ECS tasks assume role trust document
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Lambda functions assume role trust document
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Reviewer trust relationship document
data "aws_iam_policy_document" "reviewer_assume_role" {
  count = length(var.reviewer_principal_arns) > 0 ? 1 : 0
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.reviewer_principal_arns
    }
    actions = ["sts:AssumeRole"]
  }
}

# Scheduler trust relationship document
data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# AWS managed policy helper for standard log stream writing
data "aws_iam_policy_document" "cloudwatch_logs_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/*"
    ]
  }
}

# Helper policy to create log groups if they don't exist
data "aws_iam_policy_document" "cloudwatch_logs_create" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["*"]
  }
}

# ------------------------------------------------------------------------------
# 7.1. CDO-Generator-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "generator" {
  name               = "${var.name_prefix}-generator-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "generator" {
  statement {
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["arn:aws:execute-api:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*/*/POST/*"]
  }
}

resource "aws_iam_role_policy" "generator_policy" {
  name   = "generator-execution-policy"
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.generator.json
}

resource "aws_iam_role_policy" "generator_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

# ------------------------------------------------------------------------------
# 7.2. CDO-Ingest-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ingest" {
  name               = "${var.name_prefix}-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ingest" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = ["arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-telemetry"]
  }
}

resource "aws_iam_role_policy" "ingest_policy" {
  name   = "ingest-execution-policy"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_iam_role_policy" "ingest_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

# ------------------------------------------------------------------------------
# 7.3. CDO-Writer-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "writer" {
  name               = "${var.name_prefix}-writer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "writer" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:DeleteMessageBatch",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes"
    ]
    resources = ["arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["aps:RemoteWrite"]
    resources = ["arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/*"]
  }
}

resource "aws_iam_role_policy" "writer_policy" {
  name   = "writer-execution-policy"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.writer.json
}

resource "aws_iam_role_policy" "writer_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

# ------------------------------------------------------------------------------
# 7.4. CDO-Prediction-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "prediction" {
  name               = "${var.name_prefix}-prediction-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "prediction" {
  statement {
    effect = "Allow"
    actions = [
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics"
    ]
    resources = ["arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["arn:aws:execute-api:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }

  statement {
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-serving-adapter-lambda",
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-fallback-lambda"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-audit*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.grafana_token.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*"
    ]
    resources = [aws_kms_key.security.arn]
  }
}

resource "aws_iam_role_policy" "prediction_policy" {
  name   = "prediction-execution-policy"
  role   = aws_iam_role.prediction.id
  policy = data.aws_iam_policy_document.prediction.json
}

resource "aws_iam_role_policy" "prediction_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.prediction.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

resource "aws_iam_role_policy_attachment" "prediction_vpc_access" {
  role       = aws_iam_role.prediction.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ------------------------------------------------------------------------------
# 7.5. CDO-AI-Engine-Role (ECS Task Role)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ai_engine" {
  name               = "${var.name_prefix}-ai-engine-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ai_engine" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.ai_baselines.arn,
      "${aws_s3_bucket.ai_baselines.arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*"
    ]
    resources = [aws_kms_key.security.arn]
  }
}

resource "aws_iam_role_policy" "ai_engine_policy" {
  name   = "ai-engine-execution-policy"
  role   = aws_iam_role.ai_engine.id
  policy = data.aws_iam_policy_document.ai_engine.json
}

resource "aws_iam_role_policy" "ai_engine_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.ai_engine.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

# ------------------------------------------------------------------------------
# 7.6. CDO-Fallback-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "fallback" {
  name               = "${var.name_prefix}-fallback-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "fallback" {
  statement {
    effect = "Allow"
    actions = [
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics"
    ]
    resources = ["arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-audit*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.grafana_token.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*"
    ]
    resources = [aws_kms_key.security.arn]
  }
}

resource "aws_iam_role_policy" "fallback_policy" {
  name   = "fallback-execution-policy"
  role   = aws_iam_role.fallback.id
  policy = data.aws_iam_policy_document.fallback.json
}

resource "aws_iam_role_policy" "fallback_logs" {
  name   = "cloudwatch-logs-policy"
  role   = aws_iam_role.fallback.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

# ------------------------------------------------------------------------------
# 7.7. CDO-Scheduler-Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name   = "scheduler-execution-policy"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ------------------------------------------------------------------------------
# 7.8. CDO-Reviewer-Role (Read-Only)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "reviewer" {
  count              = length(var.reviewer_principal_arns) > 0 ? 1 : 0
  name               = "${var.name_prefix}-reviewer-role"
  assume_role_policy = data.aws_iam_policy_document.reviewer_assume_role[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "reviewer" {
  statement {
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics"
    ]
    resources = ["arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan"
    ]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-audit*"]
  }
}

# Explicit Deny Policy for Reviewer (Prevents reading secret values and deleting audit logs)
data "aws_iam_policy_document" "reviewer_deny" {
  statement {
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      aws_secretsmanager_secret.grafana_token.arn
    ]
  }

  statement {
    effect = "Deny"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:DeleteTable",
      "dynamodb:UpdateItem",
      "dynamodb:UpdateTable"
    ]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-audit*"]
  }
}

resource "aws_iam_role_policy" "reviewer_policy" {
  count  = length(var.reviewer_principal_arns) > 0 ? 1 : 0
  name   = "reviewer-read-policy"
  role   = aws_iam_role.reviewer[0].id
  policy = data.aws_iam_policy_document.reviewer.json
}

resource "aws_iam_role_policy" "reviewer_deny_policy" {
  count  = length(var.reviewer_principal_arns) > 0 ? 1 : 0
  name   = "reviewer-deny-policy"
  role   = aws_iam_role.reviewer[0].id
  policy = data.aws_iam_policy_document.reviewer_deny.json
}
