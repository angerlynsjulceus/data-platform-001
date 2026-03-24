# Real-Time Sales Intelligence Platform — Terraform Build Guide

**Author:** Angerlyns Julceus  
**Stack:** AWS · Terraform · Windows (PowerShell)  
**Estimated Total Time:** 3–4 weeks across all phases

---

## What You Are Building

A production-grade AWS data platform that:
- Ingests live sales events via Kinesis Data Streams
- Lands, transforms, and aggregates data through AWS Glue into S3 (bronze/silver/gold)
- Makes data queryable via Athena and RDS MySQL
- Generates AI-powered executive summaries via Amazon Bedrock
- Is secured end-to-end with KMS, IAM Roles, and SSM Parameter Store
- Is fully observable via CloudWatch

Every resource in this project is deployed and managed through Terraform. No portal clicking for infrastructure — the AWS Console is used only for validation.

---

## Project Folder Structure

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

Each phase is an independent Terraform root module with its own state file. Each phase can be deployed, updated, or destroyed independently without affecting other phases.

---

## Windows Prerequisites

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

## AWS-Specific Terraform Patterns Used Throughout

Since you are comfortable with Terraform generally, here are the AWS-specific conventions this project follows consistently.

**Provider Block**  
Every phase starts with the AWS provider pinned to version 5.0 or higher and the region pulled from a variable — never hardcoded.

**Data Source for Current Account**  
Used throughout for building ARNs and making resource names unique:
```hcl
data "aws_caller_identity" "current" {}
# Access with: data.aws_caller_identity.current.account_id
```

**Referencing Resources Across Phases**  
Because each phase has its own state file, later phases reference earlier phase resources using data source lookups by name — for example looking up the Phase 1 KMS key by its alias. This is simpler than remote state for a single-person project and avoids backend configuration complexity.

**IAM Role Pattern**  
Used in every phase that touches KMS, S3, Kinesis, or SSM. Every service that needs AWS access gets an IAM role with least-privilege policies — no credentials are ever stored on instances or in scripts.

---

## Phase Summary

| Phase | What Gets Built | Key AWS Resources |
|---|---|---|
| 1 — Foundation | S3 data lake, KMS, RDS, base IAM | `aws_s3_bucket`, `aws_kms_key`, `aws_db_instance` |
| 2 — Ingestion | Kinesis stream, simulation EC2 | `aws_kinesis_stream`, `aws_instance`, `aws_iam_role` |
| 3 — Orchestration | Glue jobs, crawlers, pipelines | `aws_glue_job`, `aws_glue_crawler` |
| 4 — Querying | Athena workgroup, Glue catalog | `aws_athena_workgroup`, `aws_glue_catalog_database` |
| 5 — AI | Bedrock model, Lambda summariser | `aws_bedrock_model`, `aws_lambda_function` |
| 6 — Observability | CloudWatch alarms, dashboards | `aws_cloudwatch_metric_alarm`, `aws_cloudwatch_dashboard` |

---

## Naming Conventions Used Throughout

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

## Deploy Order

Phases must be deployed in order — each phase depends on resources created by the previous one:

```powershell
cd phase1-foundation  → terraform init → terraform apply
cd phase2-ingestion   → terraform init → terraform apply
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

## How to Work Through This Guide

- `cd` into your project directory first — every command runs relative to where you are
- Work through each phase README in order
- Always run `terraform init` → `terraform validate` → `terraform plan` → `terraform apply`
- Validate using the AWS Console or AWS CLI before moving to the next phase
- Each phase README includes a verification checklist — do not skip these
- `terraform.tfvars` is gitignored — use `terraform.tfvars.example` in each phase as a reference

---

Start with **Phase 1 — Foundation**.
