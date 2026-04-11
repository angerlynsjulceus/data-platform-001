import json
import os
import boto3

s3       = boto3.client("s3")
ssm      = boto3.client("ssm")
bedrock  = boto3.client("bedrock-runtime", region_name=os.environ["REGION"])

def lambda_handler(event, context):
    model_id   = ssm.get_parameter(
        Name=os.environ["BEDROCK_MODEL_SSM_PATH"], WithDecryption=True
    )["Parameter"]["Value"]

    gold_bucket = os.environ["GOLD_BUCKET"]

    # Read the most recent Athena result file from gold/athena-results/
    objects = s3.list_objects_v2(Bucket=gold_bucket, Prefix="athena-results/")
    csv_files = [
        o["Key"] for o in objects.get("Contents", [])
        if o["Key"].endswith(".csv")
    ]

    if not csv_files:
        return {"statusCode": 404, "body": "No Athena result files found"}

    latest = sorted(csv_files)[-1]
    csv_content = s3.get_object(Bucket=gold_bucket, Key=latest)["Body"].read().decode("utf-8")

    prompt = f"""You are a sales intelligence analyst. Based on the following sales query results,
write a concise executive summary highlighting key trends, top performers, and any notable insights.

Data:
{csv_content}

Executive Summary:"""

    response = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 512,
            "messages": [{"role": "user", "content": prompt}]
        }),
        contentType="application/json",
        accept="application/json"
    )

    summary = json.loads(response["body"].read())["content"][0]["text"]

    # Write summary back to gold bucket
    s3.put_object(
        Bucket=gold_bucket,
        Key=f"summaries/summary_{context.aws_request_id}.txt",
        Body=summary.encode("utf-8")
    )

    return {"statusCode": 200, "body": summary}
