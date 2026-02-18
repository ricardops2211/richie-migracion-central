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
  rel_path="${file#./}"
  echo "→ Procesando: $rel_path"

  content=$(cat "source-repo/$file" | jq -Rsa . 2>/dev/null || echo "Error leyendo archivo")

  prompt=$(cat <<'EOP'
Eres un experto DevOps senior. Convierte este archivo (${rel_path}, tipo ${TYPE}) a GitHub Actions YAML robusto y moderno.

Reglas estrictas:
- .groovy en vars/ → Composite Action (.github/actions/nombre/action.yml)
- src/ (Groovy/Java-like) → lógica en steps run: bash o java
- Jenkinsfile o azure-pipelines.yml → Reusable Workflow con workflow_call
- Siempre añade: actions/cache, error handling (continue-on-error, retry), matrix si aplica
- Genera YAMLs separados por --- si hay múltiples
- Devuelve SOLO código YAML, sin explicaciones

Contenido:
$content
EOP
  )

  response=$(curl -s https://api.groq.com/openai/v1/chat/completions \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"$GROQ_MODEL"'",
      "messages": [{"role": "user", "content": "'"$prompt"'"}],
      "temperature": 0.2,
      "max_tokens": 12000
    }')

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "ERROR Groq para $rel_path"
    echo "$response" > "$OUTPUT_BASE/error-$rel_path.json"
    continue
  fi

  safe_name=$(echo "$rel_path" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/\.[^.]*$//')
  output_dir="$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"

  echo "$generated" | csplit -f "part-" -n 2 -s '/^---$/' '{*}' 2>/dev/null || echo "No se pudo dividir"

  i=1
  for part in part-*; do
    if [ -s "$part" ]; then
      target="$output_dir/generated_${i}.yml"
      mv "$part" "$target"
      echo "  Generado: $target"
      ((i++))
    else
      rm "$part"
    fi
  done
done

echo "Migración finalizada con Groq"
ls -R migrated/ 2>/dev/null || echo "No hay archivos migrados"