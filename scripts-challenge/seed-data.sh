#!/usr/bin/env bash
set -euo pipefail

TOTAL=${1:-5}
ENDPOINT="http://localhost:4566"
QUEUE_URL="$ENDPOINT/000000000000/transactions-queue"

# Usa `aws` (v2) y, si no está instalado, `awslocal`
run_aws() {
  if command -v aws >/dev/null 2>&1; then aws --endpoint-url="$ENDPOINT" "$@"; else awslocal "$@"; fi
}

echo "Inyectando $TOTAL transacciones a SQS ($QUEUE_URL)..."

for i in $(seq 1 "$TOTAL"); do
  TX_ID="tx-$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)"
  AMOUNT=$((RANDOM % 5000 + 10))

  PAYLOAD=$(cat <<EOF
{
  "transaction_id": "$TX_ID",
  "account_id": "acc-9921",
  "amount": $AMOUNT,
  "timestamp": $(date +%s)
}
EOF
)

  run_aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$PAYLOAD" \
    --region us-east-1 > /dev/null

  echo " [OK] Encolado: $TX_ID ($AMOUNT USD)"
done

echo "Inyección completada."
