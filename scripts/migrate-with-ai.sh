#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# migrate-with-ai.sh
# Transforma archivos Groovy/Jenkins/Azure a GitHub Actions YAML usando OpenAI
# ──────────────────────────────────────────────────────────────────────────────

# Variables requeridas (inyectadas por GitHub Actions)
: "${OPENAI_API_KEY:?ERROR: falta OPENAI_API_KEY}"
: "${OPENAI_MODEL:=gpt-4o}"
: "${REPO_NAME:?ERROR: falta REPO_NAME}"
: "${BRANCH_NAME:?ERROR: falta BRANCH_NAME}"
: "${FILES_TO_MIGRATE:?ERROR: falta FILES_TO_MIGRATE}"
: "${TYPE:?ERROR: falta TYPE (jenkins/azure)}"

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

echo "Iniciando migración IA para ${REPO_NAME}@${BRANCH_NAME}"
echo "Archivos a procesar: $FILES_TO_MIGRATE"

for file in $FILES_TO_MIGRATE; do
  rel_path="${file#./}"
  echo "Procesando archivo: $rel_path"

  content=$(cat "$file" | jq -Rsa .)

  prompt=$(cat <<'EOP'
Eres un experto DevOps con +15 años de experiencia migrando CI/CD.

Convierte este archivo completo (${rel_path}, tipo ${TYPE}) a GitHub Actions YAML moderno y robusto.

Reglas estrictas:
- Si es .groovy en vars/: genera Composite Action (.github/actions/nombre/action.yml) con inputs y steps equivalentes.
- Si es clase en src/ (Groovy/Java): traduce lógica a steps run: bash o java.
- Si es Jenkinsfile o azure-pipelines.yml: genera Reusable Workflow (.github/workflows/nombre.yml) con workflow_call, inputs, secrets: inherit.
- Siempre incluye:
  - actions/cache para dependencias (maven, npm, nuget, etc.)
  - Manejo de errores (continue-on-error, if: failure(), retry si aplica)
  - Matrix cuando tenga sentido (lenguajes, entornos, OS)
  - Condiciones if: para etapas opcionales
- Genera uno o varios archivos YAML separados por --- (cada uno con su nombre sugerido en comentario inicial).
- Devuelve SOLO código YAML válido, sin texto adicional ni explicaciones.

Contenido del archivo:
$content
EOP
  )

  response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d '{
      "model": "'"$OPENAI_MODEL"'",
      "messages": [{"role": "user", "content": "'"$prompt"'"}],
      "temperature": 0.2,
      "max_tokens": 12000
    }')

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "ERROR: respuesta vacía de OpenAI para $rel_path"
    echo "$response" > "$OUTPUT_BASE/error-$rel_path.json"
    continue
  fi

  # Nombre seguro para carpeta
  safe_name=$(echo "$rel_path" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/\.[^.]*$//')
  output_dir="$OUTPUT_BASE/$safe_name"
  mkdir -p "$output_dir"

  # Dividir por --- y guardar cada parte como .yml
  echo "$generated" | csplit -f "part-" -n 2 -s '/^---$/' '{*}'

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

echo "Migración IA completada para ${REPO_NAME}@${BRANCH_NAME}"
ls -R migrated/ || echo "No se generaron archivos"