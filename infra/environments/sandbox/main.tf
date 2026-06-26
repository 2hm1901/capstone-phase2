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

module "observability_audit" {
  source = "../../modules/observability_audit"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  tags        = local.common_tags

  audit_table_name     = var.audit_table_name
  audit_retention_days = var.audit_retention_days
  audit_ttl_enabled    = var.audit_ttl_enabled
  audit_kms_key_arn    = module.security_baseline.kms_key_arn

  audit_reader_principal_arns = var.audit_reader_principal_arns

  create_grafana_workspace = var.create_grafana_workspace
  grafana_workspace_id     = var.grafana_workspace_id
  grafana_workspace_name   = var.grafana_workspace_name
  grafana_datasource_uid   = var.grafana_datasource_uid
  amp_workspace_id         = var.amp_workspace_id
  grafana_secret_arn       = module.security_baseline.grafana_secret_arn

  alarm_audit_write_error_threshold  = var.alarm_audit_write_error_threshold
  alarm_annotation_error_period_secs = var.alarm_annotation_error_period_secs
  alarm_annotation_error_threshold   = var.alarm_annotation_error_threshold
  alarm_fallback_count_threshold     = var.alarm_fallback_count_threshold
  alarm_fallback_count_period_secs   = var.alarm_fallback_count_period_secs
}

output "audit_table_name" {
  description = "Name of the DynamoDB audit table."
  value       = module.observability_audit.audit_table_name
}

output "audit_table_arn" {
  description = "ARN of the DynamoDB audit table."
  value       = module.observability_audit.audit_table_arn
}

output "audit_writer_role_arn" {
  description = "IAM role ARN for audit writers (Prediction/Fallback Lambda). PutItem only."
  value       = module.observability_audit.audit_writer_role_arn
}

output "audit_reader_role_arn" {
  description = "IAM role ARN for audit readers (Mentor/debug). Query + GetItem only."
  value       = module.observability_audit.audit_reader_role_arn
}

output "grafana_workspace_id" {
  description = "Amazon Managed Grafana workspace ID (created or referenced). Null when Grafana is deferred."
  value       = module.observability_audit.grafana_workspace_id
}

output "annotation_audit_log_group_name" {
  description = "CloudWatch Logs log group for annotation/audit structured logs."
  value       = module.observability_audit.annotation_audit_log_group_name
}

output "observability_alarm_names" {
  description = "Map of CloudWatch alarm names owned by the observability_audit module."
  value       = module.observability_audit.alarm_names
}

output "observability_dashboard_name" {
  description = "CloudWatch dashboard name summarizing audit/annotation/fallback health."
  value       = module.observability_audit.dashboard_name
}

# ==============================================================================
# Security Baseline Module Call
# ==============================================================================

module "security_baseline" {
  source                  = "../../modules/security_baseline"
  aws_region              = var.aws_region
  name_prefix             = local.name_prefix
  tags                    = local.common_tags
  reviewer_principal_arns = var.reviewer_principal_arns
}

# ==============================================================================
# Security Baseline Outputs
# ==============================================================================

output "kms_key_arn" {
  description = "ARN of the customer managed KMS key"
  value       = module.security_baseline.kms_key_arn
}

output "kms_key_id" {
  description = "ID of the customer managed KMS key"
  value       = module.security_baseline.kms_key_id
}

output "baseline_bucket_name" {
  description = "Name of the baseline S3 bucket"
  value       = module.security_baseline.baseline_bucket_name
}

output "baseline_bucket_arn" {
  description = "ARN of the baseline S3 bucket"
  value       = module.security_baseline.baseline_bucket_arn
}

output "grafana_secret_arn" {
  description = "ARN of the Grafana token secret"
  value       = module.security_baseline.grafana_secret_arn
}

output "generator_role_arn" {
  description = "ARN of the Generator role"
  value       = module.security_baseline.generator_role_arn
}

output "ingest_role_arn" {
  description = "ARN of the Ingest role"
  value       = module.security_baseline.ingest_role_arn
}

output "writer_role_arn" {
  description = "ARN of the Writer role"
  value       = module.security_baseline.writer_role_arn
}

output "prediction_role_arn" {
  description = "ARN of the Prediction role"
  value       = module.security_baseline.prediction_role_arn
}

output "ai_engine_role_arn" {
  description = "ARN of the AI Engine task role"
  value       = module.security_baseline.ai_engine_role_arn
}

output "fallback_role_arn" {
  description = "ARN of the Fallback role"
  value       = module.security_baseline.fallback_role_arn
}

output "scheduler_role_arn" {
  description = "ARN of the Scheduler role"
  value       = module.security_baseline.scheduler_role_arn
}

output "reviewer_role_arn" {
  description = "ARN of the Reviewer role"
  value       = module.security_baseline.reviewer_role_arn
}

output "ai_engine_app_log_group_name" {
  description = "Name of the AI Engine app log group"
  value       = module.security_baseline.ai_engine_app_log_group_name
}

output "ai_engine_audit_log_group_name" {
  description = "Name of the AI Engine audit log group"
  value       = module.security_baseline.ai_engine_audit_log_group_name
}

output "ai_engine_ecr_repo_url" {
  description = "ECR Repository URL for AI Engine"
  value       = module.security_baseline.ai_engine_ecr_repo_url
}
