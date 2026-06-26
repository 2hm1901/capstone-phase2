# This is the only deployable CDO08 environment.

locals {
  name_prefix = "cdo08-sandbox"

  common_tags = {
    Project     = "CDO08"
    Environment = "sandbox"
  }
}

module "networking" {
  source = "../../modules/networking"

  aws_region                  = var.aws_region
  name_prefix                 = local.name_prefix
  workload_vpc_cidr           = var.workload_vpc_cidr
  ai_engine_vpc_cidr          = var.ai_engine_vpc_cidr
  private_subnet_count        = var.private_subnet_count
  ai_engine_alb_ingress_cidrs = var.ai_engine_alb_ingress_cidrs
  tags                        = local.common_tags
}

data "archive_file" "ingest_placeholder" {
  type        = "zip"
  source_dir  = "../../packages/ingest_placeholder"
  output_path = "../../packages/ingest_placeholder.zip"
}

module "telemetry_ingest" {
  source = "../../modules/telemetry_ingest"

  name_prefix         = local.name_prefix
  api_stage           = "sandbox"
  auth_mode           = "IAM"
  lambda_package_path = data.archive_file.ingest_placeholder.output_path

  lambda_timeout              = 10
  lambda_memory               = 256
  ingest_reserved_concurrency = 10

  queue_retention_seconds    = 345600
  visibility_timeout_seconds = 60
  max_receive_count          = 5
  log_retention_days         = 14

  api_throttling_burst_limit = 1000
  api_throttling_rate_limit  = 1000
}

module "telemetry_store" {
  source = "../../modules/telemetry_store"

  name_prefix         = local.name_prefix
  environment         = "sandbox"
  amp_workspace_alias = "${local.name_prefix}-amp"

  # TODO: replace these placeholder variables with module.telemetry_ingest
  # outputs after Phuong's telemetry ingest module is merged. This module does
  # not create a duplicate telemetry SQS queue or DLQ.
  telemetry_queue_arn = module.telemetry_ingest.queue_arn
  telemetry_queue_url = module.telemetry_ingest.queue_url
  telemetry_dlq_name  = module.telemetry_ingest.dlq_name

  enable_writer_event_source_mapping = var.enable_writer_event_source_mapping

  writer_source_dir                     = "${path.module}/../../../src/writer"
  batch_size                            = var.writer_batch_size
  maximum_batching_window_in_seconds    = var.writer_maximum_batching_window_seconds
  writer_timeout_seconds                = var.writer_timeout_seconds
  writer_memory_size                    = var.writer_memory_size
  writer_reserved_concurrency           = var.writer_reserved_concurrency
  log_retention_days                    = var.writer_log_retention_days
  writer_duration_alarm_threshold_ms    = 25000
  sqs_queue_age_alarm_threshold_seconds = 300

  tags = local.common_tags
}

output "workload_vpc_id" {
  description = "ID of the synthetic workload/services VPC."
  value       = module.networking.workload_vpc_id
}

output "workload_private_subnet_ids" {
  description = "Private subnet IDs for synthetic workload services."
  value       = module.networking.workload_private_subnet_ids
}

output "ai_engine_vpc_id" {
  description = "ID of the AI Engine runtime VPC."
  value       = module.networking.ai_engine_vpc_id
}

output "ai_engine_private_subnet_ids" {
  description = "Private subnet IDs for AI Engine runtime."
  value       = module.networking.ai_engine_private_subnet_ids
}

output "ai_engine_public_subnet_ids" {
  description = "Public subnet IDs for the AI Engine application load balancer."
  value       = module.networking.ai_engine_public_subnet_ids
}

output "ai_engine_s3_endpoint_id" {
  description = "Gateway VPC endpoint ID for AI Engine access to S3 baseline storage."
  value       = module.networking.ai_engine_s3_endpoint_id
}

output "generator_security_group_id" {
  description = "Security group ID for synthetic generator tasks."
  value       = module.networking.generator_security_group_id
}

output "ai_engine_alb_security_group_id" {
  description = "Security group ID for the AI Engine application load balancer."
  value       = module.networking.ai_engine_alb_security_group_id
}

output "ai_engine_task_security_group_id" {
  description = "Security group ID for AI Engine ECS tasks."
  value       = module.networking.ai_engine_task_security_group_id
}

output "ai_engine_internet_gateway_id" {
  description = "Internet Gateway ID for the AI Engine VPC public ALB path."
  value       = module.networking.ai_engine_internet_gateway_id
}
