output "athena_workgroup_name" {
  value = aws_athena_workgroup.main.name
}

output "athena_workgroup_arn" {
  value = aws_athena_workgroup.main.arn
}

output "athena_results_location" {
  value = "s3://${data.aws_s3_bucket.gold.id}/athena-results/"
}

output "athena_database_name" {
  value = local.glue_database_name
}
