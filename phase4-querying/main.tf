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
# Data source lookups — Phase 1 and Phase 3 resources
# -----------------------------------------------
# Replaces azurerm_resource_group + azurerm_storage_account data sources.
# Phase 4 does not create KMS keys or S3 buckets — it looks them up by name
# from what Phase 1 already deployed. No remote state needed.

data "aws_kms_alias" "main" {
  name = "alias/kms-sales-${var.yourname}"
}

data "aws_kms_key" "main" {
  key_id = data.aws_kms_alias.main.target_key_arn
}

data "aws_s3_bucket" "silver" {
  bucket = "silver-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
}

data "aws_s3_bucket" "gold" {
  bucket = "gold-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
}

# The Glue catalog database name is constructed from yourname — same pattern
# used in Phase 3. No data source lookup needed since we build the name directly.
locals {
  glue_database_name = "db_silver_${replace(var.yourname, "-", "_")}"
}

# -----------------------------------------------
# S3 — Athena Query Results Bucket
# -----------------------------------------------
# Synapse wrote results back to ADLS automatically.
# Athena requires an explicit S3 location to store query results.
# Every query Athena runs writes its output CSV and metadata here.
# Without this, Athena will refuse to run any query.
# We use the gold bucket as the results location — it is the analytics
# layer of the medallion architecture and the natural home for query output.

resource "aws_s3_object" "athena_results_prefix" {
  bucket  = data.aws_s3_bucket.gold.id
  key     = "athena-results/"
  content = ""
}

# -----------------------------------------------
# Athena Workgroup — Replaces Synapse Workspace
# -----------------------------------------------
# Why Athena over Redshift or EMR?
# Athena is serverless — there is no cluster to provision, patch, or scale.
# You pay only per query (per TB scanned). Redshift requires a running cluster
# that bills by the hour even when idle. For ad-hoc analytics on S3 Parquet
# data at this scale, Athena is the correct choice.
#
# A workgroup is Athena's unit of configuration and cost control.
# It sets where results land, enforces encryption, and lets you cap
# the amount of data a single query can scan — protecting against
# accidentally expensive full-table scans.

resource "aws_athena_workgroup" "main" {
  name          = "workgroup-sales-${var.yourname}"
  description   = "Athena workgroup for sales intelligence queries"
  force_destroy = true

  configuration {
    # Kills any query that would scan more than 1GB — cost guardrail
    bytes_scanned_cutoff_per_query = 1073741824

    result_configuration {
      output_location = "s3://${data.aws_s3_bucket.gold.id}/athena-results/"

      # Encrypt query results with the same KMS key used across the platform
      # Replaces Synapse's transparent data encryption
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = data.aws_kms_key.main.arn
      }
    }
  }

  tags = var.tags
}

# -----------------------------------------------
# IAM Policy — Replaces Synapse RBAC + Firewall Rules
# -----------------------------------------------
# Synapse used azurerm_synapse_firewall_rule to control network access
# and azurerm_synapse_role_assignment to grant your account admin rights.
# In AWS there is no firewall to configure — Athena is a managed API
# accessed over HTTPS. Access control is handled entirely by IAM.
#
# This policy grants the minimum permissions needed to run Athena queries:
# - Athena: start/get/stop query executions and read results
# - Glue: read the catalog database and tables Phase 3 registered
# - S3: read from silver (source data) and read/write to gold (query results)
# - KMS: decrypt silver objects and encrypt/decrypt query result objects

data "aws_iam_policy_document" "athena" {
  statement {
    sid    = "AthenaQueryAccess"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:ListQueryExecutions",
      "athena:GetWorkGroup"
    ]
    resources = [aws_athena_workgroup.main.arn]
  }

  # Glue catalog access — Athena uses the Glue Data Catalog as its metastore.
  # Without these permissions Athena cannot resolve table names to S3 paths.
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions"
    ]
    resources = [
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${local.glue_database_name}",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${local.glue_database_name}/*"
    ]
  }

  # Read source data from silver
  statement {
    sid     = "SilverRead"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      data.aws_s3_bucket.silver.arn,
      "${data.aws_s3_bucket.silver.arn}/*"
    ]
  }

  # Read and write query results to gold
  statement {
    sid     = "GoldResultsAccess"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [
      data.aws_s3_bucket.gold.arn,
      "${data.aws_s3_bucket.gold.arn}/*"
    ]
  }

  # KMS — decrypt silver data and encrypt query results
  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_key.main.arn]
  }
}

resource "aws_iam_policy" "athena" {
  name        = "policy-athena-${var.yourname}"
  description = "Least-privilege access for Athena queries against the sales data lake"
  policy      = data.aws_iam_policy_document.athena.json
  tags        = var.tags
}

# Attach the policy to the IAM user created in Phase 1
# This is the equivalent of azurerm_synapse_role_assignment granting
# your account Synapse Administrator on the workspace
data "aws_iam_user" "main" {
  user_name = "user-sales-${var.yourname}"
}

resource "aws_iam_user_policy_attachment" "athena" {
  user       = data.aws_iam_user.main.user_name
  policy_arn = aws_iam_policy.athena.arn
}
