terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  backend "s3" {
    bucket       = "cdo08-tf-state-894597652722-us-west-2"
    key          = "cdo08/sandbox/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
