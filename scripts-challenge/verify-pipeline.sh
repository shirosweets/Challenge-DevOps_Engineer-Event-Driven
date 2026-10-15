#!/usr/bin/env bash
# ==============================================================================
# CHALLENGE AUDIT SCRIPT: verify-pipeline.sh
# Verifica estado de Terraform, seguridad, configuración de SQS/S3 y el flujo
# funcional extremo a extremo. Sale con código 1 si falla cualquier chequeo.
#
# Uso: ./scripts-challenge/verify-pipeline.sh [--with-shutdown]
#   --with-shutdown  además prueba el apagado ordenado (detiene y relanza el worker)
#
# Variables opcionales:
#   TEST_BATCH_SIZE (10)  transacciones a inyectar
#   WAIT_TIMEOUT (150)    segundos máximos esperando el procesamiento
#   MIN_VISIBILITY (20)   VisibilityTimeout mínimo aceptable (el worker tarda ~15 s)
# ==============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=helper/lib.sh
source scripts-challenge/helper/lib.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"

TEST_BATCH_SIZE="${TEST_BATCH_SIZE:-10}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-150}"
MIN_VISIBILITY="${MIN_VISIBILITY:-20}"
WITH_SHUTDOWN=0
[ "${1:-}" = "--with-shutdown" ] && WITH_SHUTDOWN=1

FAILURES=0
ok()   { echo -e "${GREEN}  ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
fail() { echo -e "${RED}  ❌ $1${NC}"; FAILURES=$((FAILURES + 1)); }

TOTAL_STEPS=6
echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}   🔍 AUDITORÍA DE PIPELINE: EL GUARDIÁN DE LA INFRAESTRUCTURA   ${NC}"
echo -e "${BLUE}=================================================================${NC}\n"

# ------------------------------------------------------------------------------
echo -e "${CYAN}[1/$TOTAL_STEPS] Verificando salud del entorno local...${NC}"
if ! curl -sf "$ENDPOINT_URL/_localstack/health" >/dev/null 2>&1; then
  echo -e "${RED}❌ ERROR: LocalStack no responde en $ENDPOINT_URL.${NC}"
  echo "Levántalo con: docker compose up -d localstack   (o ./scripts-challenge/reset-env.sh --up)"
  exit 1
fi
ok "LocalStack respondiendo correctamente."

if INTEGRITY=$(verify_script_integrity); then
  ok "Scripts de auditoría íntegros (coinciden con scripts-challenge/CHECKSUMS)."
else
  echo "$INTEGRITY"
  fail "Los scripts de scripts-challenge/ fueron modificados o falta CHECKSUMS (RULES.md, punto 4). Restáuralos con: git checkout -- scripts-challenge/"
fi
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[2/$TOTAL_STEPS] Auditando infraestructura como código (Terraform)...${NC}"
if [ ! -d terraform ]; then
  echo -e "${RED}❌ ERROR: no se encontró 'terraform/'.${NC}"
  exit 1
fi

# -lock=false: es una lectura; evita chocar con un plan en segundo plano del editor
TF_PLAN_OUT=$(terraform -chdir=terraform plan -detailed-exitcode -lock=false -input=false -no-color 2>&1)
TF_EXIT_CODE=$?
if [ "$TF_EXIT_CODE" -eq 0 ]; then
  ok "Terraform State intacto: 0 cambios pendientes."
elif [ "$TF_EXIT_CODE" -eq 2 ]; then
  fail "Terraform detectó cambios pendientes: el código y la infraestructura no coinciden."
  echo "$TF_PLAN_OUT" | grep -E "^Plan:|will be (destroyed|replaced)|must be replaced" | sed 's/^/      /' || true
  if echo "$TF_PLAN_OUT" | grep -qE "^Plan: .* [1-9][0-9]* to destroy"; then
    fail "El plan DESTRUYE recursos existentes: falta preservar el estado (moved {})."
  fi
else
  fail "Falló 'terraform plan' (¿init pendiente o sintaxis inválida?)."
  echo "$TF_PLAN_OUT" | tail -n 8 | sed 's/^/      /'
fi

# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[3/$TOTAL_STEPS] Verificando seguridad y configuración desplegada...${NC}"

# 3.1 IAM: se evalúan las políticas realmente desplegadas en LocalStack
WILDCARDS=$(iam_wildcard_findings); IAM_RC=$?
if [ "$IAM_RC" -eq 3 ]; then
  fail "No se encontró ninguna política IAM desplegada: no se puede validar el menor privilegio."
elif [ -n "$WILDCARDS" ]; then
  fail "Políticas IAM con wildcards (Action '*'/'servicio:*' o Resource '*'):"
  echo "$WILDCARDS" | sed 's/^/      /'
else
  ok "Menor privilegio: ninguna política IAM desplegada usa wildcards."
fi

# 3.2 Contenedor sin privilegios
WORKER_USER=$(docker inspect --format '{{.Config.User}}' pipeline-worker 2>/dev/null) || WORKER_USER="not_found"
case "$WORKER_USER" in
  not_found) fail "Contenedor 'pipeline-worker' no encontrado: levántalo con 'docker compose up -d --build worker'." ;;
  ""|root|root:*|0|0:*) fail "El worker corre como root (Config.User='$WORKER_USER')." ;;
  *) ok "Hardening de contenedor: el worker corre con usuario no privilegiado ($WORKER_USER)." ;;
esac

# 3.3 SQS: VisibilityTimeout y redrive hacia la DLQ real
QUEUE_ATTRS=$(run_aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All --query Attributes --output json 2>/dev/null || echo '{}')
DLQ_ARN=$(run_aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text 2>/dev/null || echo "")
VISIBILITY=$(echo "$QUEUE_ATTRS" | jq -r '.VisibilityTimeout // "0"')
REDRIVE_TARGET=$(echo "$QUEUE_ATTRS" | jq -r '.RedrivePolicy // "{}" | fromjson | .deadLetterTargetArn // ""')

if [ "$VISIBILITY" -ge "$MIN_VISIBILITY" ] 2>/dev/null; then
  ok "VisibilityTimeout = ${VISIBILITY}s (>= ${MIN_VISIBILITY}s): cubre el tiempo de procesamiento."
else
  fail "VisibilityTimeout = ${VISIBILITY}s es menor que ${MIN_VISIBILITY}s: SQS reentregará mensajes en proceso."
fi

if [ -n "$DLQ_ARN" ] && [ "$REDRIVE_TARGET" = "$DLQ_ARN" ]; then
  ok "Redrive policy apunta a la DLQ real ($DLQ_ARN)."
else
  fail "Redrive policy ausente o apuntando a otra cola (esperada: $DLQ_ARN, actual: ${REDRIVE_TARGET:-ninguna})."
fi

# 3.4 S3: bloqueo de acceso público y cifrado
PAB=$(run_aws s3api get-public-access-block --bucket "$BUCKET_NAME" --query PublicAccessBlockConfiguration --output json 2>/dev/null || echo '{}')
if [ "$(echo "$PAB" | jq '[.BlockPublicAcls, .BlockPublicPolicy, .IgnorePublicAcls, .RestrictPublicBuckets] | all')" = "true" ]; then
  ok "S3: acceso público bloqueado en sus cuatro dimensiones."
else
  fail "S3: falta el bloqueo de acceso público completo (public access block)."
fi

if run_aws s3api get-bucket-encryption --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
  ok "S3: cifrado del lado del servidor configurado."
else
  fail "S3: el bucket no tiene cifrado configurado."
fi

# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[4/$TOTAL_STEPS] Inyectando $TEST_BATCH_SIZE transacciones únicas y esperando su procesamiento...${NC}"
RUN_ID="$(date +%s)-$RANDOM"
TX_IDS=""
for i in $(seq 1 "$TEST_BATCH_SIZE"); do
  TX_ID="audit-$RUN_ID-$i"
  PAYLOAD="{\"transaction_id\":\"$TX_ID\",\"account_id\":\"acc-audit\",\"amount\":$((RANDOM % 2000 + 50)),\"timestamp\":$(date +%s)}"
  run_aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$PAYLOAD" >/dev/null 2>&1 \
    && TX_IDS="$TX_IDS $TX_ID"
done
TX_IDS="${TX_IDS# }"
INJECTED=$(echo "$TX_IDS" | wc -w)
echo "  → $INJECTED/$TEST_BATCH_SIZE inyectadas (corrida $RUN_ID). Máximo de espera: ${WAIT_TIMEOUT}s."
[ "$INJECTED" -eq "$TEST_BATCH_SIZE" ] || fail "No se pudieron inyectar todas las transacciones (¿existe la cola? ¿se aplicó Terraform?)."

START=$SECONDS
# shellcheck disable=SC2086
if wait_for_txs "$WAIT_TIMEOUT" $TX_IDS; then
  ok "Las $INJECTED transacciones quedaron en DynamoDB y S3 en $((SECONDS - START))s."
else
  PENDING_COUNT=$(echo "$PENDING_TXS" | wc -w)
  fail "$PENDING_COUNT transacción(es) de $INJECTED no se asentaron en ${WAIT_TIMEOUT}s: $PENDING_TXS"
fi

# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[5/$TOTAL_STEPS] Auditando colas y ausencia de duplicados...${NC}"

if wait_for_queue_drained 90; then
  ok "Cola principal vacía: el worker borra cada mensaje tras procesarlo."
else
  fail "La cola conserva mensajes ($VISIBLE visibles | $IN_FLIGHT en vuelo): no se borran o se reentregan."
fi

DLQ_MESSAGES=$(dlq_total)
if [ "$DLQ_MESSAGES" -eq 0 ]; then
  ok "DLQ limpia: ningún mensaje cayó a la Dead-Letter Queue."
else
  fail "Hay $DLQ_MESSAGES mensaje(s) en la DLQ."
fi

# Duplicados: mejor esfuerzo, se basa en el log "Procesando transacción <id>" del worker
if docker logs pipeline-worker >/dev/null 2>&1; then
  WORKER_LOGS=$(docker logs pipeline-worker 2>&1)
  DUP_FOUND=0
  for id in $TX_IDS; do
    TIMES=$(echo "$WORKER_LOGS" | grep -c "Procesando transacción $id\b")
    if [ "$TIMES" -gt 1 ]; then
      fail "La transacción $id se procesó $TIMES veces (reentrega/duplicado)."
      DUP_FOUND=1
    fi
  done
  [ "$DUP_FOUND" -eq 0 ] && ok "Sin duplicados: cada transacción se procesó una sola vez."
else
  warn "No se pudieron leer los logs del worker: chequeo de duplicados omitido."
fi

# ------------------------------------------------------------------------------
echo -e "\n${CYAN}[6/$TOTAL_STEPS] Apagado ordenado (SIGTERM)...${NC}"
if [ "$WITH_SHUTDOWN" -eq 1 ]; then
  SD_TX="audit-$RUN_ID-shutdown"
  run_aws sqs send-message --queue-url "$QUEUE_URL" \
    --message-body "{\"transaction_id\":\"$SD_TX\",\"account_id\":\"acc-audit\",\"amount\":100,\"timestamp\":$(date +%s)}" >/dev/null
  sleep 5   # que el worker ya la haya tomado y esté procesándola
  docker stop pipeline-worker >/dev/null 2>&1
  SD_EXIT=$(docker inspect --format '{{.State.ExitCode}}' pipeline-worker 2>/dev/null || echo "?")
  if [ "$SD_EXIT" = "137" ]; then
    fail "El worker murió por SIGKILL (exit 137): no atiende SIGTERM o el grace period es menor que el procesamiento."
  elif [ "$SD_EXIT" != "0" ]; then
    fail "El worker terminó con código $SD_EXIT al recibir SIGTERM (se esperaba 0)."
  elif tx_settled "$SD_TX"; then
    ok "Apagado ordenado: la transacción en vuelo se completó y el worker salió con código 0."
  else
    fail "El worker salió con 0 pero la transacción en vuelo no quedó persistida."
  fi
  docker compose up -d worker >/dev/null 2>&1 || warn "No se pudo relanzar el worker automáticamente."
else
  warn "Omitido. Ejecútalo con: $0 --with-shutdown"
fi

# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=================================================================${NC}"
echo -e "${BLUE}                     VEREDICTO DE AUDITORÍA                      ${NC}"
echo -e "${BLUE}=================================================================${NC}"
if [ "$FAILURES" -eq 0 ]; then
  echo -e "\n${GREEN}🎉 ¡FELICITACIONES! El pipeline es funcional, seguro y consistente.${NC}"
  exit 0
fi
echo -e "\n${RED}⚠️ REVISIÓN PENDIENTE: $FAILURES chequeo(s) fallaron.${NC}"
echo "Revisa los logs del worker con: docker logs --tail 50 pipeline-worker"
exit 1
