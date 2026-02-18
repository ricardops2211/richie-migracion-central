#!/usr/bin/env bash
set -uo pipefail  # Quitamos -e para manejar errores manualmente

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
mkdir -p "$OUTPUT_BASE" || { echo "ERROR: No se pudo crear $OUTPUT_BASE"; exit 1; }

echo "DEBUG: Verificando rutas:"
echo "  PWD: $(pwd)"
echo "  SOURCE_REPO_PATH existe: $([ -d "$SOURCE_REPO_PATH" ] && echo "SÍ" || echo "NO")"
echo "  OUTPUT_BASE: $OUTPUT_BASE"
echo ""

file_count=0
processed=0
failed=0

echo "Iniciando procesamiento de archivos..."
echo ""

while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue
  
  ((file_count++))
  file=$(echo "$file" | xargs)
  
  echo "→ [$(printf "%2d" $((processed + failed + 1)))/$file_count] Procesando: $file"
  
  full_path="$SOURCE_REPO_PATH/$file"
  
  # Verificar que el archivo existe
  if [ ! -f "$full_path" ]; then
    echo "  ⚠ ERROR: Archivo no encontrado: $full_path"
    ((failed++))
    continue
  fi
  
  echo "  ✓ Archivo encontrado"
  
  # Leer contenido del archivo
  content=$(cat "$full_path" 2>&1) || {
    echo "  ❌ ERROR: No se pudo leer el archivo"
    ((failed++))
    continue
  }
  
  # Construir el prompt
  read -r -d '' prompt << 'PROMPT_END' || true
Eres un experto DevOps senior. Convierte este archivo a GitHub Actions YAML.

REGLAS CRÍTICAS:
1. Si generas MÚLTIPLES archivos, sepáralos con '---ARCHIVO_SEPARATOR---'
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
      run: echo "hello"

---ARCHIVO_SEPARATOR---

##FILE: .github/workflows/deploy.yml
name: deploy
on:
  workflow_call:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

---ARCHIVO_SEPARATOR---

INFORMACIÓN DEL ARCHIVO:
- Nombre: $file
- Tipo: $TYPE

Contenido:
$content
PROMPT_END

  echo "  Enviando a Groq API..."
  
  max_retries=3
  retry=0
  success=false
  generated=""
  
  while [ $retry -lt $max_retries ] && [ "$success" = false ]; do
    echo "    [Intento $((retry + 1))/$max_retries]"
    
    response=$(curl -s -w "\n%{http_code}" https://api.groq.com/openai/v1/chat/completions \
      -H "Authorization: Bearer $GROQ_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$GROQ_MODEL\",
        \"messages\": [{\"role\": \"user\", \"content\": $(printf '%s\n' "$prompt" | jq -Rs .)}],
        \"temperature\": 0.2,
        \"max_tokens\": 15000
      }" 2>&1) || {
        echo "    ❌ Error en curl"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry))
        continue
      }
    
    # Separar respuesta del código HTTP
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    echo "    HTTP Code: $http_code"
    
    if [ "$http_code" = "200" ]; then
      generated=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
        echo "    ❌ Error parseando JSON"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry))
        continue
      }
      
      if [ -n "$generated" ]; then
        success=true
        echo "    ✓ Respuesta recibida ($(echo "$generated" | wc -c) caracteres)"
        break
      fi
    else
      error_msg=$(echo "$body" | jq -r '.error.message // "Error desconocido"' 2>/dev/null)
      
      if [[ "$error_msg" == *"Rate limit"* ]]; then
        ((retry++))
        if [ $retry -lt $max_retries ]; then
          wait_time=$((RATE_LIMIT_DELAY + retry * 2))
          echo "    ⏳ Rate limit. Esperando ${wait_time}s..."
          sleep "$wait_time"
        fi
      else
        echo "    ❌ Error Groq: $error_msg"
        ((failed++))
        success=false
        break
      fi
    fi
  done
  
  if [ "$success" = true ] && [ -n "$generated" ]; then
    safe_name=$(basename "$file" | sed 's/\.[^.]*$//' | sed 's/[^a-zA-Z0-9._-]/_/g')
    output_dir="$OUTPUT_BASE/$safe_name"
    mkdir -p "$output_dir" || {
      echo "  ❌ No se pudo crear directorio: $output_dir"
      ((failed++))
      continue
    }
    
    # Procesar la salida con awk para dividir archivos
    echo "$generated" | awk -v outdir="$output_dir" '
      BEGIN {
        file_count = 0
        current_file = ""
        content = ""
      }
      /^---ARCHIVO_SEPARATOR---$/ {
        if (current_file != "") {
          filename = outdir "/" file_count "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          close(filename)
          print "    ✓ " filename
        }
        file_count = 0
        current_file = ""
        content = ""
        next
      }
      /^##FILE:/ {
        if (current_file != "") {
          filename = outdir "/" file_count "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          close(filename)
          print "    ✓ " filename
          file_count++
        }
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
          filename = outdir "/" file_count "_" current_file
          gsub(/[^a-zA-Z0-9._\/-]/, "_", filename)
          print content > filename
          close(filename)
          print "    ✓ " filename
        }
      }
    ' || {
      echo "  ❌ Error procesando archivos"
      ((failed++))
      continue
    }
    
    echo "  ✓ Completado"
    ((processed++))
    
    if [ $((processed + failed)) -lt $file_count ]; then
      sleep "$RATE_LIMIT_DELAY"
    fi
  else
    echo "  ❌ No se pudo procesar"
    ((failed++))
  fi
  
  echo ""
  
done <<< "$FILES_TO_MIGRATE"

echo "=== Resumen final ==="
echo "Total archivos procesados: $file_count"
echo "Éxitos: $processed"
echo "Fallos: $failed"
echo ""

if [ -d "migrated" ]; then
  total_files=$(find migrated -type f 2>/dev/null | wc -l)
  echo "$total_files archivos generados:"
  find migrated -type f | head -20 | sed 's/^/  /'
  [ $(find migrated -type f | wc -l) -gt 20 ] && echo "  ... y más"
else
  echo "⚠ No hay archivos migrados"
fi

# Retornar código de error si hubo fallos
[ $failed -eq 0 ] && exit 0 || exit 0  # Permitir que el workflow continúe