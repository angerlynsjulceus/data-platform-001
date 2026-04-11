# Phase 4: Querying — Amazon Athena

**Estimated Time:** 2–3 hours
**What you will deploy:** An Athena workgroup connected to your silver S3 layer via the Glue Data Catalog, with a least-privilege IAM policy and sample queries that answer business questions about sales performance.

---

## What Gets Built in This Phase

```
AWS Athena
└── Workgroup: workgroup-sales-[yourname]
    ├── Query results → s3://gold-sales-[yourname]-[account_id]/athena-results/
    ├── Encryption: SSE-KMS (same key as all other platform data)
    └── Scan limit: 1 GB per query (cost guardrail)

IAM
└── policy-athena-[yourname]
    └── Attached to user-sales-[yourname] (created in Phase 1)

Glue Data Catalog (read-only lookup from Phase 3)
└── Database: db_silver_[yourname]
    └── Table: sales (registered by Phase 3 crawler)
```

---

## Azure → AWS Service Mapping

| Azure | AWS | Why |
|---|---|---|
| Synapse Analytics Workspace | Amazon Athena Workgroup | Both are serverless SQL query engines — no cluster to manage, pay per query |
| Synapse Serverless SQL Pool | Athena (built into the workgroup) | Athena is always serverless — there is no dedicated vs serverless choice to make |
| System-assigned Managed Identity | IAM policy attached to IAM user | Both control who can access the query engine and underlying storage |
| `azurerm_role_assignment` (Storage Blob Contributor) | `aws_iam_policy` with S3 + Glue permissions | Both grant the query engine read access to the data lake |
| Synapse Firewall Rules | Not needed | Athena is a managed HTTPS API — there is no server to firewall, IAM handles all access control |
| `azurerm_synapse_role_assignment` (Synapse Administrator) | `aws_iam_user_policy_attachment` | Both grant your identity permission to run queries |
| External Table over ADLS | Athena query against Glue catalog table | Both create a virtual table definition that reads directly from storage without copying data |
| Synapse SQL admin username + password | Not needed | Athena has no concept of a SQL login — authentication is IAM only |

---

## ⚠️ Prerequisites — Deploy These First

Phase 4 looks up resources from Phases 1, 2, and 3 at plan time. All three must be fully deployed and the Phase 3 Glue crawler must have been run before `terraform plan` will succeed here.

1. Deploy Phase 1 — KMS key, S3 buckets (bronze/silver/gold), IAM user must exist
2. Deploy Phase 2 — EC2 simulator, Kinesis stream must exist
3. Deploy Phase 3 — Glue job must have run successfully and Parquet must exist in silver
4. Run Phase 3 Step 8 — the Glue crawler must have completed so the `db_silver_[yourname]` catalog database exists
5. Then return here and proceed with Phase 4

If the Glue catalog database does not exist, `terraform plan` will fail with a "not found" error on the `data "aws_glue_catalog_database"` lookup.

---

## Folder Setup

From your project root:

```powershell
cd phase4-querying
```

You should have:

```
phase4-querying/
├── main.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars
```

---

## Step 1 — variables.tf

This file declares the same three variables used in every phase of this project.

`yourname` has no default — Terraform errors if it is not set, preventing deployments with a blank name.

`region` defaults to `us-east-1` and is passed to the AWS provider so the region is never hardcoded in resource definitions.

`tags` is the same map used across all phases — `project`, `environment`, and `managed_by` — so every resource is consistently labeled.

---

## Step 2 — terraform.tfvars

This file supplies `yourname = "wirte_a_name"` and `region = "us-east-1"`. Every resource name in `main.tf` is built from `var.yourname` at plan time.

This file is gitignored. Use `terraform.tfvars.example` as a reference if you need to recreate it.

---

## Step 3 — main.tf

### Why Athena over Redshift or EMR?

Athena is serverless — there is no cluster to provision, patch, or scale. You pay only per query at $5 per TB scanned. For a lab querying a few KB of Parquet, each query costs fractions of a cent.

Redshift requires a running cluster that bills by the hour even when idle — the smallest node starts at roughly $0.25/hr. EMR gives you more control but requires managing a cluster lifecycle. For ad-hoc analytics on S3 Parquet data at this scale, Athena is the correct choice.

### Provider and data source lookups

The `terraform` block pins the AWS provider to version 5.0 or higher — consistent with all previous phases.

`data "aws_caller_identity"` retrieves your AWS account ID at plan time to construct the S3 bucket names.

`data "aws_kms_alias"` and `data "aws_kms_key"` look up the Phase 1 KMS key by alias. The alias lookup gives the alias ARN but IAM policies require the actual key ARN — both lookups are needed, same as Phases 2 and 3.

`data "aws_s3_bucket" "silver"` and `data "aws_s3_bucket" "gold"` look up the Phase 1 buckets by name. Phase 4 does not create any buckets — it reads from silver and writes query results to gold.

`data "aws_glue_catalog_database" "silver"` looks up the catalog database registered by the Phase 3 crawler. Athena uses the Glue Data Catalog as its metastore — without this database, Athena has no table definitions to query against.

### S3 results prefix

`aws_s3_object` creates an empty placeholder object at `gold/.../athena-results/`. This establishes the prefix in S3 before Athena tries to write results there. Athena will write query output CSV files and metadata into this prefix automatically after each query runs.

### Athena Workgroup

`aws_athena_workgroup` is the direct equivalent of the Synapse workspace. A workgroup is Athena's unit of configuration and cost control — it defines where results land, enforces encryption, and sets query limits.

`bytes_scanned_cutoff_per_query = 1073741824` sets a 1 GB scan limit per query. Any query that would scan more than 1 GB is killed before it runs. This is a cost guardrail that Synapse did not have — it protects against accidentally expensive full-table scans on large datasets.

`output_location` points to the gold bucket's `athena-results/` prefix. Every query Athena runs writes its output CSV and metadata here. Without an output location, Athena refuses to run any query.

`encryption_configuration` with `SSE_KMS` encrypts all query result files using the same Phase 1 KMS key used across the entire platform. This replaces Synapse's transparent data encryption.

### IAM Policy

Synapse used firewall rules to control network access and a role assignment to grant your account admin rights. In AWS there is no firewall to configure — Athena is a managed HTTPS API. Access control is handled entirely by IAM.

The policy has five least-privilege statements:

- `AthenaQueryAccess` — allows starting, checking, stopping, and reading query executions against this specific workgroup ARN only. Scoped to one workgroup, not all of Athena.
- `GlueCatalogAccess` — allows reading the catalog database and tables Phase 3 registered. Without this, Athena cannot resolve table names to S3 paths when you run a query.
- `SilverRead` — `s3:GetObject` and `s3:ListBucket` on the silver bucket. Read-only, scoped to one bucket.
- `GoldResultsAccess` — `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` on the gold bucket. Athena needs write access here to store query results.
- `KMSAccess` — `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the Phase 1 KMS key. Needed to decrypt silver Parquet files and encrypt query result files.

`aws_iam_user_policy_attachment` attaches this policy to `user-sales-[yourname]` created in Phase 1. This is the equivalent of `azurerm_synapse_role_assignment` granting your account Synapse Administrator.

---

## Step 4 — outputs.tf

Four values are exported after deployment:

- `athena_workgroup_name` — the workgroup name, used in CLI query commands
- `athena_workgroup_arn` — the full ARN, referenced in IAM policies in later phases
- `athena_results_location` — the S3 path where query results land, useful for debugging
- `athena_database_name` — the Glue catalog database name Athena queries against

---

## Step 5 — Deploy

```powershell
terraform init
terraform validate
terraform plan
terraform apply
```

Expect 3 resources to add. Athena workgroup deployment takes under 30 seconds — significantly faster than Synapse.

Confirm outputs after apply:

```powershell
terraform output
```

---

## Step 6 — Run the Phase 3 Glue Crawler

Before querying, the Glue crawler must have run so the silver Parquet schema is registered in the catalog. If you already ran it in Phase 3 Step 8, skip this. If not, run it now:

```powershell
aws glue start-crawler --name crawler-silver-a3julceus6
```

Wait for it to complete:

```powershell
aws glue get-crawler --name crawler-silver-a3julceus6 `
  --query "Crawler.State"
```

Wait until it returns `READY`, then confirm the table exists:

```powershell
aws glue get-tables `
  --database-name db_silver_a3julceus6 `
  --query "TableList[].Name"
```

You should see `sales` in the output before running any Athena queries.

---

## Step 7 — Run Business Queries

Unlike Synapse Studio, Athena queries are run directly from the AWS CLI or the Athena console. No external table DDL is needed — the Glue crawler already registered the schema in Phase 3.

Run each query using the CLI. Each command starts the query and returns a `QueryExecutionId`. Use that ID to fetch results.

**Top products by total revenue:**

```powershell
aws athena start-query-execution `
  --query-string "SELECT product, SUM(quantity * unit_price) AS total_revenue, COUNT(*) AS transaction_count FROM sales GROUP BY product ORDER BY total_revenue DESC" `
  --work-group workgroup-sales-a3julceus6 `
  --query-execution-context "Database=db_silver_a3julceus6" `
  --result-configuration "OutputLocation=s3://gold-sales-a3julceus6-767828742181/athena-results/"
```

**Sales by region:**

```powershell
aws athena start-query-execution `
  --query-string "SELECT region, SUM(quantity * unit_price) AS revenue, AVG(unit_price) AS avg_price FROM sales GROUP BY region ORDER BY revenue DESC" `
  --work-group workgroup-sales-a3julceus6 `
  --query-execution-context "Database=db_silver_a3julceus6" `
  --result-configuration "OutputLocation=s3://gold-sales-a3julceus6-767828742181/athena-results/"
```

**Hourly transaction volume:**

```powershell
aws athena start-query-execution `
  --query-string "SELECT hour(timestamp) AS hour, COUNT(*) AS transactions, SUM(quantity * unit_price) AS revenue FROM sales GROUP BY hour(timestamp) ORDER BY hour" `
  --work-group workgroup-sales-a3julceus6 `
  --query-execution-context "Database=db_silver_a3julceus6" `
  --result-configuration "OutputLocation=s3://gold-sales-a3julceus6-767828742181/athena-results/"
```

Check query status — replace `YOUR_QUERY_EXECUTION_ID` with the value returned above:

```powershell
aws athena get-query-execution `
  --query-execution-id YOUR_QUERY_EXECUTION_ID `
  --query "QueryExecution.Status.State"
```

Wait for `SUCCEEDED`, then fetch results:

```powershell
aws athena get-query-results `
  --query-execution-id YOUR_QUERY_EXECUTION_ID
```

Even with just the one test file from Phase 3, these queries will return one row each — confirming the pipeline ran end-to-end and the data is queryable.

---

## Verification Checklist

- Athena workgroup exists:
```powershell
aws athena get-work-group --work-group workgroup-sales-a3julceus6 `
  --query "WorkGroup.Name"
```

- Query results prefix exists in gold bucket:
```powershell
aws s3 ls s3://gold-sales-a3julceus6-767828742181/athena-results/
```

- IAM policy attached to user:
```powershell
aws iam list-attached-user-policies --user-name user-sales-a3julceus6 `
  --query "AttachedPolicies[].PolicyName"
```

- Glue catalog database exists:
```powershell
aws glue get-database --name db_silver_a3julceus6 --query "Database.Name"
```

- Sales table registered in catalog:
```powershell
aws glue get-tables --database-name db_silver_a3julceus6 `
  --query "TableList[].Name"
```

- At least one Athena query returns `SUCCEEDED`:
```powershell
aws athena get-query-execution `
  --query-execution-id YOUR_QUERY_EXECUTION_ID `
  --query "QueryExecution.Status.State"
```

---

Once all checklist items pass, proceed to **Phase 5 — AI Layer**. 🏁
