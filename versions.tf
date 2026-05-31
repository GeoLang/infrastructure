# GeoLang Infrastructure — Provider Requirements
#
# Terraform >= 1.5 required for check blocks and import blocks.
# AWS provider ~> 5.0 for latest ECS/RDS features.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment for remote state (recommended for team use):
  # backend "s3" {
  #   bucket         = "geolang-terraform-state"
  #   key            = "infrastructure/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "geolang-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "geolang"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront requires ACM certs in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "geolang"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
