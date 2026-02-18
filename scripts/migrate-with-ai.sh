#!/usr/bin/env bash
set -euo pipefail

# Variables requeridas desde el workflow
GROQ_API_KEY="${GROQ_API_KEY:-}"
GROQ_MODEL="${GROQ_MODEL:-llama-3.3-70b-versatile}"
REPO_NAME="${REPO_NAME:-unknown-repo}"
BRANCH_NAME="${BRANCH_NAME:-unknown-branch}"
FILES_TO_MIGRATE="${FILES_TO_MIGRATE:-}"
TYPE="${TYPE:-unknown}"
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-4}"

echo "=== DEBUG GROQ ==="
echo "GROQ_MODEL: $GROQ_MODEL"
echo "REPO_NAME: $REPO_NAME"
echo "BRANCH_NAME: $BRANCH_NAME"
echo "TYPE: $TYPE"
echo "PWD: $(pwd)"
echo "==================="

if [ -z "$GROQ_API_KEY" ]; then
  echo "ERROR: GROQ_API_KEY no está definida"
  exit 1
fi

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "No hay archivos para migrar"
  exit 0
fi

SOURCE_REPO_PATH="../source-repo"
OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE"

file_count=0
processed=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  ((file_count++))
  
  file=$(echo "$file" | xargs)
  full_path="$SOURCE_REPO_PATH/$file"
  
  echo "→ Procesando: $file ($(($processed + 1))/$file_count)"
  
  if [ ! -f "$full_path" ]; then
    echo "  ⚠ Archivo no encontrado: $full_path"
    mkdir -p "$OUTPUT_BASE"
    echo "{\"error\": \"File not found: $full_path\"}" > "$OUTPUT_BASE/error-$(basename "$file" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
    continue
  fi
  
  echo "  ✓ Archivo encontrado, leyendo..."
  content=$(cat "$full_path")
  
  # Prompt mejorado para generar archivos separados
  prompt="Eres un experto DevOps senior. Convierte este archivo ($file, tipo $TYPE) a GitHub Actions YAML.

REGLAS CRÍTICAS:
1. Si generas MÚLTIPLES archivos, sepáralos con '---ARCHIVO_SEPARATOR---' (NO con ---)
2. ANTES de cada YAML, escribe: '##FILE: ruta/del/archivo.yml'
3. .groovy en vars/ → .github/actions/nombre/action.yml (Composite Action)
4. Jenkinsfile → .github/workflows/nombre.yml (Reusable Workflow con workflow_call)
5. Cada archivo debe ser YAML válido y COMPLETO
6. Siempre incluye: actions/cache, error handling, retry si aplica
7. NO incluyas explicaciones, SOLO YAML

EJEMPLO DE SALIDA:
##FILE: .github/actions/miAccion/action.yml
name: miAccion
description: Descripción
runs:
  using: composite
  steps:
    - name: Step
      run: echo \"hello\"

---ARCHIVO_SEPARATOR---

##FILE: .github/workflows/deploy.yml
name: deploy
on:
  workflow_call:
    inputs:
      env:
        type: string
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

---ARCHIVO_SEPARATOR---

Contenido a convertir:
$content"

  echo "  Enviando a Groq API..."
  
  max_retries=3
  retry=0
  success=false
  
  while [ $retry -lt $max_retries ] && [ "$success" = false ]; do
    response=$(curl -s https://api.groq.com/openai/v1/chat/completions \
      -H "Authorization: Bearer $GROQ_API_KEY" \
      -H "Content-Type: application/json" \
      -d @- <<EOF
{
  "model": "$GROQ_MODEL",
  "messages": [{"role": "user", "content": $(printf '%s\n' "$prompt" | jq -Rs .)}],
  "temperature": 0.2,
  "max_tokens": 15000
}
EOF
    )
    
    generated=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    
    if [ -n "$generated" ]; then
      success=true
      break
    fi
    
    error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ "$error_msg" == *"Rate limit"* ]]; then
      ((retry++))
      if [ $retry -lt $max_retries ]; then
        wait_time=$((RATE_LIMIT_DELAY + retry * 2))
        echo "  ⏳ Rate limit. Esperando ${wait_time}s (intento $((retry+1))/$max_retries)..."
        sleep "$wait_time"
      fi
    else
      echo "  ❌ ERROR: $error_msg"
      echo "$response" > "$OUTPUT_BASE/error-$(basename "$file").json"
      success=false
      break
    fi
  done
  
  if [ "$success" = true ]; then
    safe_name=$(basename "$file" | sed 's/\.[^.]*$//' | sed 's/[^a-zA-Z0-9._-]/_/g')
    output_dir="$OUTPUT_BASE/$safe_name"
    mkdir -p "$output_dir"
    
    # Dividir por ---ARCHIVO_SEPARATOR---
    echo "$generated" | awk '
      BEGIN {
        file_num = 0
        current_file = ""
        content = ""
      }
      /^---ARCHIVO_SEPARATOR---$/ {
        if (current_file != "") {
          filename = "'$output_dir'/" file_num "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          print "    ✓ Generado: " filename
        }
        file_num = 0
        current_file = ""
        content = ""
        next
      }
      /^##FILE:/ {
        # Guardar archivo anterior si existe
        if (current_file != "") {
          filename = "'$output_dir'/" file_num "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          print "    ✓ Generado: " filename
          file_num++
        }
        # Extraer nombre del archivo
        current_file = $0
        gsub(/^##FILE:[ \t]*/, "", current_file)
        gsub(/[ \t]*$/, "", current_file)
        content = ""
        next
      }
      {
        if (current_file != "") {
          content = content $0 "\n"
        }
      }
      END {
        if (current_file != "") {
          filename = "'$output_dir'/" file_num "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          print "    ✓ Generado: " filename
        }
      }
    '
    
    echo "  ✓ Procesado completamente"
    ((processed++))
    
    if [ $processed -lt $file_count ]; then
      echo "  ⏰ Esperando ${RATE_LIMIT_DELAY}s..."
      sleep "$RATE_LIMIT_DELAY"
    fi
  else
    echo "  ❌ No se pudo procesar después de $max_retries intentos"
  fi
  
done <<< "$FILES_TO_MIGRATE"

echo ""
echo "=== Migración finalizada ==="
echo "Procesados: $processed/$file_count archivos"
if [ -d "migrated" ]; then
  total_files=$(find migrated -type f 2>/dev/null | wc -l)
  echo "$total_files archivos generados:"
  find migrated -type f | sed 's/^/  /'
else
  echo "⚠ No hay archivos migrados"
fi