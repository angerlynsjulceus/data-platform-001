# 🚀 Real-Time Sales Intelligence Platform — Terraform Build Guide

**Author:** Angerlyns Julceus  
**Stack:** AWS · Terraform · Windows (PowerShell)  
**Estimated Total Time:** 3–4 weeks across all phases

---

## 🏗️ What You Are Building

A production-grade AWS data platform that:
- 📡 Ingests live sales events via Kinesis Data Streams
- 🔄 Lands, transforms, and aggregates data through AWS Glue into S3 (bronze/silver/gold)
- 🔍 Makes data queryable via Athena and RDS MySQL
- 🤖 Generates AI-powered executive summaries via Amazon Bedrock
- 🔒 Is secured end-to-end with KMS Customer Managed Keys, IAM Least-Privilege Roles, and SSM Parameter Store
- 📊 Is fully observable via CloudWatch

Every resource in this project is deployed and managed through Terraform. No portal clicking for infrastructure — the AWS Console is used only for validation.

---

## 🔐 Security Architecture

This platform is built on an **Identity-Centric, Zero-Trust security model**. Every service authenticates via IAM — no credentials are ever stored on instances, in scripts, or in source control.

**🗝️ Centralized Encryption Hub (KMS)**  
A single Customer Managed Key (CMK) is created in Phase 1 and referenced by alias across all subsequent phases. This implements separation of duties — the encryption key lifecycle is managed independently from the services that use it. All data at rest across S3, RDS, Kinesis, and SSM is encrypted using this CMK.

**👤 Least-Privilege IAM**  
Every service gets its own IAM role scoped to only the actions it needs. For example, the EC2 simulator role can only `PutRecord` to Kinesis and `GetParameter` from SSM — nothing else. No wildcard actions, no shared credentials.

**🔗 Encryption in Transit**  
All AWS service communication uses TLS by default. No unencrypted endpoints are exposed.

---

## 📐 Phase Architecture — Modular Domain Blocks

Each phase is an independent Terraform root module with its own state file. This is not just an organizational choice — it reflects how production data platforms are actually maintained. The Foundation layer (Phase 1) has a different change frequency and risk profile than the AI layer (Phase 5). Decoupling them means a change to the observability config cannot accidentally affect core infrastructure.

| Phase | Domain | What Gets Built | Key AWS Resources |
|---|---|---|---|
| 1 — Foundation | 🏛️ Platform Core | S3 data lake, KMS, RDS, base IAM | `aws_s3_bucket`, `aws_kms_key`, `aws_db_instance` |
| 2 — Ingestion | 📡 Data Capture | Kinesis stream, simulation EC2 | `aws_kinesis_stream`, `aws_instance`, `aws_iam_role` |
| 3 — Orchestration | ⚙️ Data Processing | Glue jobs, crawlers, pipelines | `aws_glue_job`, `aws_glue_crawler` |
| 4 — Querying | 🔍 Data Access | Athena workgroup, Glue catalog | `aws_athena_workgroup`, `aws_glue_catalog_database` |
| 5 — AI | 🤖 Intelligence | Bedrock model, Lambda summariser | `aws_bedrock_model`, `aws_lambda_function` |
| 6 — Observability | 📊 Operations | CloudWatch alarms, dashboards | `aws_cloudwatch_metric_alarm`, `aws_cloudwatch_dashboard` |

---

## 🧠 Architectural Decisions

These decisions answer the questions a senior engineer or hiring manager would ask about the design.

**⚡ Why Amazon Kinesis over Managed Kafka (MSK)?**  
Kinesis Data Streams was chosen to prioritize serverless operational efficiency and native AWS integration. Unlike MSK, Kinesis requires zero cluster management and scales throughput elastically via shard adjustments without manual repartitioning. For a platform at this stage, the reduced operational overhead outweighs the additional flexibility MSK provides.

**📦 Why independent state management per phase?**  
Each phase is treated as an independent Terraform root module with its own state file. This minimizes the blast radius during deployments — a failed apply in Phase 5 cannot corrupt the state of Phase 1. It also simulates a real production environment where platform infrastructure and AI layers are owned and deployed by different teams on different schedules.

**🔗 Why data source lookups instead of remote state?**  
To reduce module coupling, AWS data sources (lookups by name or alias) are used rather than `terraform_remote_state`. This late-binding approach makes each module more portable and prevents state-locking dependencies between phases. A Phase 2 deployment does not need to read Phase 1's state file — it simply looks up the KMS alias by name.

---

## 📁 Project Folder Structure

All commands in this guide use relative paths. Before running anything, `cd` into your project directory:

```powershell
cd $HOME\data-platform-001
```

The full structure:

```
data-platform-001/
├── phase1-foundation/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── phase2-ingestion/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── user_data.sh
├── phase3-orchestration/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── phase4-querying/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── phase5-ai/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── phase6-observability/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── scripts/
    └── simulate_sales.py
```

---

## 🖥️ Windows Prerequisites

Before starting Phase 1, complete all of the following. All commands run in PowerShell.

**1. Install Terraform**

Download the Terraform binary from https://developer.hashicorp.com/terraform/install and select Windows AMD64. Extract the zip, move `terraform.exe` to `C:\terraform\`, then add it to your PATH:

```powershell
[Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";C:\terraform", "User")
```

Close and reopen PowerShell, then verify:
```powershell
terraform --version
```
You should see `Terraform v1.x.x`. Any version 1.3 or higher works for this project.

---

**2. Install AWS CLI**

Download and run the MSI installer from https://aws.amazon.com/cli/

After installation close and reopen PowerShell, then verify:
```powershell
aws --version
```

---

**3. Configure AWS Credentials**

```powershell
aws configure
```

You will be prompted for:
- AWS Access Key ID
- AWS Secret Access Key
- Default region — enter `us-east-1`
- Default output format — enter `json`

To get your access keys: AWS Console → IAM → Users → your user → Security credentials → Create access key.

Confirm your identity:
```powershell
aws sts get-caller-identity
```

---

**4. Install Python 3 (for the simulation script in Phase 2)**

Download the installer from https://www.python.org/downloads/ — select the latest 3.x release. During installation, check **Add Python to PATH** before clicking Install.

Verify in a new PowerShell window:
```powershell
python --version
```

---

**5. Verify SSH Client (for connecting to the simulation EC2 in Phase 2)**

SSH is built into Windows 10 and 11. Verify it is available:
```powershell
ssh -V
```

If not found, enable it via Settings → Apps → Optional Features → Add a feature → OpenSSH Client.

---

## ⚙️ AWS-Specific Terraform Patterns Used Throughout

**Provider Block**  
Every phase starts with the AWS provider pinned to version 5.0 or higher and the region pulled from a variable — never hardcoded.

```hcl
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
```

**Referencing Resources Across Phases**  
Because each phase has its own state file, later phases reference earlier phase resources using data source lookups by name — for example looking up the Phase 1 KMS key by its alias. This is simpler than remote state for a single-person project and avoids backend configuration complexity.

**IAM Role Pattern**  
Used in every phase that touches KMS, S3, Kinesis, or SSM. Every service that needs AWS access gets an IAM role with least-privilege policies — no credentials are ever stored on instances or in scripts.

---

## 🏷️ Naming Conventions Used Throughout

| Resource | Pattern | Example |
|---|---|---|
| KMS Key Alias | `alias/kms-sales-[yourname]` | `alias/kms-sales-a3julceus6` |
| S3 Buckets | `[layer]-sales-[yourname]-[account_id]` | `bronze-sales-a3julceus6-767828742181` |
| IAM User | `user-sales-[yourname]` | `user-sales-a3julceus6` |
| IAM Role | `role-[service]-[yourname]` | `role-simulator-a3julceus6` |
| RDS Instance | `rds-sales-[yourname]` | `rds-sales-a3julceus6` |
| Kinesis Stream | `sales-events-[yourname]` | `sales-events-a3julceus6` |
| EC2 Instance | `ec2-simulator-[yourname]` | `ec2-simulator-a3julceus6` |
| VPC | `vpc-sales-[yourname]` | `vpc-sales-a3julceus6` |

All names should be lowercase with hyphens. S3 bucket names are globally unique across all AWS accounts — the account ID suffix ensures uniqueness.

---

## 🚢 Deploy Order

Phases must be deployed in order — each phase depends on resources created by the previous one:

```powershell
cd phase1-foundation    → terraform init → terraform apply
cd phase2-ingestion     → terraform init → terraform apply
cd phase3-orchestration → terraform init → terraform apply
# and so on...
```

Destroy in reverse order:
```powershell
cd phase6-observability → terraform destroy
cd phase5-ai            → terraform destroy
# and so on back to phase1
```

---

## 📋 How to Work Through This Guide

- `cd` into your project directory first — every command runs relative to where you are
- Work through each phase README in order
- Always run `terraform init` → `terraform validate` → `terraform plan` → `terraform apply`
- Validate using the AWS Console or AWS CLI before moving to the next phase
- Each phase README includes a verification checklist — do not skip these
- `terraform.tfvars` is gitignored — use `terraform.tfvars.example` in each phase as a reference

---

## 🔭 Future Roadmap

- 🔄 **CI/CD Integration** — Implementing GitHub Actions with `terraform plan` automation and OIDC-based AWS authentication to remove manual deployments from PowerShell
- 🧊 **Modern Table Formats** — Migrating S3 storage patterns to Apache Iceberg or Delta Lake to support ACID transactions and schema evolution within the Glue and Athena layer
- 🌐 **Multi-AZ Resilience** — Expanding the Phase 1 Foundation to a full Multi-Availability Zone VPC architecture to ensure high availability for the RDS instance and simulation nodes
- ❄️ **Snowflake Integration** — Adding a Phase 7 using S3 as an external stage to demonstrate hybrid-cloud data movement between AWS and Snowflake

---

Start with **Phase 1 — Foundation**. 🏁
