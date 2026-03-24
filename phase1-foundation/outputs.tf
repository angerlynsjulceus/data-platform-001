output "iam_user_name" {
  value = aws_iam_user.main.name
}

output "iam_user_arn" {
  value = aws_iam_user.main.arn
}

output "s3_bucket_arns" {
  value = { for k, v in aws_s3_bucket.datalake : k => v.arn }
}

output "kms_key_id" {
  value = aws_kms_key.main.key_id
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "kms_alias" {
  value = aws_kms_alias.main.name
}

output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "rds_db_name" {
  value = aws_db_instance.main.db_name
}
