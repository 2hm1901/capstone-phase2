output "ai_engine_alb_dns_name" {
  description = "Tên DNS nội bộ của AI Engine ALB"
  value       = aws_lb.ai_engine.dns_name
}

output "ai_engine_endpoint" {
  description = "HTTP endpoint nội bộ của AI Engine"
  value       = "http://${aws_lb.ai_engine.dns_name}"
}

output "ai_engine_ecs_cluster_arn" {
  description = "ARN của AI Engine ECS Cluster"
  value       = aws_ecs_cluster.ai_engine.arn
}

output "ai_engine_execution_role_arn" {
  description = "Execution role ARN used by AI Engine ECS tasks to pull images and write logs."
  value       = aws_iam_role.ai_engine_execution.arn
}
