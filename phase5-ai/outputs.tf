output "lambda_function_name" {
  value = aws_lambda_function.summariser.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.summariser.arn
}

output "bedrock_model_id" {
  value     = aws_ssm_parameter.bedrock_model_id.value
  sensitive = true
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "summary_output_location" {
  value = "s3://${data.aws_s3_bucket.gold.id}/summaries/"
}
