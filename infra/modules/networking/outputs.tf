output "workload_vpc_id" {
  description = "ID of the synthetic workload/services VPC."
  value       = aws_vpc.workload.id
}

output "workload_private_subnet_ids" {
  description = "Private subnet IDs for synthetic workload services."
  value       = aws_subnet.workload_private[*].id
}

output "ai_engine_vpc_id" {
  description = "ID of the AI Engine runtime VPC."
  value       = aws_vpc.ai_engine.id
}

output "ai_engine_private_subnet_ids" {
  description = "Private subnet IDs for AI Engine runtime."
  value       = aws_subnet.ai_engine_private[*].id
}

output "ai_engine_public_subnet_ids" {
  description = "Reserved public subnet IDs in the AI Engine VPC. Current AI Engine ALB is internal and does not use these."
  value       = aws_subnet.ai_engine_public[*].id
}

output "generator_security_group_id" {
  description = "Security group ID for synthetic generator tasks."
  value       = aws_security_group.generator.id
}

output "ai_engine_alb_security_group_id" {
  description = "Security group ID for the AI Engine application load balancer."
  value       = aws_security_group.ai_engine_alb.id
}

output "ai_engine_task_security_group_id" {
  description = "Security group ID for AI Engine ECS tasks."
  value       = aws_security_group.ai_engine_task.id
}

output "serving_adapter_security_group_id" {
  description = "Security group ID for Serving Adapter Lambda in the AI Engine VPC."
  value       = aws_security_group.serving_adapter.id
}

output "ai_engine_s3_endpoint_id" {
  description = "Gateway VPC endpoint ID for AI Engine access to S3 baseline storage."
  value       = aws_vpc_endpoint.ai_engine_s3.id
}

output "ai_engine_internet_gateway_id" {
  description = "Internet Gateway ID reserved for future public ingress; current AI Engine ALB is internal."
  value       = aws_internet_gateway.ai_engine.id
}
