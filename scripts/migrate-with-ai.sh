#!/usr/bin/env bash
set -uo pipefail

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
OUTPUT_BASE="artifacts/${REPO_NAME}/${BRANCH_NAME}"



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
  
  # Extraer nombre base del archivo para usarlo en rutas
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  
  # Construir el prompt CON SUSTITUCIONES REALES
  prompt="Eres un experto DevOps senior. Convierte este archivo a GitHub Actions YAML.

INFORMACIÓN DEL ARCHIVO:
- Nombre: $file
- Nombre base: $base_name
- Tipo: $TYPE

REGLAS CRÍTICAS:
1. Si generas MÚLTIPLES archivos, sepáralos con '---ARCHIVO_SEPARATOR---'
2. ANTES de cada YAML, escribe: '##FILE: ruta/del/archivo.yml'
3. Reemplaza TODAS las variables:
   - \${FILE_NAME} → $base_name
   - \${APP_NAME} → $base_name
   - No dejes \$file, \$FILE_NAME, \$APP_NAME sin reemplazar
4. .groovy en vars/ → .github/actions/$base_name/action.yml (Composite Action)
5. Jenkinsfile → .github/workflows/${base_name}.yml (Reusable Workflow con workflow_call)
6. Cada archivo debe ser YAML válido y COMPLETO
7. Siempre incluye: actions/cache, error handling, retry si aplica
8. NO incluyas explicaciones, SOLO YAML

EJEMPLO DE SALIDA:
##FILE: .github/actions/$base_name/action.yml
name: $base_name
description: Descripción de $base_name
runs:
  using: composite
  steps:
    - name: Step
      run: echo \"Processing $base_name\"

---ARCHIVO_SEPARATOR---

##FILE: .github/workflows/${base_name}-deploy.yml
name: ${base_name}-deploy
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

Contenido a convertir:
$content"

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
    
    # Reemplazar variables en la salida de Groq
    generated="${generated//\$base_name/$base_name}"
    generated="${generated//\${base_name}/$base_name}"
    
    # Procesar la salida con bash en lugar de awk para mejor control
    temp_file=$(mktemp)
    echo "$generated" > "$temp_file"
    
    # Usar bash para procesar línea por línea
    current_file=""
    content=""
    file_count_local=0
    
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "---ARCHIVO_SEPARATOR---" ]; then
        # Guardar archivo anterior
        if [ -n "$current_file" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "  ⚠ No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          echo "    ✓ $current_file"
          ((file_count_local++))
        fi
        current_file=""
        content=""
      elif [[ "$line" =~ ^##FILE:\ * ]]; then
        # Guardar archivo anterior
        if [ -n "$current_file" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "  ⚠ No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          echo "    ✓ $current_file"
          ((file_count_local++))
        fi
        # Extraer nuevo nombre de archivo
        current_file="${line#*##FILE: }"
        current_file="${current_file# }"
        content=""
      else
        # Acumular contenido
        if [ -n "$current_file" ]; then
          content+="$line"$'\n'
        fi
      fi
    done < "$temp_file"
    
    # Guardar último archivo
    if [ -n "$current_file" ]; then
      target_path="$output_dir/$current_file"
      target_dir=$(dirname "$target_path")
      mkdir -p "$target_dir" || {
        echo "  ⚠ No se pudo crear $target_dir"
      }
      echo "$content" > "$target_path"
      echo "    ✓ $current_file"
      ((file_count_local++))
    fi
    
    rm -f "$temp_file"
    
    if [ $file_count_local -gt 0 ]; then
      echo "  ✓ Completado ($file_count_local archivo(s))"
      ((processed++))
    else
      echo "  ⚠ No se generaron archivos"
      ((failed++))
    fi
    
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

ARTIFACT_ROOT="artifacts"


if [ -d "$ARTIFACT_ROOT" ]; then
  total_files=$(find "$ARTIFACT_ROOT" -type f 2>/dev/null | wc -l)
  echo "$total_files archivos generados:"
  find "$ARTIFACT_ROOT" -type f | head -30 | sed 's/^/  /'
else
  echo "⚠ No hay archivos generados"
fi




exit 0