# GeoLang Infrastructure — ElastiCache Module (Redis)
#
# Redis cluster for caching geocoding results, routing queries,
# tile metadata, and session state.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_security_group_id" {
  description = "Security group of ECS tasks that need cache access"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_nodes" {
  description = "Number of cache nodes"
  type        = number
  default     = 1
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Subnet Group ────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-cache"
  subnet_ids = var.private_subnet_ids

  tags = var.tags
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "redis" {
  name_prefix = "${var.name_prefix}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
    description     = "Redis from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Parameter Group ─────────────────────────────────────────────────────────

resource "aws_elasticache_parameter_group" "main" {
  name   = "${var.name_prefix}-redis"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = var.tags
}

# ─── Redis Cluster ───────────────────────────────────────────────────────────

resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${var.name_prefix}-redis"
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_nodes      = var.num_cache_nodes
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  snapshot_retention_limit = 1
  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_window          = "03:00-04:00"

  transit_encryption_enabled = false # Enable if using Redis AUTH

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "endpoint" {
  description = "Redis endpoint"
  value       = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "port" {
  description = "Redis port"
  value       = aws_elasticache_cluster.main.cache_nodes[0].port
}

output "connection_url" {
  description = "Redis connection URL"
  value       = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:${aws_elasticache_cluster.main.cache_nodes[0].port}"
}

output "security_group_id" {
  description = "Redis security group ID"
  value       = aws_security_group.redis.id
}
