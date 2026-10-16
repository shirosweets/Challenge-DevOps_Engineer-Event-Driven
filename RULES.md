# 📜 REGLAS DEL CHALLENGE “El Guardián del Sistema - Rescatando la Infraestructura Rota en AWS”

**Este no es un examen**. Es una oportunidad para demostrar **cómo piensas**, cómo resuelves problemas reales de arquitectura e infraestructura, y **cómo aplicas tus conocimientos actuales en un entorno controlado.**

No buscamos perfección absoluta - buscamos criterio técnico, capacidad de depuración, resiliencia ante errores heredados, ética y atención al detalle.

---

## 🛠️ Reglas técnicas

1. **Uso exclusivo de herramientas open source y emulación local:**
   - La totalidad del desafío debe correr en local utilizando LocalStack, Docker Compose y Terraform.
   - Prohibido desplegar recursos en cuentas reales de AWS (el diseño debe ser 100% reproducible sin costo).
2. **Preservación del Estado en Terraform (Regla de Oro):**
   - **Prohibido editar a mano el archivo `terraform.tfstate`** o manipularlo con `terraform state rm/mv`/`import` para esquivar un plan que destruye recursos.
   - La infraestructura simula un entorno productivo con datos en vuelo. Cualquier refactorización o modularización **no debe destruir ni recrear recursos preexistentes**. El plan resultante debe ser limpio (`0 to add, 0 to change, 0 to destroy`).
   - **Sí está permitido borrar el state, pero solo junto con el entorno completo**: LocalStack no persiste nada al recrear su contenedor, así que el state queda obsoleto y hay que descartarlo. Se hace con `./scripts-challenge/reset-env.sh`, que borra contenedores, volúmenes y state a la vez, para repetir las pruebas desde cero.
   - **Está prohibido** borrar el state con la infraestructura aún en pie: así se evita el plan que destruye y recrea recursos. Hacerlo en medio de una refactorización invalida la entrega.
   - Cómo se comprueba: `terraform plan` debe salir limpio **tras** la refactorización sobre el mismo state, y el historial de commits debe mostrar el orden (primero la infraestructura original aplicada, después la modularización con `moved {}`).
3. **No alterar el contrato de los eventos:**
   - El payload que emite `scripts-challenge/seed-data.sh` representa transacciones bancarias reales; no puedes alterar el esquema del JSON entrante ni cambiar la firma de los atributos en DynamoDB.
4. **No modificar ni eliminar los scripts de verificación brindados:**
   - Los scripts dentro de `scripts-challenge/` son deterministas y se utilizan para auditar el cumplimiento del challenge.
   - *Puedes ejecutarlos, inspeccionarlos y aprender de ellos - pero no alterarlos.*
   - Su integridad se comprueba contra `scripts-challenge/CHECKSUMS` (sha256): `verify-pipeline.sh` falla si alguno fue modificado. Lo que **sí** es tuyo: `terraform/`, `src/`, `docker-compose.yml`, `Makefile` y cualquier archivo nuevo que agregues fuera de `scripts-challenge/`.
5. **Reproducibilidad:**
   - Tu solución debe levantarse desde cero con un único comando orquestador (`make up` o script documentado), sin pasos manuales que requieran interacción en consolas interactivas no versionadas.

---

## 🤖 Reglas de ética y uso de la IA

6. **PROHIBIDO EL USO DE IA SIN INTERVENCIÓN HUMANA PROFUNDA:**

   *Si bien en el día a día uno utiliza modelos de IA para agilizar ciertas tareas, la idea de este desafío es resolverlo con criterio propio, comprensión de los logs y la documentación técnica oficial.*

   Este challenge cuenta con **trampas de runtime, de red/DNS y de orden de arranque** (por ejemplo, direccionamiento de S3, tiempos de visibilidad frente al tiempo de proceso, políticas que dependen de la cuenta o condiciones de carrera entre servicios) diseñadas específicamente para fallar cuando se copian soluciones generadas por LLMs sin entender el contexto de ejecución.

   **¿Qué significa esto?**

   **Puedes usar IA como asistente:**
   - Consultar sintaxis específica (ej. *"¿Cómo se define un bloque `moved` en Terraform 1.5+?"*).
   - Revisar argumentos o firmas del SDK de Boto3 / AWS CLI.
   - Explicar códigos de error específicos arrojados por el kernel o LocalStack.

   **NO puedes usar IA para:**
   - Copiar/pegar soluciones completas de código, Dockerfiles o manifiestos HCL. Si tu entrega tiene el patrón típico de código alucinado (permisos excesivos, `chmod 777`, valores sin justificar, o destruir recursos al modularizar), será invalidada automáticamente.
   - Generar respuestas teóricas en el README que no coincidan exactamente con lo que implementaste en los commits.
   - Ignorar las trampas anti-IA (están puestas a propósito para desarrolladores curiosos).

7. **Transparencia obligatoria:**
   - Debes incluir un apartado en tu `README.md` aclarando con total honestidad **para qué utilizaste la IA** durante la resolución y en qué tareas cotidianas de un trabajo real la hubieras aprovechado sin estas restricciones.

---

## 🐧 Reglas de entorno

En DevOps y DevSecOps a menudo heredas sistemas rotos o entornos limpios donde debes diagnosticar a bajo nivel.

8. **Entorno recomendado:**
   - Distribución Linux estándar (Ubuntu, Debian, Fedora, Arch) o máquina virtual dedicada.
   - Todo debe ejecutarse vía terminal y Docker CLI.
   - *Si trabajas sobre macOS / WSL2, asegúrate de validar que la resolución de puertos, nombres y rutas de LocalStack funcione de forma determinista antes de entregar.*
9. **Mantener la licencia del proyecto:**
   - Respeta los archivos de licencia y atribución incluidos en el repositorio base.