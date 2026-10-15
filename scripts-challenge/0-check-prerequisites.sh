#!/usr/bin/env bash
# ==============================================================================
# SCRIPT DE VERIFICACIÓN DE REQUISITOS
# Challenge: El Guardián del Pipeline - Rescatando la Infraestructura Rota en AWS
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0

echo -e "${BLUE}🔍 VERIFICANDO REQUISITOS DEL SISTEMA...${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Verificación de Docker (>= 24.0) y de que el daemon esté activo
echo -n "1. Verificando Docker... "
if ! command -v docker &> /dev/null; then
  echo -e "\n${RED}❌ Docker no está instalado.${NC}"
  ERRORS=$((ERRORS + 1))
elif ! DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || [ -z "$DOCKER_VER" ]; then
  echo -e "\n${RED}❌ El daemon de Docker no responde (¿está iniciado? ¿tu usuario pertenece al grupo docker?).${NC}"
  ERRORS=$((ERRORS + 1))
else
  DOCKER_MAJOR=${DOCKER_VER%%.*}
  if [ "$DOCKER_MAJOR" -ge 24 ] 2>/dev/null; then
    echo -e "${GREEN}✅ Docker $DOCKER_VER activo (>= 24.0)${NC}"
  else
    echo -e "\n${YELLOW}⚠️ Docker versión $DOCKER_VER detectada. Se recomienda >= 24.0.${NC}"
  fi
fi

# 2. Verificación de Docker Compose v2 (>= 2.20: depends_on con condition y healthchecks)
echo -n "2. Verificando Docker Compose v2... "
if COMPOSE_VER=$(docker compose version --short 2>/dev/null) && [ -n "$COMPOSE_VER" ]; then
  COMPOSE_VER=${COMPOSE_VER#v}
  C_MAJOR=${COMPOSE_VER%%.*}
  C_MINOR=$(echo "$COMPOSE_VER" | cut -d'.' -f2)
  if [ "$C_MAJOR" -gt 2 ] 2>/dev/null || { [ "$C_MAJOR" -eq 2 ] 2>/dev/null && [ "$C_MINOR" -ge 20 ] 2>/dev/null; }; then
    echo -e "${GREEN}✅ Docker Compose v2 ($COMPOSE_VER) instalado correctamente${NC}"
  else
    echo -e "\n${YELLOW}⚠️ Docker Compose $COMPOSE_VER detectado. Se recomienda >= 2.20.${NC}"
  fi
else
  echo -e "\n${RED}❌ Docker Compose v2 ('docker compose') no está disponible.${NC}"
  ERRORS=$((ERRORS + 1))
fi

# 3. Verificación de Terraform (>= 1.5.0)
echo -n "3. Verificando Terraform... "
if ! command -v terraform &> /dev/null; then
  echo -e "\n${RED}❌ Terraform no está instalado.${NC}"
  ERRORS=$((ERRORS + 1))
else
  TF_RAW_VER=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null)
  if [ -z "$TF_RAW_VER" ] || [ "$TF_RAW_VER" = "null" ]; then
    TF_RAW_VER=$(terraform version | head -n1 | awk '{print $2}' | tr -d 'v')
  fi
  TF_MAJOR=$(echo "$TF_RAW_VER" | cut -d'.' -f1)
  TF_MINOR=$(echo "$TF_RAW_VER" | cut -d'.' -f2)

  if [ "$TF_MAJOR" -gt 1 ] || { [ "$TF_MAJOR" -eq 1 ] && [ "$TF_MINOR" -ge 5 ]; }; then
    echo -e "${GREEN}✅ Terraform v$TF_RAW_VER instalado (>= 1.5.0)${NC}"
  else
    echo -e "\n${RED}❌ Terraform v$TF_RAW_VER detectado. Es obligatorio >= 1.5.0 para soporte de bloques moved {}.${NC}"
    ERRORS=$((ERRORS + 1))
  fi
fi

# 4. Verificación de herramientas CLI (jq, curl, aws cli / awslocal)
echo -n "4. Verificando utilidades auxiliares (jq, curl, AWS CLI)... "
MISSING_UTILS=()

command -v jq &> /dev/null || MISSING_UTILS+=("jq")
command -v curl &> /dev/null || MISSING_UTILS+=("curl")

if ! command -v aws &> /dev/null && ! command -v awslocal &> /dev/null; then
  MISSING_UTILS+=("aws-cli o awslocal")
fi

if [ ${#MISSING_UTILS[@]} -eq 0 ]; then
  echo -e "${GREEN}✅ Herramientas CLI disponibles (jq, curl, AWS CLI)${NC}"
else
  echo -e "\n${RED}❌ Faltan las siguientes utilidades: ${MISSING_UTILS[*]}${NC}"
  ERRORS=$((ERRORS + 1))
fi

# 5. AWS CLI v2 (los scripts usan `aws`; `awslocal` es una alternativa)
echo -n "5. Verificando versión de AWS CLI... "
if command -v aws &> /dev/null; then
  AWS_VER=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
  if [ "${AWS_VER%%.*}" -ge 2 ] 2>/dev/null; then
    echo -e "${GREEN}✅ AWS CLI $AWS_VER (>= 2.x)${NC}"
  else
    echo -e "\n${YELLOW}⚠️ AWS CLI $AWS_VER detectado. Se requiere v2.x.${NC}"
  fi
elif command -v awslocal &> /dev/null; then
  echo -e "${YELLOW}⚠️ Solo se encontró awslocal; funciona, pero se recomienda AWS CLI v2.${NC}"
else
  echo -e "${YELLOW}⚠️ No instalado (ya reportado en el punto 4)${NC}"
fi

# 6. Puerto 4566 (LocalStack)
echo -n "6. Verificando puerto 4566... "
if curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1; then
  echo -e "${GREEN}✅ LocalStack ya está respondiendo en el puerto 4566${NC}"
elif (exec 3<>/dev/tcp/127.0.0.1/4566) 2>/dev/null; then
  echo -e "\n${RED}❌ El puerto 4566 está ocupado por un proceso que no es LocalStack.${NC}"
  ERRORS=$((ERRORS + 1))
else
  echo -e "${GREEN}✅ Puerto 4566 libre${NC}"
fi

# 7. Espacio en disco (imágenes de LocalStack y del worker)
echo -n "7. Verificando espacio en disco... "
FREE_KB=$(df -Pk . | awk 'NR==2 {print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 4194304 ] 2>/dev/null; then
  echo -e "\n${YELLOW}⚠️ Menos de 4 GB libres ($((FREE_KB / 1024)) MB). Las imágenes pueden no caber.${NC}"
else
  echo -e "${GREEN}✅ Espacio suficiente${NC}"
fi

# 8. Perfil de AWS que podría apuntar a una cuenta real
echo -n "8. Verificando variables de entorno de AWS... "
if [ -n "${AWS_PROFILE:-}" ]; then
  echo -e "\n${YELLOW}⚠️ AWS_PROFILE=$AWS_PROFILE está definido. Ejecuta 'unset AWS_PROFILE' o usa credenciales dummy (ENUNCIADO 1.1) para no tocar una cuenta real.${NC}"
else
  echo -e "${GREEN}✅ Sin perfil de AWS configurado${NC}"
fi

echo ""

# Resumen final
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}🎉 ¡TODOS LOS REQUISITOS CUMPLIDOS!${NC}"
  echo -e "Puedes proceder a levantar LocalStack con: ${BLUE}docker compose up -d localstack${NC}"
  exit 0
else
  echo -e "${RED}⚠️ Se encontraron $ERRORS error(es). Por favor, resuelve las dependencias faltantes antes de continuar.${NC}"
  exit 1
fi
