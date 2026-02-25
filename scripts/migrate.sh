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
echo "FILES_TO_MIGRATE: $(echo "$FILES_TO_MIGRATE" | wc -l) archivos"
echo "==================="

if [ -z "$GROQ_API_KEY" ]; then
  echo "ERROR: GROQ_API_KEY no está definida"
  exit 1
fi

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "No hay archivos para migrar"
  echo "processed=0" >> $GITHUB_OUTPUT
  echo "failed=0" >> $GITHUB_OUTPUT
  exit 0
fi

SOURCE_REPO_PATH="../source-repo"
OUTPUT_BASE="artifacts/${REPO_NAME}/${BRANCH_NAME}"

mkdir -p "$OUTPUT_BASE" || { echo "ERROR: No se pudo crear $OUTPUT_BASE"; exit 1; }

echo "DEBUG: Verificando rutas:"
echo "  PWD: $(pwd)"
echo "  SOURCE_REPO_PATH existe: $([ -d "$SOURCE_REPO_PATH" ] && echo "SÍ" || echo "NO")"
echo "  OUTPUT_BASE: $OUTPUT_BASE"
ls -la "$SOURCE_REPO_PATH" 2>/dev/null | head -10 || echo "No se puede listar SOURCE_REPO_PATH"
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
  
  # Verificar que el archivo existe con debug extra
  if [ ! -f "$full_path" ]; then
    echo "ERROR: Archivo no encontrado: $full_path"
    echo "DEBUG: Intentando búsqueda: $(find "$SOURCE_REPO_PATH" -name "$(basename "$file")" 2>/dev/null)"
    ((failed++))
    continue
  fi
  
  echo "Archivo encontrado en: $full_path"
  echo "Tamaño: $(du -h "$full_path" | cut -f1)"
  
  # Leer contenido del archivo con límite para prompts grandes
  content=$(cat "$full_path" 2>&1) || {
    echo "ERROR: No se pudo leer el archivo"
    ((failed++))
    continue
  }
  
  # Truncar content si es muy largo para evitar errores de token
  content="${content:0:40000}"  # Reducido para más seguridad
  
  # Extraer nombre base del archivo para usarlo en rutas
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  
  # Construir el prompt CON SUSTITUCIONES REALES y MEJORAS PARA ENFORZAR FORMATO
  prompt="Eres un experto DevOps senior. Convierte este archivo a GitHub Actions YAML.

INFORMACIÓN DEL ARCHIVO:
- Nombre: $file
- Nombre base: $base_name
- Tipo: $TYPE

REGLAS CRÍTICAS (SIGUE EXACTAMENTE):
1. Genera SIEMPRE al menos un archivo YAML válido, incluso si es básico.
2. Si generas MÚLTIPLES archivos, sepáralos con EXACTAMENTE '---ARCHIVO_SEPARATOR---' (sin espacios extra).
3. ANTES de CADA YAML, escribe EXACTAMENTE: '##FILE: ruta/del/archivo.yml' (sin texto adicional).
4. Reemplaza TODAS las variables: \${FILE_NAME} → $base_name, \${APP_NAME} → $base_name. No dejes variables sin reemplazar.
5. Para .groovy en vars/: .github/actions/$base_name/action.yml (Composite Action con inputs/outputs).
6. Para Jenkinsfile: .github/workflows/${base_name}.yml (Reusable con workflow_call, inputs/outputs/secrets).
7. YAML debe ser válido, completo, con best practices: cache, retry, error handling, permissions, concurrency, matrix si aplica, tests, notifications.
8. NO agregues NINGUNA explicación, comentario o texto fuera del formato ##FILE y YAML. SOLO el output estructurado.
9. Si no hay conversión directa, genera un workflow reutilizable básico con steps placeholders.
10. Sigue EL FORMATO EXACTO DEL EJEMPLO. No agregues líneas extras ni code blocks como ```yaml.

EJEMPLO DE SALIDA EXACTO (USA ESTE FORMATO):
##FILE: .github/actions/$base_name/action.yml
name: $base_name Action
description: Acción para $base_name
inputs:
  example:
    required: false
runs:
  using: composite
  steps:
    - run: echo \"Hello\"

---ARCHIVO_SEPARATOR---

##FILE: .github/workflows/${base_name}.yml
name: ${base_name} Workflow
on:
  workflow_call:
jobs:
  job:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

Contenido a convertir (convierte esto):
$content"

  echo "  Enviando a Groq API... (Longitud prompt: ${#prompt})"
  
  max_retries=5
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
        \"messages\": [{\"role\": \"system\", \"content\": \"Sigue las instrucciones EXACTAMENTE. No agregues texto extra, ni introducciones, ni code blocks. Usa el formato preciso con ##FILE y YAML directo.\"}, {\"role\": \"user\", \"content\": $(printf '%s\n' "$prompt" | jq -Rs .)}],
        \"temperature\": 0.0,
        \"max_tokens\": 16384
      }" 2>&1) || {
        echo "Error en curl: $(curl --version)"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry * 2))
        continue
      }
    
    # Separar respuesta del código HTTP
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    echo "    HTTP Code: $http_code"
    echo "    Longitud body: ${#body}"
    
    if [ "$http_code" = "200" ]; then
      generated=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
        echo "Error parseando JSON: $body"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry * 2))
        continue
      }
      
      if [ -n "$generated" ]; then
        success=true
        echo "Respuesta recibida ($(echo "$generated" | wc -c) caracteres)"
        echo "DEBUG: Full generated response:"
        echo "$generated" | head -n 50
        echo "... (truncated if long)"
        break
      else
        echo "Generated vacío"
        ((retry++))
        continue
      fi
    else
      error_msg=$(echo "$body" | jq -r '.error.message // "Error desconocido"' 2>/dev/null)
      error_type=$(echo "$body" | jq -r '.error.type // ""')
      
      echo "Error Groq: $error_msg (type: $error_type)"
      
      if [[ "$error_msg" == *"Rate limit"* ]] || [ "$http_code" = "429" ]; then
        ((retry++))
        if [ $retry -lt $max_retries ]; then
          wait_time=$((RATE_LIMIT_DELAY + retry * 3))
          echo "Rate limit. Esperando ${wait_time}s..."
          sleep "$wait_time"
        fi
      elif [[ "$error_msg" == *"context_length_exceeded"* ]]; then
        echo "Contexto demasiado largo. Truncando content más..."
        content="${content:0:20000}"
        # Reconstruir prompt con content truncado
        prompt="${prompt/Contenido a convertir:$content/Contenido a convertir (truncado):$content}"
        ((retry++))
      else
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
      echo "No se pudo crear directorio: $output_dir"
      ((failed++))
      continue
    }
    
    # Reemplazar variables en la salida de Groq
    generated="${generated//\$base_name/$base_name}"
    generated="${generated//\${base_name}/$base_name}"
    
    # Limpiar generated: remover posibles code blocks y texto extra
    generated=$(echo "$generated" | sed -e '/^##FILE:/!d' -e 's/^```yaml//g' -e 's/^```//g' -e 's/```$//g' -e '/^[^#]/s/^/  /' )  # Asegurar indentación si es necesario
    
    # Procesar la salida con bash mejorado para manejar variaciones
    temp_file=$(mktemp)
    echo "$generated" > "$temp_file"
    
    current_file=""
    content=""
    file_count_local=0
    
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(echo "$line" | sed 's/^\s*//;s/\s*$//;s/^```yaml//;s/^```//;s/```$//')  # Trim y remover code blocks
      if [ "$line" = "---ARCHIVO_SEPARATOR---" ] || [[ "$line" =~ ---ARCHIVO_SEPARATOR--- ]]; then
        if [ -n "$current_file" ] && [ -n "$content" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          # Validar YAML básico con python si yq no está
          if ! command -v yq >/dev/null; then
            python3 -c "import yaml; yaml.safe_load(open('$target_path'))" 2>/dev/null && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
            if [ $? -ne 0 ]; then
              rm "$target_path"
              continue
            fi
          else
            yq e '.' "$target_path" >/dev/null 2>&1 && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
            if [ $? -ne 0 ]; then
              rm "$target_path"
              continue
            fi
          fi
          ((file_count_local++))
        fi
        current_file=""
        content=""
      elif [[ "$line" =~ ^##FILE:\ * ]]; then
        if [ -n "$current_file" ] && [ -n "$content" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          if ! command -v yq >/dev/null; then
            python3 -c "import yaml; yaml.safe_load(open('$target_path'))" 2>/dev/null && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
            if [ $? -ne 0 ]; then
              rm "$target_path"
              continue
            fi
          else
            yq e '.' "$target_path" >/dev/null 2>&1 && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
            if [ $? -ne 0 ]; then
              rm "$target_path"
              continue
            fi
          fi
          ((file_count_local++))
        fi
        current_file="${line#*##FILE: }"
        current_file="${current_file# }"
        content=""
      else
        if [ -n "$current_file" ]; then
          content+="$line"$'\n'
        fi
      fi
    done < "$temp_file"
    
    # Guardar último
    if [ -n "$current_file" ] && [ -n "$content" ]; then
      target_path="$output_dir/$current_file"
      target_dir=$(dirname "$target_path")
      mkdir -p "$target_dir" || {
        echo "No se pudo crear $target_dir"
      }
      echo "$content" > "$target_path"
      if ! command -v yq >/dev/null; then
        python3 -c "import yaml; yaml.safe_load(open('$target_path'))" 2>/dev/null && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
        if [ $? -ne 0 ]; then
          rm "$target_path"
        fi
      else
        yq e '.' "$target_path" >/dev/null 2>&1 && echo "    ✓ $current_file (YAML válido)" || echo "    ⚠ YAML inválido en $current_file - removiendo"
        if [ $? -ne 0 ]; then
          rm "$target_path"
        fi
      fi
      ((file_count_local++))
    fi
    
    rm -f "$temp_file"
    
    # Si no se generó nada, generar un YAML básico por defecto
    if [ $file_count_local -eq 0 ]; then
      echo "No se parsearon archivos de la respuesta. Generando YAML básico por defecto..."
      default_file=".github/workflows/${base_name}.yml"
      target_path="$output_dir/$default_file"
      target_dir=$(dirname "$target_path")
      mkdir -p "$target_dir"
      cat << EOF > "$target_path"
name: ${base_name} Workflow
on:
  workflow_call:
jobs:
  default:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Default Step
        run: echo "Migrated from $file"
EOF
      echo "    ✓ $default_file (generado por defecto)"
      ((file_count_local++))
      ((processed++))
    else
      echo "Completado ($file_count_local archivo(s))"
      ((processed++))
    fi
    
    if [ $((processed + failed)) -lt $file_count ]; then
      sleep "$RATE_LIMIT_DELAY"
    fi
  else
    echo "No se pudo procesar (success: $success, generated length: ${#generated})"
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
  ls -laR "$ARTIFACT_ROOT" | head -20
else
  echo "No hay archivos generados"
fi

# Set GitHub outputs
echo "processed=$processed" >> $GITHUB_OUTPUT
echo "failed=$failed" >> $GITHUB_OUTPUT

exit 0