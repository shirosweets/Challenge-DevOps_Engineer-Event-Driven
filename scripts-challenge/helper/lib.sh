#!/usr/bin/env bash
# Funciones compartidas por los scripts de auditoría. Se usa con `source`, no se ejecuta.

ENDPOINT_URL="${ENDPOINT_URL:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"
QUEUE_URL="${QUEUE_URL:-$ENDPOINT_URL/000000000000/transactions-queue}"
DLQ_URL="${DLQ_URL:-$ENDPOINT_URL/000000000000/transactions-dlq}"
BUCKET_NAME="${BUCKET_NAME:-corporate-transactions-raw-payloads}"
TABLE_NAME="${TABLE_NAME:-transactions}"

# Usa `aws` (v2) y, si no está instalado, `awslocal`
run_aws() {
  if command -v aws >/dev/null 2>&1; then
    aws --endpoint-url="$ENDPOINT_URL" --region="$AWS_REGION" "$@"
  else
    awslocal --region "$AWS_REGION" "$@"
  fi
}

# Los scripts brindados no deben modificarse (RULES.md, punto 4): se comparan contra scripts-challenge/CHECKSUMS.
# Devuelve 0 si coinciden; imprime los archivos alterados en caso contrario.
verify_script_integrity() {
  [ -f scripts-challenge/CHECKSUMS ] || { echo "No existe scripts-challenge/CHECKSUMS"; return 2; }
  local out rc
  out=$(cd scripts-challenge && sha256sum --quiet -c CHECKSUMS 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || echo "$out" | grep -E 'FAILED|No such file' | sed 's/^/    /'
  return "$rc"
}

# Emite "<rol>/<política><TAB><documento JSON>" por cada política de cada rol:
# inline y gestionadas por el cliente. Evalúa lo realmente desplegado, no el código fuente,
# así que funciona igual si el candidato usa módulos, aws_iam_policy o policy documents.
iam_policy_documents() {
  local role name arn ver
  for role in $(run_aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null); do
    for name in $(run_aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
      printf '%s/%s\t%s\n' "$role" "$name" \
        "$(run_aws iam get-role-policy --role-name "$role" --policy-name "$name" --query PolicyDocument --output json | jq -c .)"
    done
    for arn in $(run_aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      case "$arn" in
        arn:aws:iam::aws:policy/*Admin*|arn:aws:iam::aws:policy/*FullAccess*|arn:aws:iam::aws:policy/*PowerUser*)
          # Las políticas administradas de AWS permisivas se tratan como wildcard total
          printf '%s/%s\t%s\n' "$role" "$arn" '{"Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' ;;
        arn:aws:iam::aws:policy/*) ;;
        *)
          ver=$(run_aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
          printf '%s/%s\t%s\n' "$role" "$arn" \
            "$(run_aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query PolicyVersion.Document --output json | jq -c .)" ;;
      esac
    done
  done
}

# Lista las sentencias Allow con Action "*" / "servicio:*" o Resource "*".
# Código de retorno 3 si no se encontró ninguna política: no se puede afirmar que sea segura.
iam_wildcard_findings() {
  local label doc found=0
  while IFS=$'\t' read -r label doc; do
    [ -z "$label" ] && continue
    found=1
    echo "$doc" | jq -r --arg l "$label" '
      [.Statement] | flatten | .[]
      | select(.Effect == "Allow")
      | select(([.Action] | flatten | map(select(. == "*" or endswith(":*"))) | length > 0)
            or ([.Resource] | flatten | map(select(. == "*")) | length > 0))
      | "\($l): Action=\(.Action | tostring) Resource=\(.Resource | tostring)"'
  done < <(iam_policy_documents)
  [ "$found" -eq 1 ] || return 3
}

# Una transacción está asentada si existe en DynamoDB y su payload en S3.
tx_settled() {
  local id="$1"
  run_aws dynamodb get-item --table-name "$TABLE_NAME" \
    --key "{\"transaction_id\":{\"S\":\"$id\"}}" \
    --query 'Item.transaction_id.S' --output text 2>/dev/null | grep -qx "$id" \
    && run_aws s3api head-object --bucket "$BUCKET_NAME" --key "payloads/$id.json" >/dev/null 2>&1
}

# Espera activa hasta que todas las transacciones estén asentadas o venza el timeout.
# Uso: wait_for_txs <timeout_s> <id>...   Deja los pendientes en $PENDING_TXS.
wait_for_txs() {
  local timeout="$1" start="$SECONDS" id still
  shift
  PENDING_TXS="$*"
  while :; do
    still=""
    for id in $PENDING_TXS; do
      tx_settled "$id" || still="$still $id"
    done
    PENDING_TXS="${still# }"
    [ -z "$PENDING_TXS" ] && return 0
    [ $((SECONDS - start)) -ge "$timeout" ] && return 1
    sleep 2
  done
}

# Espera a que la cola principal quede sin mensajes visibles ni en vuelo.
# Si el worker no borra los mensajes, vuelven a aparecer tras el VisibilityTimeout (reentrega).
wait_for_queue_drained() {
  local timeout="$1" start="$SECONDS" attrs
  while :; do
    attrs=$(run_aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
      --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
      --query 'Attributes' --output json 2>/dev/null || echo '{}')
    VISIBLE=$(echo "$attrs" | jq -r '.ApproximateNumberOfMessages // "0"')
    IN_FLIGHT=$(echo "$attrs" | jq -r '.ApproximateNumberOfMessagesNotVisible // "0"')
    [ "$VISIBLE" -eq 0 ] && [ "$IN_FLIGHT" -eq 0 ] && return 0
    [ $((SECONDS - start)) -ge "$timeout" ] && return 1
    sleep 2
  done
}

# Mensajes (visibles + en vuelo) en la DLQ.
dlq_total() {
  run_aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes' --output json 2>/dev/null \
    | jq -r '(.ApproximateNumberOfMessages // "0" | tonumber) + (.ApproximateNumberOfMessagesNotVisible // "0" | tonumber)' 2>/dev/null || echo 0
}
