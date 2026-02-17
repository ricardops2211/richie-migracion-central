#!/usr/bin/env bash
set -euo pipefail

: "${OPENAI_API_KEY:?}"
: "${OPENAI_MODEL:=gpt-4o}"
: "${REPO_NAME:?}"
: "${BRANCH_NAME:?}"
: "${FILES_TO_MIGRATE:?}"
: "${TYPE:?}"

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

cd target-repo

echo "Migrando $REPO_NAME@$BRANCH_NAME"
echo "Archivos: $FILES_TO_MIGRATE"

for file in $FILES_TO_MIGRATE; do
  rel="${file#./}"
  echo "Procesando $rel"

  content=$(jq -Rsa . < "$file")

  prompt=$(cat <<EOP
Eres un experto DevOps senior.

Convierte este archivo (${rel}, tipo ${TYPE})
a GitHub Actions YAML moderno y robusto.

Reglas:
- vars/*.groovy → Composite Action
- src/*.groovy → steps bash/java
- Jenkinsfile / azure-pipelines → Reusable Workflow
- Incluye cache, matrix, manejo errores.
- Devuelve SOLO YAML separado por ---.

Contenido:
${content}
EOP
)

  response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "{
      \"model\": \"${OPENAI_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": $content}],
      \"temperature\": 0.2,
      \"max_tokens\": 12000
    }")

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "Error IA"
    continue
  fi

  safe=$(echo "$rel" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/\.[^.]*$//')
  dir="../$OUTPUT_BASE/$safe"
  mkdir -p "$dir"

  echo "$generated" | csplit -f "$dir/part-" -n 2 -s '/^---$/' '{*}'

  i=1
  for p in "$dir"/part-*; do
    if [ -s "$p" ]; then
      mv "$p" "$dir/generated_${i}.yml"
      ((i++))
    else
      rm "$p"
    fi
  done

done

cd ..
echo "Migración completada"
ls -R migrated || true
