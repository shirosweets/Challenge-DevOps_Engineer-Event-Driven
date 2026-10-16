#!/usr/bin/env bash
# Verificación rápida de la solución (versión corta de scripts-challenge/verify-pipeline.sh).
# Inyecta TEST_BATCH_SIZE (10 por defecto, como verify-pipeline.sh) transacciones y comprueba que TODAS se procesen sin caer en la DLQ.
# Mide la diferencia respecto al estado previo, así que sirve aunque ya haya datos.
# Para partir de cero: ./scripts-challenge/reset-env.sh --full
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts-challenge/helper/lib.sh
source scripts-challenge/helper/lib.sh

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"

TOTAL="${TEST_BATCH_SIZE:-10}"
TIMEOUT="${WAIT_TIMEOUT:-180}"

ddb_count() {
  run_aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --query Count --output text
}

echo "[1/4] Verificando Terraform State..."
# Si el candidato modularizó con moved {}, el plan no debe tener cambios
terraform -chdir=terraform plan -detailed-exitcode -lock=false -input=false >/dev/null || {
    echo "FALLO: El plan de Terraform tiene cambios pendientes o intentó recrear recursos."
    exit 1
}

echo "[2/4] Verificando políticas de IAM desplegadas..."
if WILDCARDS=$(iam_wildcard_findings); then
    [ -z "$WILDCARDS" ] || { echo "$WILDCARDS"; echo "FALLO: Se encontraron wildcards en las políticas IAM."; exit 1; }
else
    echo "FALLO: No hay políticas IAM desplegadas para validar."
    exit 1
fi

echo "[3/4] Inyectando $TOTAL mensajes en SQS..."
BEFORE=$(ddb_count)
./scripts-challenge/seed-data.sh "$TOTAL" >/dev/null

echo "[4/4] Esperando procesamiento del worker (máx. ${TIMEOUT}s)..."
START=$SECONDS
while :; do
    PROCESSED=$(( $(ddb_count) - BEFORE ))
    [ "$PROCESSED" -ge "$TOTAL" ] && break
    [ $((SECONDS - START)) -ge "$TIMEOUT" ] && break
    sleep 3
done

DLQ_MESSAGES=$(dlq_total)
echo "Resultados: Procesados en DynamoDB: $PROCESSED/$TOTAL | Mensajes en DLQ: $DLQ_MESSAGES"

if [ "$PROCESSED" -eq "$TOTAL" ] && [ "$DLQ_MESSAGES" -eq 0 ]; then
    echo "SUCCESS: Pipeline procesado de forma limpia y consistente."
else
    echo "FALLO: Hubo pérdida de datos, duplicaciones o mensajes caídos en la DLQ."
    exit 1
fi
