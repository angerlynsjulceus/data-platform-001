terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# Reference Phase 1 KMS key by alias lookup
# This avoids needing remote state — we just look up what already exists
data "aws_kms_alias" "main" {
  name = "alias/kms-sales-${var.yourname}"
}

# Lookup the actual key ARN from the alias — required for IAM policies
data "aws_kms_key" "main" {
  key_id = data.aws_kms_alias.main.target_key_arn
}

# -----------------------------------------------
# Kinesis Data Stream - Replaces Event Hub
# -----------------------------------------------
# The stream is the equivalent of an Event Hub namespace + topic combined.
# shard_count = 1 gives 1MB/sec in, 2MB/sec out — same as 1 Throughput Unit.
resource "aws_kinesis_stream" "sales" {
  name        = "sales-events-${var.yourname}"
  shard_count = 1

  # Retain records for 24 hours (equivalent to message_retention = 1 day)
  retention_period = 24

  encryption_type = "KMS"
  kms_key_id      = data.aws_kms_alias.main.arn

  tags = var.tags
}

# -----------------------------------------------
# SSM Parameter - Replaces Key Vault Secret
# -----------------------------------------------
# The EC2 instance retrieves the stream name at runtime via IAM role
# rather than having it hardcoded in the script.
resource "aws_ssm_parameter" "kinesis_stream_name" {
  name   = "/sales/${var.yourname}/kinesis-stream-name"
  type   = "SecureString"
  value  = aws_kinesis_stream.sales.name
  key_id = data.aws_kms_alias.main.arn
  tags   = var.tags
}

# -----------------------------------------------
# VPC and Subnet for the EC2 instance
# -----------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "vpc-sales-${var.yourname}" })
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "subnet-simulator-${var.yourname}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "igw-sales-${var.yourname}" })
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "rt-sales-${var.yourname}" })
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# -----------------------------------------------
# Security Group - Replaces NSG
# -----------------------------------------------
resource "aws_security_group" "simulator" {
  name        = "simulator-sg-${var.yourname}"
  description = "Allow SSH access to simulator EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# -----------------------------------------------
# IAM Role for EC2 - Replaces Managed Identity
# -----------------------------------------------
# Gives the EC2 instance an IAM identity to authenticate
# to Kinesis and SSM without storing credentials.
resource "aws_iam_role" "simulator" {
  name = "role-simulator-${var.yourname}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

data "aws_iam_policy_document" "simulator" {
  # Replaces Key Vault Secrets User — read SSM parameters
  statement {
    sid     = "SSMAccess"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/sales/${var.yourname}/*"
    ]
  }

  # Replaces Event Hubs Data Sender — send records to Kinesis
  statement {
    sid     = "KinesisSendAccess"
    effect  = "Allow"
    actions = ["kinesis:PutRecord", "kinesis:PutRecords"]
    resources = [aws_kinesis_stream.sales.arn]
  }

  # Allow EC2 to use the KMS key for Kinesis and SSM decryption
  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "simulator" {
  name   = "policy-simulator-${var.yourname}"
  role   = aws_iam_role.simulator.id
  policy = data.aws_iam_policy_document.simulator.json
}

resource "aws_iam_instance_profile" "simulator" {
  name = "profile-simulator-${var.yourname}"
  role = aws_iam_role.simulator.name
}

# -----------------------------------------------
# EC2 Key Pair - Creates key pair and saves private key locally
# -----------------------------------------------
resource "tls_private_key" "capstone" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "capstone" {
  key_name   = "capstone"
  public_key = tls_private_key.capstone.public_key_openssh
  tags       = var.tags
}

resource "local_file" "capstone_pem" {
  content         = tls_private_key.capstone.private_key_pem
  filename        = "C:\\terraform\\key-pair\\capstone.pem"
  file_permission = "0400"
}

# Fix Windows SSH key permissions automatically — file_permission = "0400" is ignored on Windows.
# icacls removes all inherited permissions, grants read-only to the current user,
# which satisfies SSH's "UNPROTECTED PRIVATE KEY FILE" requirement.
resource "null_resource" "fix_pem_permissions" {
  triggers = {
    pem_path = local_file.capstone_pem.filename
  }

  provisioner "local-exec" {
    command     = "$path = 'C:\\terraform\\key-pair\\capstone.pem'; icacls $path /inheritance:r /grant ($env:USERNAME + ':R')"
    interpreter = ["PowerShell", "-Command"]
  }

  depends_on = [local_file.capstone_pem]
}

# -----------------------------------------------
# EC2 Instance - Replaces Linux VM simulator
# -----------------------------------------------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "simulator" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro" # Smallest size — simulator is lightweight
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.simulator.id]
  iam_instance_profile   = aws_iam_instance_profile.simulator.name
  key_name               = aws_key_pair.capstone.key_name
  monitoring             = true

  root_block_device {
    encrypted  = true
    kms_key_id = data.aws_kms_alias.main.arn
  }

  # Installs Python/boto3 and writes simulate_sales.py on boot
  # templatefile keeps Python code out of main.tf to avoid Terraform interpolation conflicts
  user_data = templatefile("${path.module}/user_data.sh", {
    yourname = var.yourname
    region   = var.region
  })

  tags = merge(var.tags, { Name = "ec2-simulator-${var.yourname}" })
}
