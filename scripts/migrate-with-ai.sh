#!/usr/bin/env bash
set -euo pipefail

: "${OPENAI_API_KEY:?ERROR: falta OPENAI_API_KEY}"
: "${OPENAI_MODEL:=gpt-4o}"
: "${REPO_NAME:?ERROR: falta REPO_NAME}"
: "${BRANCH_NAME:?ERROR: falta BRANCH_NAME}"
: "${FILES_TO_MIGRATE:?ERROR: falta FILES_TO_MIGRATE}"
: "${TYPE:?ERROR: falta TYPE (jenkins/azure)}"

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

echo "Iniciando migración IA para ${REPO_NAME}@${BRANCH_NAME}"
echo "Archivos: $FILES_TO_MIGRATE"

cd target-repo

for file in $FILES_TO_MIGRATE; do
  rel_path="${file#./}"
  echo "Procesando: $rel_path"

  content=$(jq -Rsa . < "$file")

  prompt=$(cat <<EOP
Eres un experto DevOps con +15 años migrando CI/CD.

Convierte este archivo completo (${rel_path}, tipo ${TYPE})
a GitHub Actions YAML moderno y robusto.

Reglas estrictas:
- Si es .groovy en vars/: genera Composite Action (.github/actions/nombre/action.yml)
- Si es clase en src/: traduce lógica a steps run bash/java
- Si es Jenkinsfile o azure-pipelines.yml:
  genera Reusable Workflow (.github/workflows/nombre.yml)
  con workflow_call e inputs.
- Incluye cache, manejo de errores y matrix si aplica.
- Devuelve SOLO YAML válido separado por ---.

Contenido:
${content}
EOP
)

  response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "{
      \"model\": \"${OPENAI_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": ${content}}],
      \"temperature\": 0.2,
      \"max_tokens\": 12000
    }")

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "ERROR: respuesta vacía"
    echo "$response" > "$OUTPUT_BASE/error.json"
    continue
  fi

  safe_name=$(echo "$rel_path" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/\.[^.]*$//')
  output_dir="../$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"

  echo "$generated" | csplit -f "$output_dir/part-" -n 2 -s '/^---$/' '{*}'

  i=1
  for part in "$output_dir"/part-*; do
    if [ -s "$part" ]; then
      mv "$part" "$output_dir/generated_${i}.yml"
      ((i++))
    else
      rm "$part"
    fi
  done

done

echo "Migración completada"
cd ..
ls -R migrated || echo "Sin resultados"
