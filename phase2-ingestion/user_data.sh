#!/bin/bash
yum update -y
yum install python3-pip -y
pip3 install boto3

# Pull stream name from SSM Parameter Store
STREAM_NAME=$(aws ssm get-parameter \
  --name "/sales/${yourname}/kinesis-stream-name" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region ${region})

# Write the simulation script
cat <<'SCRIPT' > /home/ec2-user/simulate_sales.py
import json
import random
import time
import boto3
from datetime import datetime

STREAM_NAME = "STREAM_NAME_PLACEHOLDER"
REGION      = "REGION_PLACEHOLDER"

PRODUCTS = ["Laptop", "Monitor", "Keyboard", "Mouse", "Headset", "Webcam", "Docking Station"]
REGIONS  = ["East", "West", "North", "South", "Central"]

def generate_sale():
    return {
        "transaction_id": f"TXN-{random.randint(100000, 999999)}",
        "timestamp":      datetime.utcnow().isoformat(),
        "product":        random.choice(PRODUCTS),
        "quantity":       random.randint(1, 5),
        "unit_price":     round(random.uniform(20, 1500), 2),
        "region":         random.choice(REGIONS),
        "store_id":       f"STORE-{random.randint(1, 20):03d}"
    }

client = boto3.client("kinesis", region_name=REGION)

print("Starting simulation - sending events every 2 seconds. Ctrl+C to stop.")

try:
    while True:
        sale = generate_sale()
        client.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(sale),
            PartitionKey=sale["store_id"]
        )
        print(f"Sent: {sale['transaction_id']} | {sale['product']} | {sale['unit_price']} | {sale['region']}")
        time.sleep(2)
except KeyboardInterrupt:
    print("Simulation stopped.")
SCRIPT

# Replace placeholders with actual values
sed -i "s/STREAM_NAME_PLACEHOLDER/$STREAM_NAME/g" /home/ec2-user/simulate_sales.py
sed -i "s/REGION_PLACEHOLDER/${region}/g" /home/ec2-user/simulate_sales.py

chown ec2-user:ec2-user /home/ec2-user/simulate_sales.py
