
# -----------------------------------------------------------------------------
# Module: synthetic_generator
# Owner:  Thuy (CDO08)
#
# Resources created:
#   - ECR repository for generator image
#   - ECS cluster (generator-dedicated; no shared cluster exists yet)
#   - CloudWatch log group  /ecs/cdo08-sandbox-generator
#   - IAM task execution role  (pull ECR + write CW logs)
#   - IAM task role           (invoke telemetry API only; no direct AMP write)
#   - ECS task definition
#
# Resources NOT created here (owned elsewhere):
#   - VPC / subnets / security groups  → module.networking
#   - API Gateway / SQS / AMP          → module.telemetry_ingest / module.telemetry_store
#   - KMS / Secrets Manager baseline   → module.security
#
# How to trigger a generator run:
#   aws ecs run-task \
#     --cluster <cluster_arn_from_output> \
#     --task-definition <task_definition_arn_from_output> \
#     --launch-type FARGATE \
#     --network-configuration "awsvpcConfiguration={subnets=[<private_subnet_id>],securityGroups=[<generator_sg_id>],assignPublicIp=DISABLED}" \
#     --overrides '{"containerOverrides":[{"name":"generator","environment":[{"name":"SCENARIO","value":"gradual_drift"}]}]}'
#
# The task is designed as a run-once/on-demand job per test window; it does NOT
# run 24/7 to contain costs.  Use the scheduled_task_rule (disabled by default)
# in this file to enable time-bounded test windows.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ECR repository — stores the generator container image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "generator" {
  name                 = "${var.name_prefix}-generator"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-ecr"
    Component = "synthetic-generator"
  })
}

resource "aws_ecr_lifecycle_policy" "generator" {
  repository = aws_ecr_repository.generator.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 tagged images; expire untagged after 1 day."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain only the last 5 images to bound storage cost."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "generator" {
  name              = "/ecs/cdo08-sandbox-generator"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name      = "/ecs/cdo08-sandbox-generator"
    Component = "synthetic-generator"
  })
}

# ---------------------------------------------------------------------------
# IAM — task execution role
# Allows ECS agent to pull ECR images and write to CloudWatch Logs.
# Does NOT grant any application-level AWS permissions.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-generator-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  description        = "ECS task execution role for synthetic generator — pulls ECR image, writes CW logs."

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-execution-role"
    Component = "synthetic-generator"
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow pulling from this specific ECR repository only
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "ECRPullGeneratorImage"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.generator.arn]
  }

  statement {
    sid     = "ECRAuthToken"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    # ecr:GetAuthorizationToken is account-scoped, resource must be "*"
    resources = ["*"] # tslint:disable-line  — AWS-required wildcard
  }
}

resource "aws_iam_role_policy" "ecr_pull" {
  name   = "${var.name_prefix}-generator-ecr-pull"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.ecr_pull.json
}

# ---------------------------------------------------------------------------
# IAM — task role
# Grants ONLY the ability for the running container to call the telemetry
# ingest API endpoint.  No direct AMP write, no admin/wildcard permissions.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_role" {
  name               = "${var.name_prefix}-generator-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  description        = "IAM task role for synthetic generator — may only invoke the telemetry ingest API. No AMP write, no admin."

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-task-role"
    Component = "synthetic-generator"
  })
}

data "aws_iam_policy_document" "task_role_permissions" {
  # Allow calling the API Gateway telemetry ingest endpoint via IAM auth.
  # Resource is scoped to POST /v1/ingest on the specific API; once
  # Phuong's telemetry_ingest module merges, replace the placeholder ARN
  # with the actual module output.
  statement {
    sid    = "InvokeTelemetryIngestAPI"
    effect = "Allow"
    actions = [
      "execute-api:Invoke",
    ]
    # Scoped to POST method on /v1/ingest of the ingest API only.
    # Format: arn:aws:execute-api:<region>:<account>:<api-id>/<stage>/POST/ingest
    # Update once telemetry_ingest module is merged; use a placeholder for now.
    resources = [
      "arn:aws:execute-api:${var.aws_region}:${var.aws_account_id}:*/*/POST/ingest",
    ]
  }

  # Allow writing logs — containers write directly via awslogs driver,
  # but explicit permission is a defence-in-depth measure.
  statement {
    sid    = "WriteCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.generator.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "task_role_permissions" {
  name   = "${var.name_prefix}-generator-task-permissions"
  role   = aws_iam_role.task_role.id
  policy = data.aws_iam_policy_document.task_role_permissions.json
}

# ---------------------------------------------------------------------------
# ECS cluster — dedicated to the synthetic generator
# (No shared cluster exists; a lightweight cluster is appropriate here)
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "generator" {
  name = "${var.name_prefix}-generator-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # Avoid extra CloudWatch cost in sandbox
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-cluster"
    Component = "synthetic-generator"
  })
}

resource "aws_ecs_cluster_capacity_providers" "generator" {
  cluster_name = aws_ecs_cluster.generator.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ---------------------------------------------------------------------------
# ECS task definition
# ---------------------------------------------------------------------------

locals {
  # Use the provided image URI, or fall back to a placeholder string that
  # makes the plan readable while the real image is not yet built.
  effective_image = var.generator_image_uri != "" ? var.generator_image_uri : "IMAGE_NOT_YET_BUILT_SEE_PR"

  container_definition = [
    {
      name      = "generator"
      image     = local.effective_image
      essential = true

      # Resource limits — matches task-level CPU/memory allocation
      cpu    = var.task_cpu
      memory = var.task_memory

      # Run as non-root where the base image supports it
      user = "1000"

      # No inbound ports required; generator only makes outbound HTTPS calls
      portMappings = []

      environment = [
        { name = "TENANT_ID", value = var.tenant_id },
        { name = "SERVICE_LIST", value = var.service_list },
        { name = "SCENARIO_LIST", value = var.scenario_list },
        { name = "EMIT_INTERVAL_SECONDS", value = tostring(var.emit_interval_seconds) },
        # INGEST_API_ENDPOINT carries a placeholder until Phuong's module merges.
        # Update sandbox/main.tf to wire module.telemetry_ingest.ingest_api_url here.
        { name = "INGEST_API_ENDPOINT", value = var.ingest_api_endpoint },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      # Secrets/credentials: generator uses the task IAM role for SigV4 auth;
      # no static AWS credentials are injected here (satisfies security design §2).

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.generator.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      readonlyRootFilesystem = true

      # No privileged mode
      privileged = false
    }
  ]
}

resource "aws_ecs_task_definition" "generator" {
  family                   = "${var.name_prefix}-generator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode(local.container_definition)

  # Ephemeral storage default (20 GiB) is sufficient for a stateless generator.

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-task-def"
    Component = "synthetic-generator"
  })
}

# ---------------------------------------------------------------------------
# Optional: EventBridge Scheduled Rule (DISABLED by default)
#
# Enable this only during a bounded test window (e.g., ≥2 hour scenario run).
# Default state = DISABLED so the task does not run 24/7 and avoids cost abuse.
#
# To enable for a test window:
#   1. Set schedule_enabled = true in the module call in sandbox/main.tf, OR
#   2. Manually enable the rule via AWS Console / CLI:
#        aws events enable-rule --name <rule_name>
#   3. Disable again after the test window completes.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "generator_schedule" {
  name                = "${var.name_prefix}-generator-schedule"
  description         = "Periodic trigger for synthetic generator task (disabled outside test windows)."
  schedule_expression = "rate(1 hour)"
  state               = "DISABLED" # Must be ENABLED manually for test windows only

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-schedule"
    Component = "synthetic-generator"
  })
}

resource "aws_cloudwatch_event_target" "generator_schedule" {
  rule      = aws_cloudwatch_event_rule.generator_schedule.name
  target_id = "GeneratorECSTask"
  arn       = aws_ecs_cluster.generator.arn
  role_arn  = aws_iam_role.events_ecs.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.generator.arn
    task_count          = 1
    launch_type         = "FARGATE"

    network_configuration {
      subnets          = var.private_subnet_ids
      security_groups  = [var.generator_security_group_id]
      assign_public_ip = false # No public inbound; outbound via SG egress rule
    }
  }
}

# IAM role that allows EventBridge to launch ECS tasks
data "aws_iam_policy_document" "events_assume" {
  statement {
    sid     = "EventBridgeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_ecs" {
  name               = "${var.name_prefix}-generator-events-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  description        = "IAM role allowing EventBridge to launch generator ECS tasks."

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-generator-events-role"
    Component = "synthetic-generator"
  })
}

data "aws_iam_policy_document" "events_ecs_permissions" {
  statement {
    sid    = "RunGeneratorTask"
    effect = "Allow"
    actions = [
      "ecs:RunTask",
    ]
    resources = [aws_ecs_task_definition.generator.arn]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.generator.arn]
    }
  }

  # EventBridge must pass the task execution and task roles when launching the task
  statement {
    sid    = "PassTaskRoles"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.task_execution.arn,
      aws_iam_role.task_role.arn,
    ]
  }
}

resource "aws_iam_role_policy" "events_ecs_permissions" {
  name   = "${var.name_prefix}-generator-events-permissions"
  role   = aws_iam_role.events_ecs.id
  policy = data.aws_iam_policy_document.events_ecs_permissions.json
}
