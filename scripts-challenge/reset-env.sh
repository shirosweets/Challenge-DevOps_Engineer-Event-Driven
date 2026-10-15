#!/usr/bin/env bash
# Deja el entorno limpio para repetir las pruebas desde cero.
#   ./scripts-challenge/reset-env.sh          -> limpia (contenedores, volúmenes, estado de Terraform)
#   ./scripts-challenge/reset-env.sh --up     -> limpia y vuelve a levantar LocalStack + terraform apply
#   ./scripts-challenge/reset-env.sh --full   -> como --up y además levanta el worker
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  ""|--up|--full) ;;
  *) echo "Uso: $0 [--up|--full]"; exit 1 ;;
esac

echo "[1/4] Deteniendo contenedores y borrando volúmenes..."
docker compose down -v --remove-orphans 2>&1 | grep -v "^$" || true

echo "[2/4] Borrando datos persistidos de LocalStack (.localstack)..."
if [ -d .localstack ]; then
  # LocalStack escribe como root dentro del contenedor, por lo que se borra desde uno
  docker run --rm -v "$PWD:/work" --entrypoint sh localstack/localstack:3.4 -c 'rm -rf /work/.localstack' \
    || rm -rf .localstack
fi

echo "[3/4] Borrando estado local de Terraform (tfstate y locks)..."
rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup terraform/.terraform.tfstate.lock.info
rm -f terraform/*.tfstate.[0-9]*

echo "[4/4] Entorno limpio."

if [ -z "$MODE" ]; then
  echo "Para volver a levantar todo: $0 --up"
  exit 0
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Levantando LocalStack..."
docker compose up -d localstack

# No depende de que el compose defina healthcheck: se espera al endpoint de salud de LocalStack
for _ in $(seq 1 60); do
  curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1 && break
  sleep 2
done
curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1 \
  || { echo "LocalStack no quedó disponible tras 120 s. Revisa: docker compose logs localstack"; exit 1; }

echo "Aplicando Terraform..."
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false | tail -n 3

if [ "$MODE" = "--full" ]; then
  echo "Construyendo y levantando el worker..."
  docker compose up -d --build worker
fi

echo "Listo. Siguiente paso: ./scripts-challenge/seed-data.sh y ./scripts-challenge/verify-pipeline.sh"
