# Phase 5: AI Layer — Amazon Bedrock & AWS Lambda

**Estimated Time:** 2–3 hours
**What you will deploy:** A Lambda function with a least-privilege IAM role that reads Athena query results from the gold S3 bucket, calls Amazon Bedrock to generate an executive summary, and writes the summary back to S3.

---

## What This Phase Is Actually Doing

Phase 5 wires up the AI layer and proves the full pipeline works end-to-end.

The Lambda function does three things:

1. Reads the latest Athena query result CSV from the gold S3 bucket
2. Sends the sales data to Amazon Bedrock as a prompt
3. Writes the generated executive summary back to `gold/summaries/`

Unlike the Azure version which used hardcoded dummy data to test the AI connection, this AWS version reads real Athena output that your pipeline already produced in Phase 4. By Phase 5 you have actual data flowing through the system — there is no reason to use dummy data.

---

## What Gets Built in This Phase

```
AWS Lambda
└── lambda-summariser-[yourname]
    ├── IAM Role: role-lambda-[yourname]
    ├── Runtime: Python 3.12
    ├── Source: summarise_sales.py (zipped by Terraform)
    ├── Reads from:  s3://gold-.../athena-results/
    └── Writes to:   s3://gold-.../summaries/

SSM Parameter Store
└── /sales/[yourname]/bedrock-model-id
    └── Value: amazon.titan-text-lite-v1 (encrypted with KMS)
```

---

## Azure → AWS Service Mapping

| Azure | AWS | Why |
|---|---|---|
| Azure OpenAI (`azurerm_cognitive_account`) | Amazon Bedrock | Bedrock is AWS's managed AI service — models are enabled at the account level, no deployment to provision |
| GPT-4o-mini model deployment | `amazon.titan-text-lite-v1` | Both are lightweight, cost-efficient models suited for summarization tasks |
| AI Foundry Hub + Project | Not needed | These are Azure ML workspace constructs — Bedrock is called directly from Lambda via IAM, no workspace required |
| Separate storage account for AI Hub | Not needed | Bedrock needs no backing storage |
| Key Vault secrets (API key + endpoint) | SSM Parameter (model ID only) | Bedrock uses IAM — there is no API key. SSM stores the model ID so Lambda can retrieve it without hardcoding |
| `azurerm_role_assignment` (Cognitive Services OpenAI User) | `aws_iam_role_policy` with `bedrock:InvokeModel` | Both grant the compute service permission to call the AI model |
| Azure Function | AWS Lambda | Both are serverless — run on demand, cost nothing when idle |
| `azapi` provider (AI Foundry) | `archive` provider (Lambda zip) | azapi was needed because AI Foundry was too new for azurerm — archive is needed to package the Lambda deployment zip |

---

## ⚠️ Prerequisites — Complete These First

Phase 5 looks up the KMS key and gold S3 bucket from Phase 1, and reads Athena results written by Phase 4. All previous phases must be deployed and tested before deploying Phase 5.

1. Phase 1 deployed — KMS key and gold S3 bucket must exist
2. Phase 2 deployed — EC2 simulator running and sending records to Kinesis
3. Phase 3 deployed — Glue job ran successfully, Parquet exists in silver
4. Phase 4 deployed — at least one Athena query ran successfully and results exist in `gold/athena-results/`

Confirm Athena results exist before deploying:

```powershell
aws s3 ls s3://gold-sales-a3julceus6-767828742181/athena-results/ --recursive
```

You should see at least one `.csv` file. If not, go back to Phase 4 Step 7 and run a query first.

---

## ⚠️ Enable Bedrock Model Access Before Deploying

Amazon Bedrock requires you to explicitly enable each model before it can be invoked. This is done once in the AWS Console — Terraform cannot do it for you.

1. Go to AWS Console → Amazon Bedrock → Model access (left menu)
2. Click Manage model access
3. Find **Anthropic Claude 3 Haiku** — if it already shows `Access granted` you are ready to deploy immediately, no action needed.

---

## Folder Setup

From your project root:

```powershell
cd phase5-ai
```

You should have:

```
phase5-ai/
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── summarise_sales.py
```

---

## Step 1 — variables.tf

The same three variables used in every phase — `yourname`, `region`, and `tags`.

The Azure version had a `location` variable with a note about Azure OpenAI regional availability. The AWS equivalent is `region` with a note about Bedrock model availability — not all models are available in all regions. `us-east-1` supports the widest selection including Titan Text Lite.

The Azure version also had `synapse_sql_admin` and `synapse_sql_password` carried over from Phase 4. Phase 5 has none of that — Bedrock authenticates via IAM, Lambda has no SQL credentials, and there is nothing to configure beyond the region.

---

## Step 2 — terraform.tfvars

Supplies `yourname = "a3julceus6"` and `region = "us-east-1"`. Same pattern as every other phase.

---

## Step 3 — main.tf

### Providers

Two providers are used — `aws` and `archive`. The `archive` provider replaces the `azapi` provider from the Azure version. `azapi` was needed because AI Foundry was too new for `azurerm` to support. `archive` is needed to zip `summarise_sales.py` into a Lambda deployment package at apply time. Without it, Terraform cannot package the function code.

### Data source lookups

`data "aws_caller_identity"` retrieves your AWS account ID to construct the S3 bucket name.

`data "aws_kms_alias"` and `data "aws_kms_key"` look up the Phase 1 KMS key. Both are needed — the alias gives the alias ARN for SSM encryption, the key data source gives the actual key ARN for IAM policies.

`data "aws_s3_bucket" "gold"` looks up the gold bucket from Phase 1. Lambda reads Athena results from here and writes summaries back here.

### SSM Parameter

In Azure, Terraform stored the OpenAI API key and endpoint in Key Vault after creating the Cognitive Account. Bedrock has no API key — it authenticates via IAM. SSM stores the model ID (`amazon.titan-text-lite-v1`) so Lambda can retrieve it at runtime without hardcoding it in the function code. If you ever want to switch models, you update the SSM parameter and Lambda picks it up on the next invocation without redeployment.

### IAM Role for Lambda

The trust policy allows `lambda.amazonaws.com` to assume this role — same pattern as the Glue role in Phase 3 but for the Lambda service.

`AWSLambdaBasicExecutionRole` is the AWS managed policy that grants Lambda permission to write logs to CloudWatch. This is the baseline every Lambda function needs — equivalent to the default logging permissions Azure Functions receive automatically.

The custom policy has five least-privilege statements:

- `BedrockInvoke` — `bedrock:InvokeModel` scoped to the specific Titan Text Lite model ARN. Replaces `azurerm_role_assignment` (Cognitive Services OpenAI User).
- `GoldRead` — `s3:GetObject` and `s3:ListBucket` on the gold bucket. Lambda needs to list and read the Athena result CSV files.
- `SummaryWrite` — `s3:PutObject` scoped to `gold/summaries/` only. Lambda can only write to the summaries prefix — not overwrite Athena results or any other gold data.
- `SSMRead` — `ssm:GetParameter` scoped to the `/sales/[yourname]/` path. Lambda retrieves the model ID at runtime.
- `KMSAccess` — `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the Phase 1 key. Needed to decrypt the SSM parameter and gold bucket objects.

### Lambda deployment package

`data "archive_file"` zips `summarise_sales.py` into `summarise_sales.zip` at apply time. `source_code_hash` is set to the base64 SHA256 of the zip — Terraform re-uploads the function whenever the Python file changes. This is the reliable version of what `etag` was supposed to do in Phase 3 before the KMS conflict.

### Lambda function

`runtime = "python3.12"` is the latest stable Python runtime on Lambda.

`handler = "summarise_sales.lambda_handler"` tells Lambda the entry point is the `lambda_handler` function inside `summarise_sales.py`.

`timeout = 300` gives the function 5 minutes. Bedrock inference on longer prompts can take several seconds — 30 seconds (the default) is too short if the Athena result CSV is large.

`memory_size = 256` is sufficient for reading a CSV and making an API call. Lambda pricing is based on memory × duration, so keeping this low reduces cost.

Environment variables pass the SSM path, gold bucket name, and region to the function at runtime — nothing is hardcoded in the Python code.

---

## Step 4 — outputs.tf

Five values exported after deployment:

- `lambda_function_name` — used to invoke the function via CLI
- `lambda_function_arn` — referenced in IAM policies in Phase 6
- `bedrock_model_id` — the model ID stored in SSM, useful for verification
- `lambda_role_arn` — the IAM role ARN, exported for Phase 6 observability
- `summary_output_location` — the S3 path where summaries land

---

## Step 5 — Deploy

```powershell
terraform init
terraform validate
terraform plan
terraform apply
```

Expect 5 resources to add. Deployment takes under 1 minute.

Confirm outputs:

```powershell
terraform output
```

---

## Step 6 — Invoke Lambda and Test

Trigger the Lambda function:

```powershell
aws lambda invoke `
  --function-name lambda-summariser-a3julceus6 `
  --payload '{}' `
  response.json
```

Check the response:

```powershell
Get-Content response.json
```

You should see a `statusCode: 200` and the executive summary text in the `body` field.

If you get `statusCode: 404` with `No Athena result files found` — go back to Phase 4 and run at least one Athena query so a CSV result exists in the gold bucket.

Check that the summary was written to S3:

```powershell
aws s3 ls s3://gold-sales-a3julceus6-767828742181/summaries/
```

You should see a `.txt` file. Read it:

```powershell
aws s3 cp s3://gold-sales-a3julceus6-767828742181/summaries/<filename>.txt -
```

You should see a natural language executive summary of your sales data.

---

## Troubleshooting

**`AccessDeniedException` from Bedrock**
The Titan Text Lite model has not been enabled in your account. Go to AWS Console → Bedrock → Model access and enable it. Wait 1–2 minutes then retry.

**`statusCode: 404` — No Athena result files found**
No CSV files exist in `gold/athena-results/`. Run a query in Phase 4 first.

**Lambda timeout**
The function timed out before Bedrock responded. This is rare with Titan Text Lite but can happen on cold starts. Retry the invocation — subsequent calls are faster.

**Check Lambda logs for any other error:**

```powershell
aws logs tail /aws/lambda/lambda-summariser-a3julceus6 --follow
```

---

## Verification Checklist

- Lambda function exists:
```powershell
aws lambda get-function --function-name lambda-summariser-a3julceus6 `
  --query "Configuration.FunctionName"
```

- SSM parameter exists:
```powershell
aws ssm get-parameter --name /sales/a3julceus6/bedrock-model-id `
  --with-decryption --query "Parameter.Value"
```

- Lambda invocation returns `200`:
```powershell
Get-Content response.json
```

- Summary file exists in gold bucket:
```powershell
aws s3 ls s3://gold-sales-a3julceus6-767828742181/summaries/
```

---

Once all checklist items pass, proceed to **Phase 6 — Observability**. 🏁
