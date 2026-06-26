# This is the only deployable CDO08 environment.

locals {
  name_prefix = "cdo08-sandbox"

  common_tags = {
    Project     = "CDO08"
    Environment = "sandbox"
    Team        = "CDO08"
    Owner       = "thuy"
  }
}

data "aws_caller_identity" "current" {}

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

# ---------------------------------------------------------------------------
# Synthetic Generator (Owner: Thuy)
#
# Consumes networking outputs; no new VPC/subnet/SG created here.
#
# ingest_api_endpoint is a placeholder until module.telemetry_ingest
# (owned by Phuong) is merged.  Wire the real endpoint by replacing the
# default value with: module.telemetry_ingest.ingest_api_url
# ---------------------------------------------------------------------------
module "synthetic_generator" {
  source = "../../modules/synthetic_generator"

  name_prefix    = local.name_prefix
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id
  tags           = local.common_tags

  # Networking — from module.networking (no new VPC/SG)
  vpc_id                      = module.networking.workload_vpc_id
  private_subnet_ids          = module.networking.workload_private_subnet_ids
  generator_security_group_id = module.networking.generator_security_group_id

  # Container image — leave empty until image is built and pushed to ECR
  generator_image_uri = var.generator_image_uri

  # Generator behaviour
  tenant_id             = var.generator_tenant_id
  service_list          = var.generator_service_list
  scenario_list         = var.generator_scenario_list
  emit_interval_seconds = var.generator_emit_interval_seconds

  # Telemetry ingest endpoint
  # TODO: replace placeholder with module.telemetry_ingest.ingest_api_url
  # once Phuong's telemetry_ingest module is merged.
  ingest_api_endpoint = var.ingest_api_endpoint

  log_retention_days = var.generator_log_retention_days
}

# ---------------------------------------------------------------------------
# Networking outputs
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Synthetic Generator outputs (Owner: Thuy)
# ---------------------------------------------------------------------------

output "generator_cluster_arn" {
  description = "ARN of the ECS cluster for the synthetic generator."
  value       = module.synthetic_generator.cluster_arn
}

output "generator_cluster_name" {
  description = "Name of the ECS cluster for the synthetic generator."
  value       = module.synthetic_generator.cluster_name
}

output "generator_task_definition_arn" {
  description = "ARN of the generator ECS task definition."
  value       = module.synthetic_generator.task_definition_arn
}

output "generator_task_role_arn" {
  description = "ARN of the generator IAM task role."
  value       = module.synthetic_generator.task_role_arn
}

output "generator_log_group_name" {
  description = "CloudWatch log group name for generator tasks."
  value       = module.synthetic_generator.log_group_name
}

output "generator_ecr_repository_url" {
  description = "ECR repository URL for the generator image."
  value       = module.synthetic_generator.ecr_repository_url
}
