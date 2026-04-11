terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------
# Data source lookups — Phase 1 and Phase 4 resources
# -----------------------------------------------
# Replaces azurerm_resource_group, azurerm_storage_account,
# and azurerm_key_vault data sources.
# Phase 5 looks up existing resources by name — no remote state needed.

data "aws_kms_alias" "main" {
  name = "alias/kms-sales-${var.yourname}"
}

data "aws_kms_key" "main" {
  key_id = data.aws_kms_alias.main.target_key_arn
}

data "aws_s3_bucket" "gold" {
  bucket = "gold-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------
# SSM Parameter — Replaces Key Vault Secrets
# -----------------------------------------------
# Azure stored the OpenAI API key and endpoint in Key Vault because
# Azure OpenAI requires an API key for authentication.
# Bedrock uses IAM — there is no API key. Instead we store the model ID
# in SSM so Lambda can retrieve it at runtime without hardcoding it.
# This keeps the model ID configurable without redeploying Lambda.

resource "aws_ssm_parameter" "bedrock_model_id" {
  name   = "/sales/${var.yourname}/bedrock-model-id"
  type   = "SecureString"
  value  = "anthropic.claude-3-haiku-20240307-v1:0"
  key_id = data.aws_kms_alias.main.arn
  tags   = var.tags
}

# -----------------------------------------------
# Lambda Function — Replaces Azure Function + AI Hub + AI Project
# -----------------------------------------------
# The Azure version used an AI Hub and AI Project as a workspace
# to manage the OpenAI connection. In AWS this is unnecessary —
# Lambda calls Bedrock directly via IAM. No workspace, no hub,
# no project, no connection string needed.
#
# Why Lambda over ECS or EC2?
# Lambda is serverless — it runs only when triggered and costs nothing
# when idle. The summariser runs on demand after each Glue job completes.
# There is no reason to keep a server running between invocations.
#
# The Lambda function:
# 1. Reads the latest Athena query results from the gold S3 bucket
# 2. Calls Bedrock to generate an executive summary of the sales data
# 3. Writes the summary back to the gold bucket under summaries/

resource "aws_iam_role" "lambda" {
  name = "role-lambda-${var.yourname}"

  # Trust policy — allows the Lambda service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# AWS managed policy — grants Lambda permission to write logs to CloudWatch.
# Equivalent to the baseline logging permissions Azure Functions get by default.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda" {
  # Replaces azurerm_role_assignment (Cognitive Services OpenAI User)
  # Grants Lambda permission to invoke Bedrock models
  statement {
    sid       = "BedrockInvoke"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"]
  }

  # Read Athena query results from gold bucket
  statement {
    sid     = "GoldRead"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      data.aws_s3_bucket.gold.arn,
      "${data.aws_s3_bucket.gold.arn}/*"
    ]
  }

  # Write AI summaries back to gold bucket under summaries/
  statement {
    sid     = "SummaryWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = ["${data.aws_s3_bucket.gold.arn}/summaries/*"]
  }

  # Read the Bedrock model ID from SSM at runtime
  # Replaces Key Vault secret reads in the Azure Function
  statement {
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/sales/${var.yourname}/*"
    ]
  }

  # KMS — decrypt SSM parameter and gold bucket objects
  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "policy-lambda-${var.yourname}"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# -----------------------------------------------
# Lambda deployment package
# -----------------------------------------------
# The function code is kept in a separate summarise_sales.py file
# and zipped by Terraform at deploy time using the archive provider.
# This is the same pattern used for the Glue script in Phase 3 —
# keeping code out of main.tf makes it testable and independently vintable.

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/summarise_sales.py"
  output_path = "${path.module}/summarise_sales.zip"
}

resource "aws_lambda_function" "summariser" {
  function_name    = "lambda-summariser-${var.yourname}"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "summarise_sales.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # 5 minute timeout — Bedrock inference can take several seconds
  # for longer prompts. 30 seconds is too short for large result sets.
  timeout     = 300
  memory_size = 256

  environment {
    variables = {
      BEDROCK_MODEL_SSM_PATH = "/sales/${var.yourname}/bedrock-model-id"
      GOLD_BUCKET            = data.aws_s3_bucket.gold.id
      REGION                 = var.region
    }
  }

  tags = var.tags
}
