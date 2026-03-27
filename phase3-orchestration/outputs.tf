output "glue_job_name" {
  value = aws_glue_job.bronze_to_silver.name
}

output "glue_job_arn" {
  value = aws_glue_job.bronze_to_silver.arn
}

output "glue_role_arn" {
  value = aws_iam_role.glue.arn
}

output "glue_crawler_name" {
  value = aws_glue_crawler.silver.name
}

output "glue_catalog_database" {
  value = aws_glue_catalog_database.silver.name
}
