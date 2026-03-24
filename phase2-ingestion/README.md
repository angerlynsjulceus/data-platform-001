# Phase 2: Ingestion — Kinesis Data Stream & Simulation EC2

**Estimated Time:** 2–3 hours  
**What you will deploy:** A Kinesis Data Stream to receive live sales events and an EC2 instance running a Python script that simulates a point-of-sale system sending those events.

---

## What Gets Built in This Phase

```
AWS Account
├── Kinesis Data Stream
│   └── sales-events-[yourname]
├── SSM Parameter Store
│   └── /sales/[yourname]/kinesis-stream-name
├── EC2 Instance — ec2-simulator-[yourname]
│   ├── IAM Role + Instance Profile (replaces Managed Identity)
│   └── simulate_sales.py  ← sends JSON events to Kinesis
└── VPC + Subnet + IGW + Route Table + Security Group
```

---

## Azure → AWS Service Mapping

| Azure | AWS |
|---|---|
| Event Hub Namespace + Event Hub | Kinesis Data Stream |
| Key Vault Secret | SSM Parameter Store (SecureString) |
| Linux VM (Standard_B1s) | EC2 `t3.micro` + Amazon Linux 2023 |
| System-assigned Managed Identity | IAM Role + Instance Profile |
| RBAC role assignments | IAM role policies |
| Virtual Network + NSG | VPC + Subnet + IGW + Route Table + Security Group |
| `apt` + `azure-eventhub` | `yum` + `boto3` |

---

## Folder Setup

From your project root:
```powershell
cd phase2-ingestion
```
Files already created:
```
phase2-ingestion/
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── user_data.sh
```

---

## Why This Order?

The steps are in this order for a reason — each one builds on the previous:

1. `variables.tf` first — defines all inputs before anything references them
2. `terraform.tfvars` second — provides the actual values for those inputs
3. `main.tf` third — the infrastructure itself, which references the variables
4. `outputs.tf` fourth — exposes values from the resources created in `main.tf`
5. Deploy fifth — only after all files are in place
6. Run the script last — the EC2 must exist before you can SSH into it

---

## Step 1 — variables.tf

This file defines the inputs for Phase 2. It keeps the same `yourname`, `region`, and `tags` pattern as Phase 1 for consistency across all phases. Unlike Phase 1, there is no `db_password` or `allowed_cidr` here because Phase 2 does not create a database — it creates an EC2 instance that uses an SSH key pair instead of a password. Keeping variables minimal to what each phase actually needs avoids confusion when deploying phases independently.

See `variables.tf` for the full variable definitions.

---

## Step 2 — terraform.tfvars

This file sets your `yourname` and `region` values. These must match what you used in Phase 1 — the KMS alias lookup in `main.tf` is built from `yourname`, so if they don't match, Phase 2 will fail to find the Phase 1 KMS key.

> ⚠️ `terraform.tfvars` is excluded from git via `.gitignore`. Never commit it — use `terraform.tfvars.example` as a reference instead.  
> No password needed — AWS uses the `capstone` SSH key pair for EC2 access instead of a password.

See `terraform.tfvars.example` for the expected format.

---

## Step 3 — main.tf

This is the largest file in Phase 2 and is broken into seven sections. The order matters — resources that depend on others are declared after them:

**Provider & Identity**  
Configures the AWS provider and pulls the current account ID. It also looks up the KMS key created in Phase 1 using the alias name. This is why Phase 1 must be deployed first — if the alias doesn't exist, Terraform will fail here before creating anything.

**Kinesis Data Stream**  
Creates the stream that receives live sales events from the simulator. One shard gives 1MB/sec inbound throughput — enough for this simulation. Records are retained for 24 hours and encrypted with the Phase 1 KMS key. This replaces Azure Event Hub — no separate namespace is needed in AWS.

**SSM Parameter Store**  
Stores the Kinesis stream name as a SecureString so the EC2 can retrieve it at boot without hardcoding it in the script. This replaces Azure Key Vault secrets. The EC2 IAM role is granted permission to read this parameter — no connection strings or credentials are ever stored on the instance.

**VPC and Networking**  
Creates a dedicated VPC, subnet, internet gateway, and route table for the EC2 instance. Unlike Azure, AWS does not automatically provide internet access to new VPCs — the internet gateway and route table must be explicitly created and associated. Without these, the EC2 cannot reach Kinesis or be SSH'd into.

**Security Group**  
Creates a firewall rule allowing SSH on port 22. This replaces Azure NSG. In production you would restrict the source to your own IP — for this dev environment it is open to allow easy access.

**IAM Role and Instance Profile**  
Creates an IAM role that the EC2 assumes at boot. This replaces Azure Managed Identity. The role has three permissions: read SSM parameters, send records to Kinesis, and use the KMS key for decryption. The instance profile is the wrapper that attaches the role to the EC2 — both are required in AWS.

**EC2 Key Pair**  
Creates an SSH key pair for accessing the EC2 instance. You have two options — either use an existing key pair you already have in AWS, or let Terraform generate a new one using the `tls` provider. If you choose to create a new one, Terraform will upload the public key to AWS and save the private key as a `.pem` file locally. If you already have a key pair, you can reference it by name instead. Either way, the key pair name is what gets attached to the EC2 instance for SSH access. Never share or commit your private key file.

**EC2 Instance**  
Creates a `t3.micro` running Amazon Linux 2023 — the AWS equivalent of Ubuntu for this use case. The root EBS volume is encrypted with the Phase 1 KMS key. Detailed CloudWatch monitoring is enabled. On first boot, `user_data.sh` runs automatically to install Python, boto3, pull the stream name from SSM, and write `simulate_sales.py` to the home directory — no manual setup needed after SSH.

See `main.tf` for the full resource definitions.

---

## Step 4 — outputs.tf

Outputs expose the key values you need after deployment. The Kinesis stream name and ARN are exposed for use by later phases. The EC2 public IP and IAM role ARN replace the Azure VM public IP and principal ID outputs. A pre-built `ssh_command` output is included so you can copy and paste the exact SSH command directly from `terraform output` without constructing it manually.

See `outputs.tf` for the full output definitions.

---

## Step 5 — Deploy

> ⚠️ Phase 1 must be deployed and confirmed working before running Phase 2. Phase 2 looks up the KMS key from Phase 1 at plan time — if Phase 1 is not deployed, `terraform plan` will fail immediately.

```powershell
terraform init
terraform validate
terraform plan
terraform apply
```

You should see approximately 16 resources to add. Deployment takes 3–5 minutes due to EC2 creation. The EC2 `user_data.sh` script runs in the background after the instance boots — wait 2–3 minutes after `terraform apply` completes before SSH-ing in.

---

## Step 6 — Run the Simulation Script

**1. Get the EC2 public IP from Terraform output:**
```powershell
terraform output ec2_public_ip
```

**2. Fix key pair permissions on Windows (run once — SSH will refuse the key if skipped):**
```powershell
$pemFile = "C:\terraform\key-pair\capstone.pem"
icacls $pemFile /inheritancelevel:r
icacls $pemFile /remove "BUILTIN\Users"
icacls $pemFile /remove "Everyone"
icacls $pemFile /grant:r "$($env:USERNAME):(F)"
```

**3. SSH into the EC2:**
```powershell
ssh -i "C:\terraform\key-pair\capstone.pem" ec2-user@<public-ip>
```

**4. Verify the script was written by user_data (once inside SSH):**
```bash
cat /var/log/cloud-init-output.log | tail -20
ls ~/simulate_sales.py
```

**5. Run the simulation:**
```bash
python3 ~/simulate_sales.py
```

Expected output every 2 seconds:
```
Sent: TXN-482910 | Laptop | $1249.99 | East
Sent: TXN-193847 | Mouse  | $34.50   | West
```

Leave this running while you validate. Press Ctrl+C to stop.

---

## Verification Checklist

- [ ] Kinesis stream `sales-events-[yourname]` exists in AWS Console → Kinesis
```powershell
aws kinesis list-streams --output table
```

- [ ] EC2 instance `ec2-simulator-[yourname]` is running with IAM role attached
```powershell
aws ec2 describe-instances --filters "Name=tag:Name,Values=ec2-simulator-[yourname]" --query "Reservations[0].Instances[0].State.Name"
```

- [ ] SSM Parameter `/sales/[yourname]/kinesis-stream-name` exists in Parameter Store
```powershell
aws ssm get-parameter --name "/sales/[yourname]/kinesis-stream-name" --with-decryption --query "Parameter.Value" --output text
```

- [ ] SSH into EC2 works using the `capstone` key pair
- [ ] Simulation script runs and prints transaction lines without error
- [ ] Kinesis stream → Monitoring tab shows incoming records
```powershell
aws kinesis describe-stream-summary --stream-name "sales-events-[yourname]" --query "StreamDescriptionSummary.OpenShardCount"
```

---

## Troubleshooting

| Error | Cause | Resolution |
|---|---|---|
| `empty result` on KMS alias | Phase 1 not deployed yet | Deploy phase1 first |
| `Permission denied (publickey)` | Wrong key or permissions | Run `icacls` fix commands in Step 6 |
| `UNPROTECTED PRIVATE KEY FILE` | Too many users have access to `.pem` | Run `icacls` fix commands in Step 6 |
| `simulate_sales.py` not found | `user_data` not finished | Wait 2 mins, check `cloud-init-output.log` |
| `KMSAccessDeniedException` | IAM policy using alias ARN not key ARN | Run `terraform apply` to update IAM policy |
| `AccessDeniedException` on Kinesis | IAM role not propagated | Wait 60 seconds and retry |
| `StreamName` length 0 | SSM lookup failed during boot | Manually set stream name in script with `sed` |

---

## Destroy

Always destroy Phase 2 before Phase 1 — Phase 2 depends on the KMS key from Phase 1. Destroying in the wrong order will leave orphaned encrypted resources.

```powershell
# In phase2-ingestion
terraform destroy

# Then in phase1-foundation
cd ..\phase1-foundation
terraform destroy
```

---

Once the simulation script is running and you can see incoming records in the Kinesis Monitoring tab, proceed to **Phase 3 — Orchestration**.
