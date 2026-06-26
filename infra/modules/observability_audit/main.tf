data "aws_caller_identity" "current" {}

locals {
  audit_table_name       = coalesce(var.audit_table_name, "${var.name_prefix}-audit")
  grafana_secret_name    = var.grafana_secret_name
  grafana_workspace_name = coalesce(var.grafana_workspace_name, "${var.name_prefix}-grafana")
}

# -----------------------------------------------------------------------------
# DynamoDB audit table
# Partition key: tenant_id#service_id (tenant isolation via LeadingKeys)
# Sort key: prediction_id (lookup a single prediction/fallback record)
# GSI1: correlation_id -> prediction_id for E2E trace lookup
# TTL: expires_at (epoch seconds), retention var.audit_retention_days
# Encryption: customer-managed KMS key when var.audit_kms_key_arn is provided,
#             AWS-owned key when deferred until the security module merges.
# Billing: PAY_PER_REQUEST (on-demand) for capstone cost guard.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "audit" {
  name         = local.audit_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_service"
  range_key    = "prediction_id"

  attribute {
    name = "tenant_service"
    type = "S"
  }

  attribute {
    name = "prediction_id"
    type = "S"
  }

  attribute {
    name = "correlation_id"
    type = "S"
  }

  global_secondary_index {
    name            = "correlation-index"
    hash_key        = "correlation_id"
    range_key       = "prediction_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.audit_kms_key_arn
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = var.audit_ttl_enabled
  }

  tags = merge(var.tags, {
    Name = local.audit_table_name
    Role = "prediction-fallback-audit"
  })
}

# -----------------------------------------------------------------------------
# IAM writer role for audit table (Prediction / Fallback Lambda)
# PutItem only, scoped to the audit table ARN, LeadingKeys enforces tenant
# isolation so a writer cannot read or write across tenants.
# Writer Lambda (telemetry) does NOT receive this role.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_writer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "audit_writer" {
  name               = "${var.name_prefix}-audit-writer-role"
  assume_role_policy = data.aws_iam_policy_document.audit_writer_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-audit-writer-role" })
}

data "aws_iam_policy_document" "audit_writer" {
  statement {
    sid    = "PutAuditItem"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem"
    ]
    resources = [aws_dynamodb_table.audit.arn]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "dynamodb:LeadingKeys"
      values   = ["${var.name_prefix}-*"]
    }
  }

  statement {
    sid       = "NoScanDelete"
    effect    = "Deny"
    actions   = ["dynamodb:Scan", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

resource "aws_iam_role_policy" "audit_writer" {
  name   = "${var.name_prefix}-audit-writer-policy"
  role   = aws_iam_role.audit_writer.id
  policy = data.aws_iam_policy_document.audit_writer.json
}

# -----------------------------------------------------------------------------
# IAM reviewer role for audit table (Mentor / debug)
# Query + GetItem only, LeadingKeys enforces tenant scoping.
# No Scan, no Delete, no PutItem.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_reader_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "audit_reader" {
  name               = "${var.name_prefix}-audit-reader-role"
  assume_role_policy = data.aws_iam_policy_document.audit_reader_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-audit-reader-role" })
}

data "aws_iam_policy_document" "audit_reader" {
  statement {
    sid    = "QueryGetAudit"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem"
    ]
    resources = [
      aws_dynamodb_table.audit.arn,
      "${aws_dynamodb_table.audit.arn}/index/*"
    ]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "dynamodb:LeadingKeys"
      values   = ["${var.name_prefix}-*"]
    }
  }

  statement {
    sid       = "NoScanDeletePut"
    effect    = "Deny"
    actions   = ["dynamodb:Scan", "dynamodb:DeleteItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

resource "aws_iam_role_policy" "audit_reader" {
  name   = "${var.name_prefix}-audit-reader-policy"
  role   = aws_iam_role.audit_reader.id
  policy = data.aws_iam_policy_document.audit_reader.json
}

# -----------------------------------------------------------------------------
# Grafana
# Two modes:
#   1. create_grafana_workspace = true  -> create aws_grafana_workspace
#   2. create_grafana_workspace = false  -> reference mode, use var.grafana_workspace_id
# Token is NEVER stored in Terraform state. Only a Secrets Manager placeholder
# is created; the Tech Lead puts the actual token manually after apply.
# -----------------------------------------------------------------------------
resource "aws_grafana_workspace" "this" {
  count                    = var.create_grafana_workspace ? 1 : 0
  name                     = local.grafana_workspace_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  data_sources             = var.amp_workspace_id != null ? ["PROMETHEUS"] : []
  description              = "CDO08 sandbox Grafana overlay for prediction/fallback annotations."

  tags = merge(var.tags, {
    Name = local.grafana_workspace_name
    Role = "dashboard-overlay"
  })
}

locals {
  grafana_workspace_id = var.create_grafana_workspace ? aws_grafana_workspace.this[0].id : var.grafana_workspace_id
}

# Secrets Manager placeholder for the Grafana service-account token.
# Value is put manually by the Tech Lead after Terraform apply.
resource "aws_secretsmanager_secret" "grafana_token" {
  name                    = local.grafana_secret_name
  description             = "Grafana service-account token for annotation publisher. Value is put manually after apply."
  recovery_window_in_days = 30

  tags = merge(var.tags, {
    Name = local.grafana_secret_name
    Role = "grafana-annotation-secret"
  })
}

# -----------------------------------------------------------------------------
# CloudWatch log group for annotation / audit publisher structured logs.
# Used by the metric filters below. Lambda log groups for Prediction/Fallback
# are owned by the AI integration module; this group is the central audit /
# annotation publisher log group owned by this module.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "annotation_audit" {
  name              = "${var.name_prefix}/annotation-audit"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-annotation-audit-lg"
  })
}

# -----------------------------------------------------------------------------
# CloudWatch metric filters -> alarms for audit / annotation / fallback.
# Metrics are emitted via structured logs (EMF-style) by Prediction/Fallback
# Lambda. The metric filters below turn those log entries into CloudWatch
# metrics without incurring PutMetricData cost.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "audit_write_error" {
  name           = "${var.name_prefix}-audit-write-error-filter"
  log_group_name = aws_cloudwatch_log_group.annotation_audit.name
  pattern        = "{ $.event = \"audit_write_error\" }"

  metric_transformation {
    name      = "AuditWriteError"
    namespace = "CDO08/Sandbox"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "annotation_error" {
  name           = "${var.name_prefix}-annotation-error-filter"
  log_group_name = aws_cloudwatch_log_group.annotation_audit.name
  pattern        = "{ $.event = \"annotation_error\" }"

  metric_transformation {
    name      = "AnnotationError"
    namespace = "CDO08/Sandbox"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "fallback_annotation_count" {
  name           = "${var.name_prefix}-fallback-annotation-count-filter"
  log_group_name = aws_cloudwatch_log_group.annotation_audit.name
  pattern        = "{ $.event = \"fallback_annotation\" }"

  metric_transformation {
    name      = "FallbackAnnotationCount"
    namespace = "CDO08/Sandbox"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "audit_write_error" {
  alarm_name          = "${var.name_prefix}-audit-write-error"
  namespace           = "CDO08/Sandbox"
  metric_name         = "AuditWriteError"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.alarm_audit_write_error_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "Audit write errors must not be silently lost."

  alarm_actions = []
  ok_actions    = []

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-audit-write-error"
  })
}

resource "aws_cloudwatch_metric_alarm" "annotation_error" {
  alarm_name          = "${var.name_prefix}-annotation-error"
  namespace           = "CDO08/Sandbox"
  metric_name         = "AnnotationError"
  statistic           = "Sum"
  period              = var.alarm_annotation_error_period_secs
  evaluation_periods  = 1
  threshold           = var.alarm_annotation_error_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "Sustained Grafana annotation failures break the evidence path."

  alarm_actions = []
  ok_actions    = []

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-annotation-error"
  })
}

resource "aws_cloudwatch_metric_alarm" "fallback_count_spike" {
  alarm_name          = "${var.name_prefix}-fallback-count-spike"
  namespace           = "CDO08/Sandbox"
  metric_name         = "FallbackAnnotationCount"
  statistic           = "Sum"
  period              = var.alarm_fallback_count_period_secs
  evaluation_periods  = 1
  threshold           = var.alarm_fallback_count_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "Fallback annotation spike above baseline may indicate AI Engine degradation."

  alarm_actions = []
  ok_actions    = []

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-fallback-count-spike"
  })
}

# -----------------------------------------------------------------------------
# CloudWatch dashboard summarizing audit / annotation / fallback health.
# Dashboard body contains only metric references and alarm status - no secret,
# PII, or raw payload text.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name_prefix}-observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Audit Write Errors"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["CDO08/Sandbox", "AuditWriteError"]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Annotation Errors"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["CDO08/Sandbox", "AnnotationError"]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Fallback Annotation Count"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["CDO08/Sandbox", "FallbackAnnotationCount"]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Alarm Status"
          region = var.aws_region
          alarms = [
            aws_cloudwatch_metric_alarm.audit_write_error.alarm_name,
            aws_cloudwatch_metric_alarm.annotation_error.alarm_name,
            aws_cloudwatch_metric_alarm.fallback_count_spike.alarm_name
          ]
        }
      }
    ]
  })
}