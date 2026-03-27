# Phase 3: Orchestration — AWS Glue

**Estimated Time:** 2–3 hours
**What you will deploy:** A Glue ETL job with a least-privilege IAM role, a PySpark script uploaded to S3, and a Glue crawler that catalogs the silver output so Athena can query it in Phase 4.

---

## What Gets Built in This Phase

```
S3 bronze-sales-[yourname]-[account_id]
└── scripts/bronze_to_silver.py       ← PySpark script uploaded by Terraform

AWS Glue
├── IAM Role: role-glue-[yourname]    ← Identity Glue uses to access S3 and KMS
├── Job: glue-bronze-to-silver-[yourname]
│   ├── Source: s3://bronze.../sales/ (JSON)
│   └── Sink:   s3://silver.../sales/ (Parquet, Snappy compressed)
├── Catalog Database: db_silver_[yourname]
└── Crawler: crawler-silver-[yourname]
    └── Scans silver bucket → registers schema in Glue Data Catalog
```

---

## Azure → AWS Service Mapping

| Azure | AWS | Why |
|---|---|---|
| Azure Data Factory | AWS Glue | Managed ETL engine — runs transformation jobs on a serverless Spark cluster |
| ADF System-assigned Managed Identity | IAM Role (`role-glue-[yourname]`) | Both give the service an identity to authenticate without storing credentials |
| `azurerm_role_assignment` (Storage Blob Contributor) | `aws_iam_role_policy` + `AWSGlueServiceRole` | Both grant the service read/write access to storage |
| ADF Linked Service (ADLS connection) | Not needed | Glue reads S3 natively via IAM — no explicit connection object required |
| ADF Dataset (source/sink definition) | `--bronze_path` / `--silver_path` job arguments | Both define where data comes from and where it lands |
| ADF Pipeline Copy activity + column mappings | PySpark `StructType` schema in `bronze_to_silver.py` | Both enforce field names and types during the bronze → silver transformation |

---

## ⚠️ Prerequisites — Deploy These First

Phase 3 looks up resources created by Phase 1 and Phase 2 at plan time. If those phases are not deployed, `terraform plan` will fail with a "not found" error.

Before running anything in this phase:

1. Deploy Phase 1 — `cd phase1-foundation` → `terraform apply` → wait for it to complete fully
2. Deploy Phase 2 — `cd phase2-ingestion` → `terraform apply` → wait for it to complete fully
3. SSH into the EC2 instance and run `python3 ~/simulate_sales.py` to confirm the simulator is working and records are flowing into Kinesis
4. Then return here and proceed with Phase 3

Phase 3 reads from the bronze S3 bucket created in Phase 1. The KMS key and S3 buckets must exist before `terraform plan` will succeed.

---

## Folder Setup

From your project root:

```powershell
cd phase3-orchestration
```

The files were already created in Phase 1. You should have:

```
phase3-orchestration/
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── bronze_to_silver.py
```

---

## Step 1 — variables.tf

This file declares the three inputs every phase in this project uses.

`yourname` is a plain string with no default — Terraform will error if it is not set, which prevents accidental deployments with a blank name that would create incorrectly named resources.

`region` defaults to `us-east-1`. This is passed to the AWS provider so the region is never hardcoded anywhere in the resource definitions.

`tags` is a map applied to every resource Terraform creates in this phase. All three phases use the same tag set — `project`, `environment`, and `managed_by` — so every resource in your AWS account is consistently labeled and filterable in the console.

---

## Step 2 — terraform.tfvars

This file supplies the actual values for `yourname` and `region`. It is the only place your specific name appears — every resource name in `main.tf` is built from `var.yourname` at plan time, so changing this one value renames everything consistently.

This file is gitignored. Use `terraform.tfvars.example` as a reference if you need to recreate it.

---

## Step 3 — main.tf

### Why AWS Glue instead of a different service?

AWS Glue was chosen because it is the native serverless ETL service on AWS and the direct equivalent of Azure Data Factory's data movement and transformation capabilities. It runs PySpark on a managed Spark cluster — you define the transformation logic, AWS manages the cluster lifecycle. There is no server to provision, patch, or scale manually.

The alternative would be EMR (Elastic MapReduce), which gives you more control but requires managing a cluster. For a bronze-to-silver transformation at this scale, Glue's serverless model is the right tradeoff.

### Provider and data source lookups

The `terraform` block pins the AWS provider to version 5.0 or higher — the same constraint used in Phases 1 and 2.

`data "aws_caller_identity"` retrieves your AWS account ID at plan time. This is needed to construct the S3 bucket names, which include the account ID suffix from Phase 1.

`data "aws_kms_alias"` and `data "aws_kms_key"` look up the KMS key created in Phase 1 by its alias name. The alias lookup gives you the alias ARN, but IAM policies require the actual key ARN — that is why both lookups are needed. This is the same pattern used in Phase 2.

`data "aws_s3_bucket"` looks up the bronze and silver buckets by name. Phase 3 does not create these buckets — they already exist from Phase 1. The data source gives Terraform their ARNs so they can be referenced in IAM policies without hardcoding.

### IAM Role for Glue

In Azure, ADF used a System-assigned Managed Identity and you granted it the Storage Blob Data Contributor role via `azurerm_role_assignment`. In AWS the equivalent is an IAM role with a trust policy.

The trust policy on `aws_iam_role` says `glue.amazonaws.com` is allowed to assume this role. This is what gives the Glue service permission to act as this identity when it runs your job — without it, Glue cannot use the role at all.

`aws_iam_role_policy_attachment` attaches the AWS-managed `AWSGlueServiceRole` policy. This is a baseline policy AWS provides that grants Glue the minimum permissions it needs to write logs to CloudWatch, access Glue catalog APIs, and read from S3 paths Glue itself manages. You attach this in addition to your custom policy — not instead of it.

`data "aws_iam_policy_document"` defines four least-privilege statements:
- `BronzeRead` — `s3:GetObject` and `s3:ListBucket` on the bronze bucket. Read-only, scoped to one bucket.
- `SilverWrite` — `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket` on the silver bucket. Write access scoped to one bucket.
- `ScriptRead` — `s3:GetObject` on the `scripts/` prefix of the bronze bucket. Glue needs to download the PySpark script before it can run it.
- `KMSAccess` — `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the Phase 1 KMS key. Glue needs Decrypt to read KMS-encrypted bronze objects and GenerateDataKey to write KMS-encrypted silver objects.

### PySpark script upload

`aws_s3_object` uploads `bronze_to_silver.py` from your local `phase3-orchestration/` folder to `s3://bronze-.../scripts/bronze_to_silver.py`.

The `source` attribute points to the local file. Terraform will re-upload the script if the file content changes on subsequent `terraform apply` runs.

`kms_key_id` ensures the script object itself is encrypted at rest using the same KMS key as all other data in the platform.

> ⚠️ **Known issue:** `etag` conflicts with `kms_key_id` in the AWS provider — AWS cannot compute a plain MD5 checksum of a KMS-encrypted object. The `etag` attribute was removed for this reason. This is an AWS provider limitation, not a Terraform bug.

### Glue Job

`aws_glue_job` is the equivalent of the ADF pipeline. It defines what script to run, where to find it, and what arguments to pass.

The `command` block sets `script_location` to the S3 path where the script was just uploaded. `name = "glueetl"` tells Glue this is a standard Spark ETL job (as opposed to a streaming or Python shell job).

`default_arguments` passes four values to the job at runtime:
- `--bronze_path` and `--silver_path` are the S3 paths the PySpark script reads from and writes to. These replace ADF's dataset definitions — the script calls `getResolvedOptions` to read them at runtime.
- `--enable-metrics` and `--enable-job-insights` turn on CloudWatch metrics and Glue's built-in job profiling. These cost nothing extra and are essential for Phase 6 observability.

`glue_version = "4.0"` is Spark 3.3 with Python 3.10 — the current latest. `worker_type = "G.1X"` is the smallest available worker (1 DPU, 4 vCPU, 16 GB memory). `number_of_workers = 2` is the minimum Glue allows. `timeout = 10` kills the job after 10 minutes — a safety net that prevents a runaway job from accumulating cost.

### Glue Crawler and Catalog Database

This has no direct equivalent in the Azure version. ADF wrote Parquet to ADLS and the schema was inferred at query time by Synapse or Azure SQL. In AWS, Athena (Phase 4) cannot query S3 data without a table definition in the Glue Data Catalog first.

`aws_glue_catalog_database` creates a logical database namespace in the Glue catalog. The name uses `replace(var.yourname, "-", "_")` because Glue catalog database names cannot contain hyphens.

`aws_glue_crawler` scans the silver bucket's `sales/` prefix, infers the Parquet schema, and registers it as a table in the catalog database. You run the crawler once after the Glue job completes — after that, Athena can query the table by name. The `CrawlerOutput` configuration tells the crawler to inherit partition behavior from the existing table rather than overwriting it on subsequent runs.

---

## Step 4 — outputs.tf

Five values are exported after deployment:

- `glue_job_name` — the name of the Glue job, used to trigger it via CLI
- `glue_job_arn` — the full ARN, useful for IAM policies in later phases
- `glue_role_arn` — the IAM role ARN Glue uses, exported for reference
- `glue_crawler_name` — needed to trigger the crawler via CLI after the job runs
- `glue_catalog_database` — the database name Phase 4 Athena queries against

---

## Step 5 — Deploy

```powershell
terraform init
terraform validate
terraform plan
terraform apply
```

Expect 8 resources to add. Deployment takes 1–2 minutes — Glue resources provision faster than ADF.

Confirm outputs after apply:

```powershell
terraform output
```

---

## Step 6 — Upload Test Data to Bronze

The Glue job reads from `s3://bronze-.../sales/`. That prefix needs at least one JSON file before you run the job.

Create and upload a test record:

```powershell
$json = '{"transaction_id":"TXN-123456","timestamp":"2026-03-01T12:00:00","product":"Laptop","quantity":1,"unit_price":999.99,"region":"East","store_id":"STORE-001"}'
$json | Out-File -FilePath "$env:TEMP\test_sales.json" -Encoding utf8

aws s3 cp "$env:TEMP\test_sales.json" `
  s3://bronze-sales-a3julceus6-767828742181/sales/test_sales.json
```

Verify it landed:

```powershell
aws s3 ls s3://bronze-sales-a3julceus6-767828742181/sales/
```

You should see `test_sales.json` in the output before continuing.

---

## Step 7 — Run the Glue Job

Trigger the job:

```powershell
aws glue start-job-run --job-name glue-bronze-to-silver-a3julceus6
```

This returns a `JobRunId`. Use it to check status:

```powershell
aws glue get-job-run `
  --job-name glue-bronze-to-silver-a3julceus6 `
  --run-id <JobRunId>
```

Wait until `JobRunState` shows `SUCCEEDED`. The job typically takes 3–5 minutes on the first run because Glue provisions the Spark cluster from scratch.

If the state shows `FAILED`, check the error:

```powershell
aws glue get-job-run `
  --job-name glue-bronze-to-silver-a3julceus6 `
  --run-id <JobRunId> `
  --query "JobRun.ErrorMessage"
```

After the job succeeds, verify Parquet landed in silver:

```powershell
aws s3 ls s3://silver-sales-a3julceus6-767828742181/sales/ --recursive
```

You should see one or more `.parquet` files.

---

## Step 8 — Run the Glue Crawler

> ⚠️ **Skip this step until you have deployed Phase 4.** The crawler registers the silver schema in the Glue Data Catalog so Athena can query it — but Athena is not set up until Phase 4. There is no benefit to running the crawler now. Come back to this step when you are ready to start Phase 4.

The crawler scans the silver output and registers the schema in the Glue Data Catalog so Athena can query it in Phase 4.

Start the crawler:

```powershell
aws glue start-crawler --name crawler-silver-a3julceus6
```

Check crawler status:

```powershell
aws glue get-crawler --name crawler-silver-a3julceus6 `
  --query "Crawler.State"
```

Wait until it returns `READY` — that means the crawl completed. Then confirm the table was registered:

```powershell
aws glue get-tables `
  --database-name db_silver_a3julceus6 `
  --query "TableList[].Name"
```

You should see a table named `sales` in the output.

---

## Verification Checklist

- IAM role `role-glue-a3julceus6` exists:
```powershell
aws iam get-role --role-name role-glue-a3julceus6 --query "Role.RoleName"
```

- Glue job exists:
```powershell
aws glue get-job --job-name glue-bronze-to-silver-a3julceus6 --query "Job.Name"
```

- PySpark script uploaded to bronze bucket:
```powershell
aws s3 ls s3://bronze-sales-a3julceus6-767828742181/scripts/
```

- Glue job run succeeded:
```powershell
aws glue get-job-runs --job-name glue-bronze-to-silver-a3julceus6 `
  --query "JobRuns[0].JobRunState"
```

- Parquet file exists in silver bucket:
```powershell
aws s3 ls s3://silver-sales-a3julceus6-767828742181/sales/ --recursive
```

- Glue catalog database exists:
```powershell
aws glue get-database --name db_silver_a3julceus6 --query "Database.Name"
```

- Crawler registered the sales table:
```powershell
aws glue get-tables --database-name db_silver_a3julceus6 --query "TableList[].Name"
```

---

Once all checklist items pass, proceed to **Phase 4 — Querying**. 🏁
