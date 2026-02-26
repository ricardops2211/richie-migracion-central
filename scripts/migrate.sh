#!/usr/bin/env bash
set -uo pipefail

# Usage: ./script.sh [--dry-run] [--config .env]
DRY_RUN=false
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Opción desconocida: $1"; exit 1 ;;
  esac
done

# Cargar config si existe
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

# Variables con defaults y validación
GROQ_API_KEY="${GROQ_API_KEY:-}"
GROQ_MODEL="${GROQ_MODEL:-llama-3.3-70b-versatile}"
REPO_NAME="${REPO_NAME:-unknown-repo}"
BRANCH_NAME="${BRANCH_NAME:-unknown-branch}"
FILES_TO_MIGRATE="${FILES_TO_MIGRATE:-}"
TYPE="${TYPE:-unknown}"
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-4}"

# Validación estricta
required_vars=("GROQ_API_KEY" "REPO_NAME" "BRANCH_NAME")
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var no está definida"; exit 1
  fi
done

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "Escaneando archivos automáticamente..."
  FILES_TO_MIGRATE=$(find "../source-repo" -name "Jenkinsfile" -o -path "*/vars/*.groovy" -o -name "*.yml" | sed 's|^../source-repo/||')
fi

# Arrays para procesamiento
mapfile -t files < <(echo "$FILES_TO_MIGRATE")

echo "=== DEBUG ==="
echo "GROQ_MODEL: $GROQ_MODEL"
echo "REPO_NAME: $REPO_NAME"
echo "BRANCH_NAME: $BRANCH_NAME"
echo "TYPE: $TYPE"
echo "Archivos: ${#files[@]}"
echo "============="

# Chequeo de dependencias
command -v curl >/dev/null || { echo "ERROR: curl no instalado"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq no instalado"; exit 1; }

SOURCE_REPO_PATH="../source-repo"
OUTPUT_BASE="artifacts/${REPO_NAME}/${BRANCH_NAME}"
mkdir -p "$OUTPUT_BASE" || { echo "ERROR: No se pudo crear $OUTPUT_BASE"; exit 1; }

file_count=${#files[@]}
processed=0
failed=0
summary_log="$OUTPUT_BASE/summary.json"
error_log="$OUTPUT_BASE/errors.log"
> "$error_log"  # Limpiar log de errores

# Función para procesar archivo
process_file() {
  local file="$1"
  file=$(echo "$file" | xargs)
  echo "→ Procesando: $file"

  full_path="$SOURCE_REPO_PATH/$file"
  [ ! -f "$full_path" ] && { echo "ERROR: Archivo no encontrado: $full_path" >> "$error_log"; ((failed++)); return; }

  content=$(cat "$full_path") || { echo "ERROR: Lectura fallida para $file" >> "$error_log"; ((failed++)); return; }

  # Detección de elementos
  libraries=$(grep -oE "@Library\('[^']+'\)" <<< "$content" | tr '\n' ', ')
  secrets=$(grep -oE "(credentials|withCredentials|SECRET|PASSWORD|KEY)" <<< "$content" | sort -u | tr '\n' ', ')
  extra_info=""
  [ -n "$libraries" ] && extra_info+="Detectado @Library: $libraries. Conviértelo a composite actions en .github/actions/. "
  [ -n "$secrets" ] && extra_info+="Detectados secrets: $secrets. Usa \${{ secrets.NAME }} y agrega # TODO: Configura en settings. "

  base_name=$(basename "$file" | sed 's/\.[^.]*$//')

  # Prompt mejorado
  prompt="Eres un experto DevOps. Convierte a GitHub Actions YAML.

INFO: Nombre: $file, Base: $base_name, Tipo: $TYPE
$extra_info

REGLAS:
1. Múltiples archivos: Separa con '---ARCHIVO_SEPARATOR---'
2. Antes de YAML: '##FILE: ruta/archivo.yml'
3. Reemplaza: \${FILE_NAME}/\${APP_NAME} → $base_name
4. .groovy en vars/ → .github/actions/$base_name/action.yml (composite)
5. Jenkinsfile → .github/workflows/$base_name.yml (reusable con workflow_call)
6. Maneja @Library: Crea actions separadas.
7. Secrets: Usa secrets context, agrega TODO.
8. Incluye cache, retries, error handling.
9. Maneja stages/parallel/tools/post.
10. YAML válido y completo. Sin explicaciones. SOLO genera YAML válido para GHA. NO generes archivos Groovy u otros.

Contenido:
$content"

  if $DRY_RUN; then
    echo "  [Dry-run] Prompt: ${prompt:0:100}..."
    generated="##FILE: dummy.yml\nname: test"  # Simulado
  else
    # Llamada a API con mejoras (backoff exponencial, timeout)
    # Nota: Comentario movido aquí para evitar errores en multilínea
    # Authorization masked como Bearer ***
    max_retries=5
    retry=0
    success=false
    while [ $retry -lt $max_retries ] && ! $success; do
      # Preparar body JSON por separado para claridad
      json_body=$(jq -n --arg model "$GROQ_MODEL" --arg content "$(jq -Rs . <<< "$prompt")" \
        '{model: $model, messages: [{role: "user", content: $content}], temperature: 0.1, max_tokens: 20000}')

      response=$(curl -s --max-time 60 -w "\n%{http_code}" \
        https://api.groq.com/openai/v1/chat/completions \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$json_body") || {
        echo "Curl error para $file (retry $retry)" >> "$error_log"; ((retry++)); sleep $(($RATE_LIMIT_DELAY * 2 ** $retry)); continue;
      }

      http_code=$(tail -n1 <<< "$response")
      body=$(head -n-1 <<< "$response")

      if [ "$http_code" = "200" ]; then
        generated=$(jq -r '.choices[0].message.content // empty' <<< "$body")
        [ -n "$generated" ] && success=true
      elif [[ "$http_code" == "429" ]]; then
        echo "Rate limit para $file" >> "$error_log"; ((retry++)); sleep $(($RATE_LIMIT_DELAY * 2 ** $retry))
      else
        echo "Error: $http_code para $file" >> "$error_log"; ((failed++)); return
      fi
    done
    if ! $success; then
      echo "Fallo total en API para $file" >> "$error_log"; ((failed++)); return
    fi
  fi

  if [ -n "$generated" ]; then
    # Reemplazos adicionales
    generated="${generated//\$base_name/$base_name}"

    # Procesar salida
    safe_name=$(echo "$base_name" | sed 's/[^a-zA-Z0-9._-]/_/g')
    output_dir="$OUTPUT_BASE/.github"  # Aplanar: Todo en .github/
    mkdir -p "$output_dir/workflows" "$output_dir/actions"

    temp_file=$(mktemp)
    echo "$generated" > "$temp_file"

    current_file=""
    content=""
    generated_files=()  # Array para trackear y evitar duplicados
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == "---ARCHIVO_SEPARATOR---" ]] || [[ "$line" =~ ^##FILE: ]]; then
        if [ -n "$current_file" ]; then
          # Validación estricta: Solo guarda si parece YAML válido
          if grep -qE "^(name|on|jobs):" <<< "$content"; then
            # Ajusta path para aplanar: e.g., workflows/$safe_name-$current_file si es workflow
            if [[ "$current_file" =~ workflows ]]; then
              target_path="$output_dir/workflows/${safe_name}-${current_file##*/}"
            else
              target_path="$output_dir/actions/${safe_name}-${current_file##*/}"
            fi
            # Evita duplicados
            if [[ ! " ${generated_files[*]} " =~ " ${target_path} " ]]; then
              mkdir -p "$(dirname "$target_path")"
              echo "$content" > "$target_path"
              generated_files+=("$target_path")
              echo "    ✓ ${target_path##$OUTPUT_BASE/}"
            else
              echo "    Skip duplicado: $current_file"
            fi
          else
            echo "Warning: YAML inválido, no guardando $current_file para $file" >> "$error_log"
          fi
        fi
        if [[ "$line" =~ ^##FILE: ]]; then
          current_file="${line#*##FILE: }"
        fi
        content=""
      else
        content+="$line\n"
      fi
    done < "$temp_file"
    # Guardar el último si existe
    if [ -n "$current_file" ]; then
      if grep -qE "^(name|on|jobs):" <<< "$content"; then
        if [[ "$current_file" =~ workflows ]]; then
          target_path="$output_dir/workflows/${safe_name}-${current_file##*/}"
        else
          target_path="$output_dir/actions/${safe_name}-${current_file##*/}"
        fi
        if [[ ! " ${generated_files[*]} " =~ " ${target_path} " ]]; then
          mkdir -p "$(dirname "$target_path")"
          echo "$content" > "$target_path"
          generated_files+=("$target_path")
          echo "    ✓ ${target_path##$OUTPUT_BASE/}"
        else
          echo "    Skip duplicado: $current_file"
        fi
      else
        echo "Warning: YAML inválido, no guardando $current_file para $file" >> "$error_log"
      fi
    fi
    rm "$temp_file"

    if [ ${#generated_files[@]} -gt 0 ]; then
      ((processed++))
      sleep "$RATE_LIMIT_DELAY"  # Pausa solo después de éxito
    else
      echo "No generado para $file" >> "$error_log"
      ((failed++))
    fi
  else
    echo "No generado para $file" >> "$error_log"
    ((failed++))
  fi
}

# Procesamiento secuencial
if [ ${#files[@]} -eq 0 ]; then
  echo "No hay archivos para procesar"
else
  for file in "${files[@]}"; do
    process_file "$file" || echo "Error general en $file" >> "$error_log"
  done
fi

# Resumen
echo "=== Resumen ==="
echo "Total: $file_count | Éxitos: $processed | Fallos: $failed"
if [ -s "$error_log" ]; then
  echo "Errores encontrados, ver $error_log:"
  cat "$error_log"
fi

# Genera JSON
jq -n --arg total "$file_count" --arg success "$processed" --arg fail "$failed" \
  '{total: $total, success: $success, fail: $fail}' > "$summary_log"

# Lista archivos
find "$OUTPUT_BASE" -type f | head -30 | sed 's/^/  /'

exit 0
