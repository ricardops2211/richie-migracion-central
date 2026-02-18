#!/usr/bin/env bash
set -euo pipefail

# Variables requeridas desde el workflow
GROQ_API_KEY="${GROQ_API_KEY:-}"
GROQ_MODEL="${GROQ_MODEL:-deepseek-coder-v2-lite}"
REPO_NAME="${REPO_NAME:-unknown-repo}"
BRANCH_NAME="${BRANCH_NAME:-unknown-branch}"
FILES_TO_MIGRATE="${FILES_TO_MIGRATE:-}"
TYPE="${TYPE:-unknown}"

# Depuración inicial
echo "=== DEBUG GROQ ==="
echo "GROQ_MODEL: $GROQ_MODEL"
echo "REPO_NAME: $REPO_NAME"
echo "BRANCH_NAME: $BRANCH_NAME"
echo "FILES_TO_MIGRATE: $FILES_TO_MIGRATE"
echo "TYPE: $TYPE"
echo "==================="

if [ -z "$GROQ_API_KEY" ]; then
  echo "ERROR: GROQ_API_KEY no está definida"
  exit 1
fi

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "No hay archivos para migrar"
  exit 0
fi

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

for file in $FILES_TO_MIGRATE; do
  # Limpiar el prefijo ./
  clean_file="${file#./}"
  full_path="source-repo/$clean_file"
  
  echo "→ Procesando: $clean_file"
  
  # Verificar que el archivo existe
  if [ ! -f "$full_path" ]; then
    echo "  ⚠ Archivo no encontrado: $full_path"
    mkdir -p "$OUTPUT_BASE"
    echo "{\"error\": \"File not found: $full_path\"}" > "$OUTPUT_BASE/error-$(echo "$clean_file" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
    continue
  fi
  
  # Leer contenido del archivo
  content=$(cat "$full_path" | jq -Rsa .)
  
  # Construir el prompt (sin variables bash, pasarlas directamente)
  prompt="Eres un experto DevOps senior. Convierte este archivo (${clean_file}, tipo ${TYPE}) a GitHub Actions YAML robusto y moderno.

Reglas estrictas:
- .groovy en vars/ → Composite Action (.github/actions/nombre/action.yml)
- src/ (Groovy/Java-like) → lógica en steps run: bash o java
- Jenkinsfile o azure-pipelines.yml → Reusable Workflow con workflow_call
- Siempre añade: actions/cache, error handling (continue-on-error, retry), matrix si aplica
- Genera YAMLs separados por --- si hay múltiples
- Devuelve SOLO código YAML, sin explicaciones

Contenido:
$content"

  echo "  Enviando a Groq API..."
  
  # Llamar a Groq API
  response=$(curl -s https://api.groq.com/openai/v1/chat/completions \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "model": "$GROQ_MODEL",
  "messages": [{"role": "user", "content": $(echo "$prompt" | jq -Rsa .)}],
  "temperature": 0.2,
  "max_tokens": 12000
}
EOF
  )
  
  # Extraer la respuesta generada
  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  
  if [ -z "$generated" ]; then
    echo "  ❌ ERROR: Groq no respondió correctamente para $clean_file"
    mkdir -p "$OUTPUT_BASE"
    echo "$response" > "$OUTPUT_BASE/error-$(echo "$clean_file" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
    continue
  fi
  
  # Crear nombre seguro para el directorio de salida
  safe_name=$(echo "$clean_file" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/\.[^.]*$//')
  output_dir="$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"
  
  # Dividir YAMLs por --- usando awk
  echo "$generated" | awk 'BEGIN {file=1; content=""} 
    /^---$/ {
      if (content != "") {
        filename="'$output_dir'/generated_" file ".yml"
        print content > filename
        file++
        content=""
      }
      next
    }
    {content = content $0 "\n"}
    END {
      if (content != "") {
        filename="'$output_dir'/generated_" file ".yml"
        print content > filename
      }
    }'
  
  # Contar YAMLs generados
  yml_count=$(find "$output_dir" -name "generated_*.yml" 2>/dev/null | wc -l)
  echo "  ✓ Generados $yml_count archivo(s) YAML en $output_dir"
done

echo ""
echo "=== Migración finalizada con Groq ==="
if [ -d "migrated" ]; then
  echo "Estructura generada:"
  find migrated -type f | head -20
  [ $(find migrated -type f | wc -l) -gt 20 ] && echo "... y más archivos"
else
  echo "⚠ No hay archivos migrados"
fi