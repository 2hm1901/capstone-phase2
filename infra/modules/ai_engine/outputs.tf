output "ai_engine_alb_dns_name" {
  description = "Tên DNS của AI Engine ALB"
  value       = aws_lb.ai_engine.dns_name
}

output "ai_engine_endpoint" {
  description = "HTTP endpoint của AI Engine"
  value       = "http://${aws_lb.ai_engine.dns_name}"
}

output "ai_engine_ecs_cluster_arn" {
  description = "ARN của AI Engine ECS Cluster"
  value       = aws_ecs_cluster.ai_engine.arn
}