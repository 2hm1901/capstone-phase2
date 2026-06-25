data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_names = slice(data.aws_availability_zones.available.names, 0, var.private_subnet_count)
}

resource "aws_vpc" "workload" {
  cidr_block           = var.workload_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-workload-vpc"
    Role = "synthetic-workload"
  })
}

resource "aws_vpc" "ai_engine" {
  cidr_block           = var.ai_engine_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-vpc"
    Role = "ai-engine-runtime"
  })
}

resource "aws_subnet" "workload_private" {
  count = var.private_subnet_count

  vpc_id                  = aws_vpc.workload.id
  cidr_block              = cidrsubnet(var.workload_vpc_cidr, 8, count.index)
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-workload-private-${count.index + 1}"
    Tier = "private"
    Role = "synthetic-workload"
  })
}

resource "aws_subnet" "ai_engine_private" {
  count = var.private_subnet_count

  vpc_id                  = aws_vpc.ai_engine.id
  cidr_block              = cidrsubnet(var.ai_engine_vpc_cidr, 8, count.index)
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-private-${count.index + 1}"
    Tier = "private"
    Role = "ai-engine-runtime"
  })
}

resource "aws_route_table" "workload_private" {
  vpc_id = aws_vpc.workload.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-workload-private-rt"
  })
}

resource "aws_route_table" "ai_engine_private" {
  vpc_id = aws_vpc.ai_engine.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-private-rt"
  })
}

resource "aws_route_table_association" "workload_private" {
  count = var.private_subnet_count

  subnet_id      = aws_subnet.workload_private[count.index].id
  route_table_id = aws_route_table.workload_private.id
}

resource "aws_route_table_association" "ai_engine_private" {
  count = var.private_subnet_count

  subnet_id      = aws_subnet.ai_engine_private[count.index].id
  route_table_id = aws_route_table.ai_engine_private.id
}

resource "aws_vpc_peering_connection" "workload_to_ai_engine" {
  vpc_id      = aws_vpc.workload.id
  peer_vpc_id = aws_vpc.ai_engine.id
  auto_accept = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-workload-ai-engine-peering"
  })
}

resource "aws_route" "workload_to_ai_engine" {
  route_table_id            = aws_route_table.workload_private.id
  destination_cidr_block    = aws_vpc.ai_engine.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_to_ai_engine.id
}

resource "aws_route" "ai_engine_to_workload" {
  route_table_id            = aws_route_table.ai_engine_private.id
  destination_cidr_block    = aws_vpc.workload.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_to_ai_engine.id
}

resource "aws_vpc_endpoint" "ai_engine_s3" {
  vpc_id            = aws_vpc.ai_engine.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.ai_engine_private.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-s3-endpoint"
    Role = "baseline-storage-access"
  })
}

resource "aws_security_group" "generator" {
  name        = "${var.name_prefix}-generator-sg"
  description = "Security group for synthetic workload generator tasks."
  vpc_id      = aws_vpc.workload.id

  egress {
    description = "Allow HTTPS egress to AWS services and telemetry entrypoints."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-generator-sg"
  })
}

resource "aws_security_group" "ai_engine_alb" {
  name        = "${var.name_prefix}-ai-engine-alb-sg"
  description = "Security group for the internal AI Engine load balancer."
  vpc_id      = aws_vpc.ai_engine.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-alb-sg"
  })
}

resource "aws_security_group" "ai_engine_task" {
  name        = "${var.name_prefix}-ai-engine-task-sg"
  description = "Security group for AI Engine ECS Fargate tasks."
  vpc_id      = aws_vpc.ai_engine.id

  egress {
    description = "Allow HTTPS egress to AWS services through VPC endpoints or controlled egress."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ai-engine-task-sg"
  })
}

resource "aws_security_group_rule" "ai_engine_alb_ingress_from_workload" {
  type              = "ingress"
  description       = "Allow HTTPS from the workload VPC over private routing."
  security_group_id = aws_security_group.ai_engine_alb.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.workload.cidr_block]
}

resource "aws_security_group_rule" "ai_engine_alb_egress_to_task" {
  type                     = "egress"
  description              = "Forward requests to AI Engine tasks."
  security_group_id        = aws_security_group.ai_engine_alb.id
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ai_engine_task.id
}

resource "aws_security_group_rule" "ai_engine_task_ingress_from_alb" {
  type                     = "ingress"
  description              = "Allow FastAPI traffic from the internal ALB."
  security_group_id        = aws_security_group.ai_engine_task.id
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ai_engine_alb.id
}
