#!/bin/bash

set -e

OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_MODEL=${OPENAI_MODEL:-gpt-4.1}

if [ -z "$OPENAI_API_KEY" ]; then
  echo "❌ OPENAI_API_KEY no definido"
  exit 1
fi

rm -rf workspace migrated
mkdir -p workspace migrated

echo "🚀 Iniciando migración múltiple"

repo_count=$(jq length repos.json)

for ((i=0; i<repo_count; i++)); do

  repo=$(jq -r ".[$i].repo" repos.json)
  branch=$(jq -r ".[$i].branch" repos.json)
  shared_lib_path=$(jq -r ".[$i].shared_lib_path" repos.json)
  jenkins_path=$(jq -r ".[$i].jenkins_path" repos.json)
  type=$(jq -r ".[$i].type" repos.json)

  echo "------------------------------------------"
  echo "🔄 Procesando $repo ($type)"

  git clone --depth 1 --branch "$branch" "https://github.com/$repo.git" "workspace/$repo"

  cd "workspace/$repo"

  if [ ! -d "$shared_lib_path" ]; then
    echo "⚠️ Carpeta $shared_lib_path no encontrada"
    cd ../../
    continue
  fi

  FILES=$(find "$shared_lib_path" -type f)

  for file in $FILES; do
    echo "📄 Migrando $file"

    content=$(cat "$file")

    if [ "$type" == "azure" ]; then
      prompt="Eres experto DevOps.
Migra este Azure DevOps template a Jenkins Declarative Pipeline.
Devuelve solo el Jenkinsfile.

$content"
    else
      prompt="Eres experto en Jenkins Shared Libraries.
Convierte esta shared library en un Jenkinsfile declarative que la use.
Devuelve solo el Jenkinsfile.

$content"
    fi

    response=$(jq -n \
      --arg model "$OPENAI_MODEL" \
      --arg prompt "$prompt" \
      '{
        model: $model,
        messages: [
          { role: "user", content: $prompt }
        ],
        temperature: 0.1,
        max_tokens: 4000
      }' | curl -s https://api.openai.com/v1/chat/completions \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer '"$OPENAI_API_KEY"'" \
          -d @-)

    api_error=$(echo "$response" | jq -r '.error.message // empty')

    if [ -n "$api_error" ]; then
      echo "❌ Error OpenAI: $api_error"
      continue
    fi

    generated=$(echo "$response" | jq -r '.choices[0].message.content // empty')

    if [ -z "$generated" ]; then
      echo "❌ Respuesta vacía"
      continue
    fi

    output_dir="../../../migrated/$repo"
    mkdir -p "$output_dir"

    echo "$generated" > "$output_dir/$jenkins_path"

    echo "✅ Guardado en migrated/$repo/$jenkins_path"

  done

  cd ../../

done

echo "🎉 Migración completa"
