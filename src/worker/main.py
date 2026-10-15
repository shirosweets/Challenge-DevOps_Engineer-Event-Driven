import json
import logging
import os
import sys
import time
import urllib3
import boto3
from botocore.config import Config

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# Configuración obligatoria para LocalStack
config = Config(
    s3={'addressing_style': 'path'},
    retries={'max_attempts': 0}
)

ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL", "http://localhost:4566")
QUEUE_URL = os.getenv("SQS_QUEUE_URL")
BUCKET_NAME = os.getenv("S3_BUCKET_NAME")
TABLE_NAME = os.getenv("DYNAMODB_TABLE_NAME")

sqs = boto3.client("sqs", endpoint_url=ENDPOINT_URL, config=config)
s3 = boto3.client("s3", endpoint_url=ENDPOINT_URL, config=config)
dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT_URL, config=config)
table = dynamodb.Table(TABLE_NAME)

def process_transaction(payload: dict):
    tx_id = payload.get("transaction_id")
    logger.info(f"Procesando transacción {tx_id}...")

    time.sleep(15)

    # Persistencia en S3
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=f"payloads/{tx_id}.json",
        Body=json.dumps(payload),
        ContentType="application/json"
    )

    # Persistencia en DynamoDB
    table.put_item(
        Item={
            "transaction_id": tx_id,
            "amount": str(payload.get("amount")),
            "status": "COMPLETED",
            "processed_at": int(time.time())
        }
    )
    logger.info(f"Transacción {tx_id} persistida con éxito.")

def run():
    logger.info("Worker iniciado. Escuchando SQS...")
    
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=5
            )

            messages = response.get("Messages", [])
            if not messages:
                continue

            for msg in messages:
                body = json.loads(msg["Body"])
                process_transaction(body)

                sqs.delete_message(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=msg["ReceiptHandle"]
                )
                logger.info(f"Mensaje {msg['MessageId']} eliminado de SQS.")

        except Exception as e:
            logger.error(f"Falla crítica en el ciclo de consumo: {e}")
            sys.exit(1)

if __name__ == "__main__":
    run()
