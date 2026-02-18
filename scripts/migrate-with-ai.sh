#!/usr/bin/env bash
set -euo pipefail

# Variables requeridas desde el workflow
GROQ_API_KEY="${GROQ_API_KEY:-}"
GROQ_MODEL="${GROQ_MODEL:-deepseek-coder-v2-lite}"
REPO_NAME="${REPO_NAME:-unknown-repo}"
BRANCH_NAME="${BRANCH_NAME:-unknown-branch}"
FILES_TO_MIGRATE="${FILES_TO_MIGRATE:-}"
TYPE="${TYPE:-unknown}"

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

# Debug: mostrar archivos en source-repo
echo "DEBUG: Contenido de source-repo:"
find source-repo -type f \( -name "*.groovy" -o -name "Jenkinsfile*" \) 2>/dev/null || echo "  (ninguno encontrado)"
echo ""

while IFS= read -r file; do
  # Saltar líneas vacías
  [ -z "$file" ] && continue
  
  # Limpiar espacios
  file=$(echo "$file" | xargs)
  
  echo "→ Procesando: $file"
  
  # Construir ruta completa
  full_path="source-repo/$file"
  
  # Eliminar ./ si existe
  full_path="${full_path//\.\//}"
  
  # Verificar que el archivo existe
  if [ ! -f "$full_path" ]; then
    echo "  ⚠ Archivo no encontrado: $full_path"
    mkdir -p "$OUTPUT_BASE"
    echo "{\"error\": \"File not found: $full_path\", \"searched_at\": \"$(pwd)/$full_path\"}" > "$OUTPUT_BASE/error-$(basename "$file" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
    continue
  fi
  
  echo "  ✓ Archivo encontrado, leyendo..."
  
  # Leer contenido del archivo
  content=$(cat "$full_path")
  
  # Construir el prompt
  prompt="Eres un experto DevOps senior. Convierte este archivo ($file, tipo $TYPE) a GitHub Actions YAML robusto y moderno.

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
  "messages": [{"role": "user", "content": $(printf '%s\n' "$prompt" | jq -Rs .)}],
  "temperature": 0.2,
  "max_tokens": 12000
}
EOF
  )
  
  # Extraer la respuesta generada
  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  
  if [ -z "$generated" ]; then
    echo "  ❌ ERROR: Groq no respondió correctamente"
    echo "$response" > "$OUTPUT_BASE/error-$(basename "$file" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
    continue
  fi
  
  # Crear nombre seguro para el directorio de salida
  safe_name=$(basename "$file" | sed 's/\.[^.]*$//' | sed 's/[^a-zA-Z0-9._-]/_/g')
  output_dir="$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"
  
  # Guardar archivo generado
  echo "$generated" > "$output_dir/generated.yml"
  echo "  ✓ Guardado en: $output_dir/generated.yml"
  
done <<< "$FILES_TO_MIGRATE"

echo ""
echo "=== Migración finalizada ==="
find migrated -type f 2>/dev/null | wc -l
echo " archivos generados"