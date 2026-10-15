#!/bin/bash
# ==============================================================================
# AUDITORÍA DE PUNTOS: El Guardián del Pipeline
# Evalúa el estado del reto asignando puntaje por buenas prácticas,
# penalizando destrucción de estado o roturas funcionales.
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

success() { echo -e "${GREEN}✅ $1 (+$2 pts)${NC}"; PUNTOS=$((PUNTOS + $2)); }
error() { echo -e "${RED}❌ $1${NC}"; }

echo -e "${YELLOW}🛡️  EVALUANDO TU SOLUCIÓN: EL GUARDIÁN DEL PIPELINE...${NC}"
echo "No te decimos cómo arreglarlo. Solo si pasaste o no."
echo "=============================================="

cd "$(dirname "$0")/.."
# shellcheck source=helper/lib.sh
source scripts-challenge/helper/lib.sh

PUNTOS=0
ENDPOINT="$ENDPOINT_URL"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# 1. Disponibilidad de LocalStack & Healthcheck
if curl -sf "$ENDPOINT/_localstack/health" >/dev/null 2>&1; then
    success "LocalStack levantado y respondiendo en el puerto 4566" 10
else
    error "LocalStack no está accesible. No se pueden validar los siguientes puntos."
    echo -e "${RED}🎯 PUNTUACIÓN FINAL: 0/100${NC}"
    exit 1
fi

# 2. Terraform Provider & S3 Path Style
if [ -d "terraform" ] && (cd terraform && terraform validate -no-color >/dev/null 2>&1); then
    success "Sintaxis de Terraform y provider AWS validados correctamente" 10
else
    error "Configuración de Terraform inválida o provider mal configurado"
fi

# 3. Preservación del Estado en Terraform (REGLA DE ORO)
if [ -d "terraform" ]; then
    TF_PLAN=$(cd terraform && terraform plan -detailed-exitcode -no-color 2>&1)
    TF_CODE=$?

    if [ "$TF_CODE" -eq 0 ]; then
        success "Preservación de Estado: 0 recursos destruidos y estado limpio" 20
    elif echo "$TF_PLAN" | grep -q "to destroy"; then
        error "¡PÉRDIDA DE DATOS! El plan de Terraform intenta destruir recursos existentes"
        PUNTOS=$((PUNTOS - 15))
    else
        error "Terraform detectó cambios pendientes o desalineación en el plan"
    fi
else
    error "Directorio terraform/ no encontrado"
fi

# 4. Hardening de IAM (Principio de Menor Privilegio) sobre las políticas desplegadas
WILDCARDS=$(iam_wildcard_findings); IAM_RC=$?
if [ "$IAM_RC" -eq 3 ]; then
    error "No hay políticas IAM desplegadas: no se puede validar el menor privilegio"
elif [ -z "$WILDCARDS" ]; then
    success "Principio de menor privilegio: sin wildcards globales (*/*) en IAM" 15
else
    error "Políticas de IAM excesivamente permisivas (*/*) detectadas"
fi

# 5. Hardening de Contenedores (Worker no-root)
WORKER_USER=$(docker inspect --format '{{.Config.User}}' pipeline-worker 2>/dev/null) || WORKER_USER="not_found"
if [ "$WORKER_USER" != "not_found" ] && [ -n "$WORKER_USER" ] && [ "$WORKER_USER" != "root" ] && [ "$WORKER_USER" != "0" ]; then
    success "Contenedor hardened: worker corre con usuario sin privilegios" 10
else
    error "El worker corre como 'root' o no se pudo inspeccionar el contenedor"
fi

# 6. SQS Lifecycle & VisibilityTimeout
VISIBILITY=$(run_aws sqs get-queue-attributes \
    --queue-url "$ENDPOINT/000000000000/transactions-queue" \
    --attribute-names VisibilityTimeout \
    --query "Attributes.VisibilityTimeout" --output text 2>/dev/null || echo "0")

if [ "$VISIBILITY" -ge 20 ] 2>/dev/null; then
    success "VisibilityTimeout calibrado adecuadamente para evitar reentregas" 15
else
    error "VisibilityTimeout insuficiente frente al tiempo de procesamiento del worker"
fi

# 7. Redrive Policy y Dead-Letter Queue vinculada
REDRIVE=$(run_aws sqs get-queue-attributes \
    --queue-url "$ENDPOINT/000000000000/transactions-queue" \
    --attribute-names RedrivePolicy \
    --query "Attributes.RedrivePolicy" --output text 2>/dev/null || echo "")

if echo "$REDRIVE" | grep -q "000000000000:transactions-dlq"; then
    success "Dead-Letter Queue correctamente vinculada al entorno local" 10
else
    error "Redrive policy de SQS ausente o apuntando a cuenta incorrecta"
fi

# 8. S3 Public Access Block y Cifrado
S3_BLOCK=$(run_aws s3api get-public-access-block \
    --bucket "corporate-transactions-raw-payloads" 2>/dev/null || echo "")

if [ -n "$S3_BLOCK" ]; then
    success "Políticas de bloqueo de acceso público aplicadas en S3" 10
else
    error "Bucket de S3 sin bloqueo estricto de acceso público"
fi

# ------------------------------------------------------------------------------
# 9. Funcionalidad base del pipeline - ¡NO SUMA, SOLO RESTA!
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}Verificando funcionalidad del flujo...${NC}"

# Inyectamos 1 mensaje de prueba
TX_TEST="check-$(head -c 8 /dev/urandom | md5sum | head -c 6)"
PAYLOAD="{\"transaction_id\":\"$TX_TEST\",\"amount\":100,\"timestamp\":$(date +%s)}"

run_aws sqs send-message \
    --queue-url "$ENDPOINT/000000000000/transactions-queue" \
    --message-body "$PAYLOAD" >/dev/null 2>&1

# Espera activa (hasta 90 s) en lugar de un sleep fijo atado a los tiempos del worker
if wait_for_txs 90 "$TX_TEST"; then
    echo -e "${GREEN}✅ Funcionalidad de procesamiento y persistencia preservada${NC}"
else
    error "El worker no procesó la transacción en DynamoDB tras el ciclo"
    PUNTOS=$((PUNTOS - 15))
fi

# Verificar si cayó a la DLQ
DLQ_COUNT=$(run_aws sqs get-queue-attributes \
    --queue-url "$ENDPOINT/000000000000/transactions-dlq" \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text 2>/dev/null || echo "0")

if [ "$DLQ_COUNT" -eq 0 ] 2>/dev/null; then
    echo -e "${GREEN}✅ Cola DLQ limpia: sin transacciones descartadas${NC}"
else
    error "Hay mensajes atascados en la Dead-Letter Queue"
    PUNTOS=$((PUNTOS - 10))
fi

# ------------------------------------------------------------------------------
# Resumen y Veredicto
# ------------------------------------------------------------------------------
echo ""
[ $PUNTOS -lt 0 ] && PUNTOS=0
echo -e "${GREEN}🎯 PUNTUACIÓN FINAL: $PUNTOS/100${NC}"

if [ $PUNTOS -ge 90 ]; then
    echo -e "${GREEN}🏆 ¡EXCELENTE! Tu infraestructura es sólida, segura y resiliente.${NC}"
elif [ $PUNTOS -ge 70 ]; then
    echo -e "${YELLOW}👍 ¡BUEN TRABAJO! Con algunos ajustes de hardening, estará lista para producción.${NC}"
else
    echo -e "${RED}💪 ¡NO TE RINDAS! La infraestructura en la nube se construye iteración tras iteración.${NC}"
fi

echo -e "${YELLOW}💡 Consejo del Guardián: No eres guardián de configuraciones… eres guardián de la integridad de los datos que viajan por ellas.${NC}"