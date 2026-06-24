provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "CDO08"
      Environment = "sandbox"
      ManagedBy   = "Terraform"
    }
  }
}
