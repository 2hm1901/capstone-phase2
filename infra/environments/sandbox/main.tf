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

module "prediction" {
  source = "../../modules/prediction"

  name_prefix       = local.name_prefix
  aws_region        = var.aws_region
  enable_prediction = var.enable_prediction

  service_list                = var.prediction_service_list
  prediction_interval_minutes = 5
  lookback_minutes            = 120

  # From Nam có thể thay đổi tử Nam
  #amp_workspace_id   = module.telemetry_store.amp_workspace_id
  #amp_workspace_arn  = module.telemetry_store.amp_workspace_arn
  #amp_query_endpoint = module.telemetry_store.amp_query_endpoint

  #chạy để test
  amp_workspace_id   = "ws-placeholder-id"
  amp_workspace_arn  = "arn:aws:aps:us-west-2:123456789012:workspace/ws-placeholder"
  amp_query_endpoint = "https://aps-workspaces.us-west-2.amazonaws.com/workspaces/ws-placeholder"

  # From AI Engine module / runtime config
  ai_engine_endpoint   = null
  ai_engine_invoke_arn = null

  # From Quân audit/Grafana module
  audit_table_arn              = null
  audit_table_name             = null
  grafana_api_token_secret_arn = null

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
