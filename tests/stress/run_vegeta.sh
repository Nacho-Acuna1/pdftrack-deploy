#!/usr/bin/env bash
# ==============================================================================
# PDFtrack - Vegeta Stress Test (Modelo Abierto de Carga)
# ==============================================================================
# Prueba de carga constante a tasa fija (Open Model) para evaluar el
# comportamiento del sistema PDFtrack bajo arribo constante de peticiones.
#
# Configuración:
#   - Tasa de ataque: 50 req/s constantes
#   - Duración: 30 segundos
#   - Total generado: 1500 peticiones
#   - Timeout por request: 30s
#   - Método: POST /extract
#   - Content-Type: application/pdf
#   - Payload: Rota secuencialmente los 4 PDFs oficiales
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PDF_DIR="$SCRIPT_DIR/pdfs"
RESULTS_DIR="$SCRIPT_DIR/results"

# 1. Crear el directorio de resultados si no existe
mkdir -p "$RESULTS_DIR"

# 2. Verificar que los 4 PDFs oficiales existen antes de iniciar
PDF_FILES=(
  "Guide-Spanish-LatinSouth-American.pdf"
  "Filosofia Lean.pdf"
  "scrum_manager_historias_usuario.pdf"
  "Essential-Kanban-Condensed-Spanish.pdf"
)

echo "==> Verificando existencia de los 4 PDFs oficiales en $PDF_DIR..."
for pdf in "${PDF_FILES[@]}"; do
  if [ ! -f "$PDF_DIR/$pdf" ]; then
    echo "ERROR: Falta el archivo PDF requerido: $PDF_DIR/$pdf" >&2
    echo "Por favor verifique que los 4 PDFs oficiales de la cátedra estén presentes." >&2
    exit 1
  fi
done
echo ">> Todos los PDFs oficiales verificados correctamente."

# Configuración de red y destino
PUBLIC_PORT="${PUBLIC_PORT:-80}"
TARGET_URL="http://localhost:${PUBLIC_PORT}/extract"

echo "==> Generando archivo de objetivos para Vegeta (Destino: $TARGET_URL)..."
TARGETS_FILE="$RESULTS_DIR/vegeta-targets.txt"
rm -f "$TARGETS_FILE"

for pdf in "${PDF_FILES[@]}"; do
  cat <<EOF >> "$TARGETS_FILE"
POST $TARGET_URL
Content-Type: application/pdf
@tests/stress/pdfs/$pdf

EOF
done

echo "==> Iniciando ataque con Vegeta: 50 req/s por 30s (1500 peticiones)..."

# 3. Ejecutar ataque usando tee para guardar binario y procesar simultáneamente
# Si vegeta está instalado localmente, lo ejecuta; caso contrario usa el contenedor peterevans/vegeta
if command -v vegeta >/dev/null 2>&1; then
  echo ">> Ejecutando Vegeta binario local..."
  vegeta attack \
    -format=http \
    -targets="$TARGETS_FILE" \
    -rate=50/s \
    -duration=30s \
    -timeout=30s \
    | tee "$RESULTS_DIR/vegeta-results.bin" \
    | vegeta report -type=text > "$RESULTS_DIR/vegeta-report.txt"

  vegeta report -type=json "$RESULTS_DIR/vegeta-results.bin" > "$RESULTS_DIR/vegeta-report.json"
else
  echo ">> Ejecutando Vegeta mediante contenedor Docker peterevans/vegeta (--network host)..."
  docker run --rm -i --network host \
    -v "$ROOT_DIR:/workspace" \
    -w /workspace \
    peterevans/vegeta sh -c '
      vegeta attack \
        -format=http \
        -targets=tests/stress/results/vegeta-targets.txt \
        -rate=50/s \
        -duration=30s \
        -timeout=30s \
        | tee tests/stress/results/vegeta-results.bin \
        | vegeta report -type=text > tests/stress/results/vegeta-report.txt
      vegeta report -type=json tests/stress/results/vegeta-results.bin > tests/stress/results/vegeta-report.json
    '
fi

# 5. Mostrar el reporte txt al final por stdout
echo ""
echo "=============================================================================="
echo " PDFtrack - Reporte de Resultados Vegeta (Modelo Abierto de Carga)"
echo "=============================================================================="
cat "$RESULTS_DIR/vegeta-report.txt"
echo "=============================================================================="

# 6. Informar dónde quedaron guardados los resultados
echo ""
echo ">> Resultados guardados exitosamente en $RESULTS_DIR:"
echo "   - Binario bruto:       $RESULTS_DIR/vegeta-results.bin"
echo "   - Reporte texto plano: $RESULTS_DIR/vegeta-report.txt"
echo "   - Reporte JSON:        $RESULTS_DIR/vegeta-report.json"
echo ""
