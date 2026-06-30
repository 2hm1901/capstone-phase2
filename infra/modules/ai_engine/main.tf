# Tạo ECS Cluster cho AI Engine
resource "aws_ecs_cluster" "ai_engine" {
  name = "${var.name_prefix}-ai-engine"
  tags = var.tags
}

# Tạo Application Load Balancer (ALB)
resource "aws_lb" "ai_engine" {
  name               = "${var.name_prefix}-ai-engine-alb"
  internal           = false  # TẠM THỜI: internal = false để dễ demo/test. Sau này có thể harden về internal/private path
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids
  tags               = var.tags
}

resource "aws_lb_target_group" "ai_engine" {
  name     = "${var.name_prefix}-ai-engine-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "ip"  # Vì dùng Fargate, target là IP

  # Health check theo deployment contract
  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

# Tạo Listener để ALB lắng nghe trên cổng 80
resource "aws_lb_listener" "ai_engine" {
  load_balancer_arn = aws_lb.ai_engine.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_engine.arn
  }
}

# Tạo Task Definition cho Fargate
resource "aws_ecs_task_definition" "ai_engine" {
  family                   = "${var.name_prefix}-ai-engine"
  network_mode             = "awsvpc"  # Bắt buộc với Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"  # 0.5 vCPU
  memory                   = "1024" # 1GB RAM
  execution_role_arn       = var.ai_engine_role_arn
  task_role_arn            = var.ai_engine_role_arn

  container_definitions = jsonencode([
    {
      name      = "ai-engine"
      image     = "${var.ai_engine_ecr_repo_url}:${var.ai_engine_image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      environment = [
        {
          name  = "AWS_REGION",
          value = var.aws_region
        },
        {
          name  = "BASELINE_BACKEND",
          value = "s3"
        },
        {
          name  = "BASELINE_S3_BUCKET",
          value = var.baseline_bucket_name
        },
        {
          name  = "BASELINE_S3_PREFIX",
          value = "baselines/"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.app_log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = var.tags
}

# Tạo ECS Service 
resource "aws_ecs_service" "ai_engine" {
  name            = "${var.name_prefix}-ai-engine-service"
  cluster         = aws_ecs_cluster.ai_engine.id
  task_definition = aws_ecs_task_definition.ai_engine.arn
  desired_count   = 2  # Min 2 theo deployment contract
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.task_security_group_id]
    assign_public_ip = false  # Task không cần public IP, nằm trong private subnet
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ai_engine.arn
    container_name   = "ai-engine"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.ai_engine]

  tags = var.tags
}
# Cấu hình Auto Scaling cho ECS Service (min 2, max 4)
resource "aws_appautoscaling_target" "ai_engine" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.ai_engine.name}/${aws_ecs_service.ai_engine.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 4
}

# Policy auto scale theo CPU utilization (mục tiêu 70%) Auto Scaling Policy
resource "aws_appautoscaling_policy" "ai_engine_cpu" {
  name               = "${var.name_prefix}-ai-engine-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ai_engine.resource_id
  scalable_dimension = aws_appautoscaling_target.ai_engine.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ai_engine.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300  # 5 phút
    scale_out_cooldown = 60   # 1 phút
  }
}