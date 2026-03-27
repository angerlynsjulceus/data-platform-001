terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------
# Data source lookups — Phase 1 resources
# -----------------------------------------------
# Replaces azurerm_resource_group + azurerm_storage_account data sources.
# Each phase looks up Phase 1 resources by name — no remote state needed.

data "aws_kms_alias" "main" {
  name = "alias/kms-sales-${var.yourname}"
}

data "aws_kms_key" "main" {
  key_id = data.aws_kms_alias.main.target_key_arn
}

data "aws_s3_bucket" "bronze" {
  bucket = "bronze-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
}

data "aws_s3_bucket" "silver" {
  bucket = "silver-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------
# IAM Role for Glue — Replaces ADF Managed Identity + RBAC
# -----------------------------------------------
# ADF used a SystemAssigned Managed Identity and an azurerm_role_assignment
# to grant Storage Blob Data Contributor on the storage account.
# In AWS, Glue authenticates via an IAM role attached at job creation time.
# The trust policy allows the Glue service to assume this role.

resource "aws_iam_role" "glue" {
  name = "role-glue-${var.yourname}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# AWS managed policy — grants Glue access to CloudWatch Logs, S3 (Glue assets),
# and Glue catalog APIs. Equivalent to the baseline permissions ADF gets by default.
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue" {
  # Read from bronze — equivalent to Storage Blob Data Contributor on source
  statement {
    sid     = "BronzeRead"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      data.aws_s3_bucket.bronze.arn,
      "${data.aws_s3_bucket.bronze.arn}/*"
    ]
  }

  # Write to silver — equivalent to Storage Blob Data Contributor on sink
  statement {
    sid     = "SilverWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      data.aws_s3_bucket.silver.arn,
      "${data.aws_s3_bucket.silver.arn}/*"
    ]
  }

  # Glue script lives in the bronze bucket under a scripts/ prefix
  statement {
    sid     = "ScriptRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.bronze.arn}/scripts/*"]
  }

  # KMS — Glue must decrypt bronze objects and encrypt silver objects
  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "glue" {
  name   = "policy-glue-${var.yourname}"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

# -----------------------------------------------
# Glue Script — Uploaded to S3
# -----------------------------------------------
# ADF embedded the copy activity and column mappings in the pipeline JSON.
# Glue requires an external PySpark script. The script is stored in S3 and
# referenced by the Glue job — this is the standard Glue deployment pattern.
#
# Column mappings from the ADF pipeline are preserved exactly:
# transaction_id (String), timestamp (DateTime→TimestampType), product (String),
# quantity (Int32→IntegerType), unit_price (Double→DoubleType),
# region (String), store_id (String)

resource "aws_s3_object" "glue_script" {
  bucket       = data.aws_s3_bucket.bronze.id
  key          = "scripts/bronze_to_silver.py"
  source       = "${path.module}/bronze_to_silver.py"
  content_type = "text/x-python"
  kms_key_id   = data.aws_kms_alias.main.arn
  tags         = var.tags
}

# -----------------------------------------------
# Glue Job — Replaces ADF Pipeline (pl_bronze_to_silver)
# -----------------------------------------------
# ADF's Copy activity handled source, sink, and column mapping in one JSON block.
# The Glue job is the equivalent orchestration unit — it runs the PySpark script
# above on a managed Spark cluster. glue_version 4.0 = Spark 3.3 + Python 3.10.
# worker_type DPU-2 (G.1X) is the smallest available — sufficient for this workload.

resource "aws_glue_job" "bronze_to_silver" {
  name     = "glue-bronze-to-silver-${var.yourname}"
  role_arn = aws_iam_role.glue.arn

  command {
    name            = "glueetl"
    script_location = "s3://${data.aws_s3_bucket.bronze.id}/scripts/bronze_to_silver.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"        = "python"
    "--bronze_path"         = "s3://${data.aws_s3_bucket.bronze.id}/sales/"
    "--silver_path"         = "s3://${data.aws_s3_bucket.silver.id}/sales/"
    "--enable-metrics"      = "true"
    "--enable-job-insights" = "true"
  }

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 10 # minutes — short timeout for a small dataset

  tags = var.tags
}

# -----------------------------------------------
# Glue Crawler — Catalogs the silver output
# -----------------------------------------------
# ADF wrote Parquet to ADLS and the schema was inferred at query time.
# In AWS, Athena (Phase 4) needs a Glue Data Catalog table to query the data.
# The crawler scans the silver bucket and registers the schema automatically.

resource "aws_glue_catalog_database" "silver" {
  name = "db_silver_${replace(var.yourname, "-", "_")}"
}

resource "aws_glue_crawler" "silver" {
  name          = "crawler-silver-${var.yourname}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.silver.name

  s3_target {
    path = "s3://${data.aws_s3_bucket.silver.id}/sales/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  tags = var.tags
}
