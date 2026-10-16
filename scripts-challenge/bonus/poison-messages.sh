#!/usr/bin/env bash
# ==============================================================================
# BONUS: mensajes venenosos
#
# Un mensaje venenoso es uno que el worker nunca podrá procesar bien, sin importar
# cuántas veces se reintente. El pipeline debe aislarlo (acabar en la DLQ) sin
# bloquear la cola ni afectar a las transacciones válidas.
#
# Uso:
#   ./scripts-challenge/bonus/poison-messages.sh list     lista los casos
#   ./scripts-challenge/bonus/poison-messages.sh send     inyecta los casos y una transacción válida
#   ./scripts-challenge/bonus/poison-messages.sh check    send + espera + auditoría (exit 0 = correcto)
#
# Variables opcionales:
#   WAIT_TIMEOUT (300)  segundos máximos esperando que los venenosos lleguen a la DLQ
#
# Este bonus NO forma parte del puntaje de check-challenge-points.sh ni de verify-pipeline.sh.
# ==============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.."
# shellcheck source=../helper/lib.sh
source scripts-challenge/helper/lib.sh

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# nombre|descripción|cuerpo
CASES=(
  'json-invalido|JSON mal formado|{"transaction_id": "tx-poison-1", "amount": '
  'texto-plano|Texto que no es JSON|esto no es una transaccion'
  'espacios|Cuerpo con solo espacios| '
  'arreglo|JSON válido pero es un arreglo, no un objeto|[1, 2, 3]'
  'escalar|JSON válido pero es un número|42'
  'nulo|JSON válido pero es null|null'
  'sin-id|Objeto sin transaction_id|{"account_id": "acc-9921", "amount": 100, "timestamp": 1700000000}'
  'id-nulo|transaction_id es null|{"transaction_id": null, "account_id": "acc-9921", "amount": 100}'
  'id-vacio|transaction_id es una cadena vacía|{"transaction_id": "", "account_id": "acc-9921", "amount": 100}'
)

send_body() {
  run_aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$1" >/dev/null
}

cmd_list() {
  echo "Casos de mensajes venenosos (${#CASES[@]}):"
  local c name desc
  for c in "${CASES[@]}"; do
    name="${c%%|*}"; desc="${c#*|}"; desc="${desc%%|*}"
    printf '  - %-14s %s\n' "$name" "$desc"
  done
}

# Inyecta los venenosos y una transacción válida (canario) para comprobar que la cola sigue fluyendo.
cmd_send() {
  local c name rest body
  for c in "${CASES[@]}"; do
    name="${c%%|*}"; rest="${c#*|}"; body="${rest#*|}"
    send_body "$body" && echo "  [OK] Enviado venenoso: $name"
  done
  CANARY_ID="tx-canary-$(date +%s)-$RANDOM"
  send_body "{\"transaction_id\": \"$CANARY_ID\", \"account_id\": \"acc-9921\", \"amount\": 100, \"timestamp\": $(date +%s)}"
  echo "  [OK] Enviada transacción válida (canario): $CANARY_ID"
}

cmd_check() {
  local fails=0 expected="${#CASES[@]}" before after start elapsed junk
  ok()   { echo "  ✔ $*"; }
  fail() { echo "  ❌ $*"; fails=$((fails + 1)); }

  echo "=== Bonus: mensajes venenosos ==="
  run_aws sqs list-queues >/dev/null 2>&1 || { echo "LocalStack no responde. Levanta el entorno primero."; exit 1; }

  before=$(dlq_total)
  echo "[1/4] Inyectando $expected mensajes venenosos y 1 válido (DLQ actual: $before)..."
  cmd_send

  echo "[2/4] Esperando que la transacción válida se procese (la cola no debe bloquearse)..."
  if wait_for_txs 90 "$CANARY_ID"; then
    ok "La transacción válida se procesó pese a los venenosos."
  else
    fail "La transacción válida no se procesó: los venenosos bloquean el consumo."
  fi

  echo "[3/4] Esperando que los venenosos lleguen a la DLQ (máx ${WAIT_TIMEOUT}s)..."
  start=$SECONDS
  while :; do
    after=$(dlq_total)
    [ $((after - before)) -ge "$expected" ] && break
    [ $((SECONDS - start)) -ge "$WAIT_TIMEOUT" ] && break
    sleep 5
  done
  elapsed=$((SECONDS - start))
  if [ $((after - before)) -eq "$expected" ]; then
    ok "Los $expected venenosos están en la DLQ (${elapsed}s), sin perder ni duplicar."
  elif [ $((after - before)) -gt "$expected" ]; then
    fail "La DLQ recibió $((after - before)) mensajes (esperados $expected): algún válido se descartó."
  else
    fail "Solo $((after - before)) de $expected venenosos llegaron a la DLQ tras ${WAIT_TIMEOUT}s."
  fi

  echo "[4/4] Auditando el estado final..."
  if wait_for_queue_drained 60; then
    ok "La cola principal quedó vacía."
  else
    fail "La cola principal conserva mensajes: algo se reentrega sin fin."
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' pipeline-worker 2>/dev/null)" = "true" ]; then
    ok "El worker sigue en ejecución."
  else
    fail "El worker se detuvo: un mensaje venenoso lo hizo caer."
  fi
  junk=$(run_aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -E '^payloads/(None|null)?\.json$' || true)
  if [ -z "$junk" ]; then
    ok "S3 sin objetos basura generados por mensajes inválidos."
  else
    echo "  ⚠ S3 contiene objetos de mensajes inválidos ($(echo "$junk" | tr '\n' ' ')): valida el mensaje antes de persistir."
  fi

  echo
  if [ "$fails" -eq 0 ]; then
    echo "🎉 Bonus superado: los mensajes venenosos quedaron aislados."
  else
    echo "❌ Bonus no superado: $fails chequeo(s) fallaron."
    exit 1
  fi
}

case "${1:-}" in
  list)  cmd_list ;;
  send)  cmd_send ;;
  check) cmd_check ;;
  *) echo "Uso: $0 {list|send|check}"; exit 1 ;;
esac
