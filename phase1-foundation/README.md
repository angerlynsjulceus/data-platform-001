# Phase 1: Foundation — S3 Data Lake, KMS, RDS, Base IAM

**Estimated Time:** 2–3 hours  
**What you will deploy:** The base infrastructure everything else builds on top of.

---

## What Gets Built in This Phase

```
AWS Account
├── KMS Key (alias/kms-sales-[yourname])
│   └── Encrypts S3, RDS, and SSM resources across all phases
├── S3 Data Lake
│   ├── Bucket: bronze-sales-[yourname]-[account_id]  ← raw incoming data
│   ├── Bucket: silver-sales-[yourname]-[account_id]  ← cleaned / structured data
│   └── Bucket: gold-sales-[yourname]-[account_id]    ← aggregated / analytics-ready data
├── IAM User + Policy
│   └── user-sales-[yourname] → full access to KMS and S3
└── RDS MySQL (db.t3.micro)
    ├── VPC + 2 Subnets (multi-AZ)
    └── Security Group — port 3306
```

The Bronze/Silver/Gold pattern (also called a medallion architecture) is the standard way to organize a data lake. Raw data lands in Bronze exactly as received. Silver holds cleaned, typed, structured versions. Gold holds aggregated summaries ready for reporting and AI consumption.

---

## Azure → AWS Service Mapping

| Azure | AWS |
|---|---|
| Resource Group | Not needed — AWS resources are region-scoped |
| ADLS Gen2 Storage Account | S3 buckets with versioning + KMS encryption |
| Storage Containers (bronze/silver/gold) | S3 buckets per medallion layer |
| Key Vault | KMS key + alias |
| RBAC Key Vault Administrator | IAM user + policy with `kms:*` |
| RBAC Storage Blob Data Contributor | IAM policy with `s3:*` |

---

## Folder Setup

From inside your `data-platform-001` directory, all phase folders are already created. Move into Phase 1:

```powershell
cd phase1-foundation
```

Files already created:
```
phase1-foundation/
├── main.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars
```

---

## Step 1 — variables.tf

This file declares all inputs so nothing is hardcoded in your main config. It defines:

- `yourname` — a string suffix appended to every resource name to make them unique across the project
- `region` — the AWS region to deploy into, defaults to `us-east-1`
- `tags` — a map of tags applied to every resource for cost tracking and project identification
- `db_password` — the RDS MySQL root password, marked as `sensitive` so it never appears in Terraform output or state in plain text
- `allowed_cidr` — the IP range allowed to connect to RDS on port 3306. Use your own IP in production

---

## Step 2 — terraform.tfvars

This file provides the actual values for the variables declared in `variables.tf`. Replace `yourname` with your own name — it will be appended to every resource created in this phase.

> ⚠️ `terraform.tfvars` is excluded from git via `.gitignore`. Never commit it — use `terraform.tfvars.example` as a reference instead.  
> Pass `db_password` via environment variable — never put it in `terraform.tfvars`:
> ```powershell
> $env:TF_VAR_db_password="YourStrongPassword123!"
> ```

> Why a separate `.tfvars` file? It keeps your variable values separate from your configuration. When you move to a team environment or CI/CD pipeline, you swap the `.tfvars` file without touching any Terraform code.

---

## Step 3 — main.tf

This is the core infrastructure file. It is broken into five sections:

**Provider & Identity**  
Configures the AWS provider with the region from your variables and pulls your current AWS account ID using `aws_caller_identity`. The account ID is used to make S3 bucket names globally unique.

**KMS — Encryption Key**  
Creates a single customer-managed KMS key with automatic key rotation enabled and a 7-day deletion window. A human-readable alias is attached so other phases can look it up by name without needing the key ID. This one key encrypts S3, RDS, and SSM across all phases — sharing one key keeps costs low.

**S3 Data Lake — Medallion Architecture**  
Creates three S3 buckets following the bronze/silver/gold pattern. Each bucket gets versioning enabled to protect against accidental deletion, KMS encryption using the key created above, and all four public access block settings enabled so no data can ever be made public accidentally.

**IAM — User and Policy**  
Creates a dedicated IAM user for the data platform and attaches a policy granting full access to the KMS key and all three S3 buckets. The policy covers both the bucket ARN and the object ARN (`bucket/*`) — both are required because AWS separates bucket-level actions like `s3:ListBucket` from object-level actions like `s3:GetObject`.

**RDS — MySQL Database**  
Creates a dedicated VPC with two subnets across two availability zones — AWS requires at least two AZs in a subnet group even for single-AZ RDS deployments. A security group is created to allow MySQL traffic on port 3306 from your `allowed_cidr`. The RDS instance runs MySQL 8.0 on a `db.t3.micro` with 20GB storage, encrypted with the KMS key.

> Note: Unlike Azure, AWS does not require a Resource Group. Resources are scoped to a region and account directly.

---

## Step 4 — outputs.tf

Outputs expose key resource values after deployment. These are used by later phases to reference Phase 1 resources without hardcoding names or IDs. Outputs include the IAM user name and ARN, S3 bucket names and ARNs as a map, KMS key ID, ARN and alias, and the RDS endpoint and database name.

---

## Step 5 — Deploy

From inside the `phase1-foundation` folder run these commands in order:

```powershell
# Download the AWS provider plugin
terraform init
```
You should see: `Terraform has been successfully initialized.`

```powershell
# Preview what will be created — read this carefully before applying
terraform plan
```
You should see approximately 18 resources to add: KMS key, alias, 3 S3 buckets + versioning + encryption + public access blocks, IAM user + policy + attachment, VPC, 2 subnets, subnet group, security group, and RDS instance.

```powershell
# Deploy
terraform apply
```
Terraform will show the plan again and prompt:
```
Do you want to perform these actions? yes
```
Type `yes` and press Enter. Deployment takes approximately 3–5 minutes due to RDS creation.

---

## Verification Checklist

Open the AWS Console or use the AWS CLI commands below to confirm each of the following:

- [ ] KMS → Customer managed keys — `kms-sales-[yourname]` exists with alias `alias/kms-sales-[yourname]`
```powershell
aws kms list-aliases --query "Aliases[?contains(AliasName, 'kms-sales')]" --output table
```

- [ ] S3 → Buckets — three buckets exist: `bronze-sales-[yourname]-[account_id]`, `silver-sales-[yourname]-[account_id]`, `gold-sales-[yourname]-[account_id]`
```powershell
aws s3 ls | findstr "sales"
```

- [ ] Each S3 bucket → Properties → Server-side encryption shows `aws:kms`
```powershell
aws s3api get-bucket-encryption --bucket "bronze-sales-[yourname]-[account_id]"
```

- [ ] Each S3 bucket → Permissions → Block public access shows all 4 settings enabled
```powershell
aws s3api get-public-access-block --bucket "bronze-sales-[yourname]-[account_id]"
```

- [ ] IAM → Users — `user-sales-[yourname]` exists with `policy-sales-admin-[yourname]` attached
```powershell
aws iam list-attached-user-policies --user-name "user-sales-[yourname]"
```

- [ ] RDS → Databases — `rds-sales-[yourname]` exists and status is `Available`
```powershell
aws rds describe-db-instances --db-instance-identifier "rds-sales-[yourname]" --query "DBInstances[0].DBInstanceStatus"
```

- [ ] VPC → Your VPCs — `vpc-sales-[yourname]` exists with two subnets
```powershell
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=vpc-sales-[yourname]" --query "Vpcs[0].VpcId"
```

---

## Troubleshooting

| Error | Cause | Resolution |
|---|---|---|
| S3 bucket name already taken | S3 bucket names are globally unique across all AWS accounts | The bucket name includes your account ID so this should not occur — check `yourname` has no spaces or uppercase |
| `InvalidClientTokenId` | AWS credentials not configured | Run `aws configure` in PowerShell and set your access key and region |
| `db_password` not set | Sensitive variable has no default | Set via `$env:TF_VAR_db_password="yourpassword"` in PowerShell before running `terraform apply` |
| RDS creation timeout | RDS takes 5–10 mins to provision | Wait and re-run `terraform apply` — it will pick up where it left off |
| KMS key pending deletion on re-deploy | KMS has a 7-day deletion window | Wait 7 days or use the AWS Console to cancel the pending deletion |
| `InvalidParameterValue` on security group name | Security group names cannot start with `sg-` | Already fixed — name uses `rds-sg-` prefix |

---

## Key Concepts Introduced in This Phase

| Concept | What it means |
|---|---|
| Medallion Architecture | Bronze/Silver/Gold zone pattern for organizing a data lake by data quality stage |
| KMS (Key Management Service) | AWS managed encryption key service — replaces Azure Key Vault for encryption. One key shared across all phases keeps costs low |
| S3 Versioning | Keeps previous versions of objects — protects against accidental deletion or overwrites |
| IAM User vs Managed Identity | AWS uses IAM users/roles with explicit policies. Unlike Azure Managed Identity, permissions must cover both bucket ARN and object ARN (`bucket/*`) |
| RDS Subnet Group | RDS requires at least 2 subnets in different availability zones — AWS enforces this even for single-AZ deployments |

---

Once all checklist items are confirmed, proceed to **Phase 2 — Ingestion**.
