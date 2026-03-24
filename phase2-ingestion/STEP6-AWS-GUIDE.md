# Phase 2 — Step 6: Upload and Run the Simulation Script (AWS)

## What changed from Azure
| Azure                           | AWS                                       |
|---------------------------------|-------------------------------------------|
| apt install python3-pip         | yum install python3-pip (Amazon Linux)    |
| azure-eventhub / azure-identity | boto3 (AWS SDK — no extra auth needed)    |
| Managed Identity credential     | IAM Instance Profile (automatic in boto3) |
| Key Vault URI lookup            | SSM Parameter Store lookup                |
| Event Hub connection string     | Kinesis stream name only                  |

---

## Step 1 — Get the EC2 public IP from Terraform output
Run in PowerShell from your `phase2-ingestion` folder:
```powershell
terraform output ec2_public_ip
```

---

## Step 2 — SSH into the EC2 instance
Run in PowerShell:
```powershell
ssh -i "C:\terraform\key-pair\capstone.pem" ec2-user@<public-ip>
```
> No password needed — authentication uses the capstone key pair.
> If you get an UNPROTECTED PRIVATE KEY FILE warning, fix permissions by running in PowerShell:
> ```powershell
> $pemFile = "C:\terraform\key-pair\capstone.pem"
> icacls $pemFile /inheritancelevel:r
> icacls $pemFile /remove "BUILTIN\Users"
> icacls $pemFile /remove "Everyone"
> icacls $pemFile /grant:r "$($env:USERNAME):(F)"
> ```

---

## Step 3 — Verify user_data already ran (auto-installed on boot)
The EC2 user_data script automatically:
- Installed Python3 and boto3
- Pulled the Kinesis stream name from SSM
- Wrote simulate_sales.py to /home/ec2-user/

Once SSH'd into the EC2, verify it completed:
```bash
cat /var/log/cloud-init-output.log | tail -20
ls ~/simulate_sales.py
```

---

## Step 4 — Get the Kinesis stream name (if needed manually)
Run from PowerShell on your local machine (not inside SSH):

Option 1 — via SSM Parameter Store:
```powershell
aws ssm get-parameter `
  --name "/sales/<yourname>/kinesis-stream-name" `
  --with-decryption `
  --query "Parameter.Value" `
  --output text
```

Option 2 — directly from Kinesis:
```powershell
aws kinesis list-streams --output text
```

Both will return something like: `sales-events-a3julceus6`

---

## Step 5 — Run the simulation script
Once SSH'd into the EC2:
```bash
python3 ~/simulate_sales.py
```
You should see a new transaction printed every 2 seconds:
```
Sent: TXN-482910 | Laptop | $1249.99 | East
Sent: TXN-193847 | Mouse  | $34.50   | West
```
Leave this running while you validate. Press Ctrl+C to stop.

---

## Verification Checklist
- [ ] Kinesis stream `sales-events-<yourname>` exists in AWS Console → Kinesis
- [ ] EC2 instance `ec2-simulator-<yourname>` is running with IAM role attached
- [ ] SSM Parameter `/sales/<yourname>/kinesis-stream-name` exists in Parameter Store
- [ ] SSH into EC2 works using the capstone key pair
- [ ] Simulation script runs and prints transaction lines without error
- [ ] AWS Console → Kinesis → stream → Monitoring tab shows incoming records

---

## Troubleshooting
| Error                                      | Cause                              | Resolution                                          |
|--------------------------------------------|------------------------------------|-----------------------------------------------------|
| Permission denied (publickey)              | Wrong key or permissions           | Run the icacls fix commands in Step 2               |
| UNPROTECTED PRIVATE KEY FILE               | Too many users have access to .pem | Run the icacls fix commands in Step 2               |
| simulate_sales.py not found                | user_data not finished             | Wait 2 mins, check cloud-init-output.log            |
| An error occurred (AccessDeniedException)  | IAM role not propagated            | Wait 60 seconds and retry                           |
| Could not connect to Kinesis endpoint      | No internet gateway / route table  | Verify IGW and route table in VPC console           |
| ResourceNotFoundException on stream        | Stream name mismatch               | Re-run SSM get-parameter in PowerShell to confirm   |

---

Once the simulation script is running and you can see incoming records in the Kinesis Monitoring tab, proceed to Phase 3 — Orchestration.
