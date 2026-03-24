import json
import random
import time
import boto3
from datetime import datetime

# Kinesis config — pulled from SSM at boot via user_data, or set manually below
# To get the stream name: aws ssm get-parameter --name "/sales/<yourname>/kinesis-stream-name" --with-decryption --query "Parameter.Value" --output text
STREAM_NAME = "sales-events-<yourname>"
REGION      = "us-east-1"

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

# Authenticate using IAM Instance Profile — no credentials in this script
# boto3 automatically uses the EC2 instance's IAM role
client = boto3.client("kinesis", region_name=REGION)

print("Starting simulation — sending events every 2 seconds. Ctrl+C to stop.")

try:
    while True:
        sale = generate_sale()
        client.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(sale),
            PartitionKey=sale["store_id"]  # Routes records to Kinesis shards
        )
        print(f"Sent: {sale['transaction_id']} | {sale['product']} | ${sale['unit_price']} | {sale['region']}")
        time.sleep(2)
except KeyboardInterrupt:
    print("Simulation stopped.")
