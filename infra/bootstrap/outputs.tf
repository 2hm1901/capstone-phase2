output "state_bucket_name" {
  description = "Use this value in the sandbox backend.hcl file."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_region" {
  description = "Use this value in the sandbox backend.hcl file."
  value       = var.aws_region
}
