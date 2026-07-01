data "aws_caller_identity" "current" {}

locals {
  audit_table_name       = coalesce(var.audit_table_name, "${var.name_prefix}-audit")
  grafana_workspace_name = coalesce(var.grafana_workspace_name, "${var.name_prefix}-grafana")
}

# -----------------------------------------------------------------------------
# DynamoDB audit table
# Partition key: tenant_id#service_id (logical tenant isolation enforced at
# the ingest/application layer, not via DynamoDB IAM conditions).
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
# Grafana
# Two modes:
#   1. create_grafana_workspace = true  -> create aws_grafana_workspace
#   2. create_grafana_workspace = false  -> reference mode, use var.grafana_workspace_id
# This module does NOT own the Grafana service-account token secret. The secret
# is created by the security module (owner: Quyết) and passed in as
# var.grafana_secret_arn, so Terraform state never holds the token and there is
# no ownership/duplicate conflict with the security module.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "grafana_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "grafana_workspace" {
  count = var.create_grafana_workspace ? 1 : 0

  name               = "${var.name_prefix}-grafana-workspace-role"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume_role.json
  description        = "Service role used by Amazon Managed Grafana to query CDO08 AMP data."

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-grafana-workspace-role"
    Role = "grafana-workspace-service-role"
  })
}

data "aws_iam_policy_document" "grafana_workspace" {
  statement {
    sid    = "ListPrometheusWorkspaces"
    effect = "Allow"

    actions = [
      "aps:ListWorkspaces"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "QueryPrometheusWorkspace"
    effect = "Allow"

    actions = [
      "aps:DescribeWorkspace",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics"
    ]

    resources = var.amp_workspace_id != null ? [
      "arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/${var.amp_workspace_id}"
    ] : ["*"]
  }
}

resource "aws_iam_role_policy" "grafana_workspace" {
  count = var.create_grafana_workspace ? 1 : 0

  name   = "${var.name_prefix}-grafana-workspace-policy"
  role   = aws_iam_role.grafana_workspace[0].id
  policy = data.aws_iam_policy_document.grafana_workspace.json
}

resource "aws_grafana_workspace" "this" {
  count                    = var.create_grafana_workspace ? 1 : 0
  name                     = local.grafana_workspace_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana_workspace[0].arn
  data_sources             = var.amp_workspace_id != null ? ["PROMETHEUS"] : []
  description              = "CDO08 sandbox Grafana overlay for prediction/fallback annotations."

  depends_on = [
    aws_iam_role_policy.grafana_workspace
  ]

  tags = merge(var.tags, {
    Name = local.grafana_workspace_name
    Role = "dashboard-overlay"
  })
}

locals {
  grafana_workspace_id = var.create_grafana_workspace ? aws_grafana_workspace.this[0].id : var.grafana_workspace_id
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
            aws_cloudwatch_metric_alarm.audit_write_error.arn,
            aws_cloudwatch_metric_alarm.annotation_error.arn,
            aws_cloudwatch_metric_alarm.fallback_count_spike.arn
          ]
        }
      }
    ]
  })
}
