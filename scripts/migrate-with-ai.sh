#!/usr/bin/env bash
set -euo pipefail

# Variables de entorno (con defaults seguros para pruebas)
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"
REPO_NAME="${REPO_NAME:-unknown-repo}"
BRANCH_NAME="${BRANCH_NAME:-unknown-branch}"
FILES_TO_MIGRATE="${FILES_TO_MIGRATE:-}"
TYPE="${TYPE:-unknown}"

# Logging para depuración
echo "=== DEBUG: Variables recibidas ==="
echo "OPENAI_API_KEY: [longitud ${#OPENAI_API_KEY} caracteres]"
echo "OPENAI_MODEL: $OPENAI_MODEL"
echo "REPO_NAME: $REPO_NAME"
echo "BRANCH_NAME: $BRANCH_NAME"
echo "FILES_TO_MIGRATE: $FILES_TO_MIGRATE"
echo "TYPE: $TYPE"
echo "=================================="

if [ -z "$OPENAI_API_KEY" ]; then
  echo "ERROR: OPENAI_API_KEY no está definida o está vacía"
  exit 1
fi

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "No hay archivos para migrar. Saliendo sin error."
  exit 0
fi

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

echo "Iniciando migración para ${REPO_NAME}@${BRANCH_NAME}"

for file in $FILES_TO_MIGRATE; do
  rel_path="${file#./}"
  echo "→ Procesando: $rel_path"

  content=$(cat "source-repo/$file" | jq -Rsa . 2>/dev/null || echo "Error leyendo $file")

  prompt=$(cat <<'EOP'
Eres un experto DevOps. Convierte este archivo (${rel_path}, tipo ${TYPE}) a GitHub Actions YAML robusto.

Reglas:
- vars/*.groovy → Composite Action
- src/* → lógica en steps
- Jenkinsfile o azure-pipelines.yml → Reusable Workflow
- Añade caching, error handling, matrix si aplica
- Devuelve SOLO YAML, separado por --- si hay varios

Contenido:
$content
EOP
  )

  response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d '{
      "model": "'"$OPENAI_MODEL"'",
      "messages": [{"role": "user", "content": "'"$prompt"'"}],
      "temperature": 0.2,
      "max_tokens": 12000
    }' || echo "Error curl")

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "ERROR en respuesta para $rel_path"
    echo "$response" > "$OUTPUT_BASE/error-$rel_path.json"
    continue
  fi

  safe_name=$(echo "$rel_path" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/\.[^.]*$//')
  output_dir="$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"

  echo "$generated" | csplit -f "part-" -n 2 -s '/^---$/' '{*}' 2>/dev/null || echo "No se pudo dividir con ---"

  i=1
  for part in part-*; do
    if [ -s "$part" ]; then
      mv "$part" "$output_dir/generated_${i}.yml"
      ((i++))
    else
      rm "$part"
    fi
  done
done

echo "Finalizado"
ls -R migrated/ 2>/dev/null || echo "No hay archivos migrados"