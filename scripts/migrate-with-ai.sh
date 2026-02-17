#!/bin/bash

set -e

# ============================
# CONFIG
# ============================

OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_MODEL=${OPENAI_MODEL:-gpt-4.1}
GITHUB_REPO=$1
BRANCH=${2:-master}

if [ -z "$OPENAI_API_KEY" ]; then
  echo "❌ OPENAI_API_KEY no está definido"
  exit 1
fi

if [ -z "$GITHUB_REPO" ]; then
  echo "❌ Uso: ./migrate-with-ai.sh owner/repo [branch]"
  exit 1
fi

echo "🔄 Migrando $GITHUB_REPO@$BRANCH"

# ============================
# CLONAR REPO
# ============================

rm -rf repo migrated
git clone --depth 1 --branch "$BRANCH" "https://github.com/$GITHUB_REPO.git" repo

mkdir -p "migrated/$GITHUB_REPO/$BRANCH"

cd repo

FILES=$(find . -type f \( -name "*.yml" -o -name "*.yaml" \))

if [ -z "$FILES" ]; then
  echo "⚠️ No se encontraron archivos YAML"
  exit 0
fi

echo "📂 Archivos encontrados:"
echo "$FILES"

# ============================
# PROCESAR ARCHIVOS
# ============================

for file in $FILES; do
  echo "-------------------------------------------------"
  echo "🚀 Procesando $file"

  content=$(cat "$file")

  prompt="Eres un experto DevOps.

Migra el siguiente pipeline a Jenkins declarative pipeline.

Devuelve SOLO el código Jenkinsfile.
No agregues explicaciones.

Contenido original:
$content
"

  # ============================
  # LLAMADA A OPENAI (FORMA CORRECTA)
  # ============================

  response=$(jq -n \
    --arg model "$OPENAI_MODEL" \
    --arg prompt "$prompt" \
    '{
      model: $model,
      messages: [
        { role: "user", content: $prompt }
      ],
      temperature: 0.2,
      max_tokens: 4000
    }' | curl -s https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer '"$OPENAI_API_KEY"'" \
        -d @-)

  # Mostrar respuesta completa para debug
  echo "🧠 Respuesta API:"
  echo "$response" | jq .

  # Verificar si hubo error
  api_error=$(echo "$response" | jq -r '.error.message // empty')

  if [ -n "$api_error" ]; then
    echo "❌ Error OpenAI: $api_error"
    continue
  fi

  generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$generated" ]; then
    echo "❌ Error IA: respuesta vacía"
    continue
  fi

  # ============================
  # GUARDAR RESULTADO
  # ============================

  output_path="../migrated/$GITHUB_REPO/$BRANCH/${file#./}"
  mkdir -p "$(dirname "$output_path")"

  echo "$generated" > "$output_path"

  echo "✅ Migrado → $output_path"

done

cd ..

echo "-------------------------------------------------"
echo "🎉 Migración completada"
echo "📁 Resultados en: migrated/$GITHUB_REPO/$BRANCH"
