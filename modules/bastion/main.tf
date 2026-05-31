# GeoLang Infrastructure — Bastion Host Module
#
# EC2 bastion host for secure SSH access to private resources
# (RDS database, ECS tasks). Uses SSM Session Manager — no
# SSH keys or open ports required.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_id" {
  description = "Public subnet for the bastion host"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.nano"
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to SSH (empty = SSM only, no SSH)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── AMI (Amazon Linux 2023, ARM) ────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.allowed_cidrs) > 0 ? [1] : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
      description = "SSH access"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── IAM Role (SSM Session Manager) ──────────────────────────────────────────

resource "aws_iam_role" "bastion" {
  name = "${var.name_prefix}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-bastion"
  role = aws_iam_role.bastion.name
  tags = var.tags
}

# ─── EC2 Instance ─────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y postgresql16
    echo "Bastion ready. Use: aws ssm start-session --target $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
  EOF

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion" })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "instance_id" {
  description = "Bastion EC2 instance ID (use with SSM Session Manager)"
  value       = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Bastion security group ID (add to RDS ingress for DB access)"
  value       = aws_security_group.bastion.id
}

output "ssm_connect_command" {
  description = "Command to connect via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id}"
}

output "db_tunnel_command" {
  description = "Command to create an SSH tunnel to RDS (requires SSH key)"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{\"portNumber\":[\"5432\"],\"localPortNumber\":[\"5432\"]}'"
}
