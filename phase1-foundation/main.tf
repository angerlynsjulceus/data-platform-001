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

# Pull current AWS caller identity
data "aws_caller_identity" "current" {}

# -----------------------------------------------
# KMS - Encryption key for all services
# -----------------------------------------------
resource "aws_kms_key" "main" {
  description             = "kms-sales-${var.yourname}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/kms-sales-${var.yourname}"
  target_key_id = aws_kms_key.main.key_id
}

# -----------------------------------------------
# S3 Data Lake
# -----------------------------------------------
# Each bucket maps to a medallion layer: bronze (raw), silver (cleaned), gold (aggregated).

locals {
  buckets = ["bronze", "silver", "gold"]
}

# Bronze bucket — raw data lands here exactly as received
# Silver bucket — cleaned and structured data
# Gold bucket   — aggregated, analytics-ready data
resource "aws_s3_bucket" "datalake" {
  for_each      = toset(local.buckets)
  bucket        = "${each.key}-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "datalake" {
  for_each = toset(local.buckets)
  bucket   = aws_s3_bucket.datalake[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datalake" {
  for_each = toset(local.buckets)
  bucket   = aws_s3_bucket.datalake[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datalake" {
  for_each                = toset(local.buckets)
  bucket                  = aws_s3_bucket.datalake[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------
# IAM - User, policy, and attachment
# -----------------------------------------------
# Creates a dedicated IAM user for the data platform with full access to KMS and S3.

resource "aws_iam_user" "main" {
  name = "user-sales-${var.yourname}"
  tags = var.tags
}

data "aws_iam_policy_document" "admin_self" {
  statement {
    sid     = "KMSAdminAccess"
    effect  = "Allow"
    actions = ["kms:*"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid     = "S3DataLakeAccess"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = flatten([
      for bucket in local.buckets : [
        "arn:aws:s3:::${bucket}-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}",
        "arn:aws:s3:::${bucket}-sales-${var.yourname}-${data.aws_caller_identity.current.account_id}/*"
      ]
    ])
  }
}

resource "aws_iam_policy" "admin_self" {
  name        = "policy-sales-admin-${var.yourname}"
  description = "Grants data platform IAM user admin access to KMS and S3 data lake"
  policy      = data.aws_iam_policy_document.admin_self.json
  tags        = var.tags
}

resource "aws_iam_user_policy_attachment" "admin_self" {
  user       = aws_iam_user.main.name
  policy_arn = aws_iam_policy.admin_self.arn
}

# -----------------------------------------------
# RDS - MySQL database
# -----------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "vpc-sales-${var.yourname}" })
}

resource "aws_subnet" "rds_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.region}a"
  tags              = merge(var.tags, { Name = "subnet-rds-a-${var.yourname}" })
}

resource "aws_subnet" "rds_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.region}b"
  tags              = merge(var.tags, { Name = "subnet-rds-b-${var.yourname}" })
}

resource "aws_db_subnet_group" "main" {
  name       = "rds-subnet-group-${var.yourname}"
  subnet_ids = [aws_subnet.rds_a.id, aws_subnet.rds_b.id]
  tags       = var.tags
}

resource "aws_security_group" "rds" {
  name        = "rds-sg-${var.yourname}"
  description = "Allow MySQL access"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_instance" "main" {
  identifier        = "rds-sales-${var.yourname}"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "salesdb"
  username = "admin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  kms_key_id          = aws_kms_key.main.arn
  storage_encrypted   = true
  skip_final_snapshot = true
  tags                = var.tags
}
