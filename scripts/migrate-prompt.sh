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

# Nuevo: Archivo de log con timestamp
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === DEBUG GROQ ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] GROQ_MODEL: $GROQ_MODEL"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] REPO_NAME: $REPO_NAME"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] BRANCH_NAME: $BRANCH_NAME"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] TYPE: $TYPE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PWD: $(pwd)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] FILES_TO_MIGRATE (crudo): $FILES_TO_MIGRATE"  # Nuevo: Debug de la lista
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ==================="

# Nuevo: Verificar dependencias
dependencies=("curl" "jq" "mktemp")
for dep in "${dependencies[@]}"; do
  if ! command -v "$dep" &> /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $dep no está instalado. Instálalo para continuar (e.g., apt install $dep)."
    exit 1
  fi
done

if [ -z "$GROQ_API_KEY" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: GROQ_API_KEY no está definida"
  exit 1
fi

SOURCE_REPO_PATH="../source-repo"
OUTPUT_BASE="artifacts/${REPO_NAME}/${BRANCH_NAME}"

mkdir -p "$OUTPUT_BASE" || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No se pudo crear $OUTPUT_BASE (verifica permisos)"
  exit 1
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: Verificando rutas:"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   PWD: $(pwd)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   SOURCE_REPO_PATH existe: $([ -d "$SOURCE_REPO_PATH" ] && echo "SÍ" || echo "NO")"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   OUTPUT_BASE: $OUTPUT_BASE"
echo ""

# Nuevo: Auto-detección si $FILES_TO_MIGRATE está vacío
if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ADVERTENCIA: FILES_TO_MIGRATE vacío. Auto-detectando archivos en $SOURCE_REPO_PATH..."
  FILES_TO_MIGRATE=$(find "$SOURCE_REPO_PATH" -type f \( -name "Jenkinsfile*" -o -name "*.groovy" \) -print0 | xargs -0 -I {} basename {} | tr '\n' '\n')  # Busca Jenkinsfiles y .groovy
  if [ -z "$FILES_TO_MIGRATE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No se encontraron archivos para migrar en $SOURCE_REPO_PATH (verifica repo clonado)."
    exit 0
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Archivos auto-detectados:"
  echo "$FILES_TO_MIGRATE"
fi

file_count=$(echo "$FILES_TO_MIGRATE" | wc -l)  # Nuevo: Cuenta real de archivos
processed=0
failed=0

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando procesamiento de $file_count archivos..."
echo ""

while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue
  
  ((file_count_total=$processed + failed + 1))  # Nuevo: Contador dinámico
  file=$(echo "$file" | xargs | sed 's/[^a-zA-Z0-9./-]/_/g')  # Sanitización
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] → [$file_count_total/$file_count] Procesando: $file"
  
  full_path="$SOURCE_REPO_PATH/$file"
  
  if [ ! -f "$full_path" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ⚠ ERROR: Archivo no encontrado: $full_path (verifica clone del repo)"
    ((failed++))
    continue  # Continúa con el siguiente en lugar de fail total
  fi
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ Archivo encontrado"
  
  content=$(cat "$full_path" 2>&1) || {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ❌ ERROR: No se pudo leer $full_path (verifica permisos)"
    ((failed++))
    continue
  }
  
  # Extraer nombre base del archivo para usarlo en rutas
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  
  # Nuevo: Detectar posibles secretos o params para dinamizar prompt
  has_secrets=$(echo "$content" | grep -Ei "password|api_key|token|secret" | wc -l)
  has_params=$(echo "$content" | grep -Ei "Map params|def call" | wc -l)
  extra_rules=""
  if [ $has_secrets -gt 0 ]; then
    extra_rules+="- Detectados posibles secretos: Usa ${{ secrets.NAME }} y sugiere GitHub Secrets en la descripción. Evita hardcoding.\n"
  fi
  if [ $has_params -gt 0 ]; then
    extra_rules+="- Detectados params: Mapea a inputs con type: string, required: true/false, default si aplica.\n"
  fi
  
  # Prompt mejorado para mayor calidad y exactitud (enfocado en shared libs)
  prompt="Eres un experto DevOps senior especializado en migrar shared libraries de Jenkins a GitHub Actions. Convierte este archivo Groovy a YAML reutilizable, enfocándote en exactitud y best practices.

INFORMACIÓN DEL ARCHIVO:
- Nombre: $file
- Nombre base: $base_name
- Tipo: $TYPE (shared library reutilizable en Jenkins)

REGLAS CRÍTICAS PARA EXACTITUD Y CALIDAD:
1. Para .groovy en vars/ o src/ (shared lib): Convierte a Composite Action en .github/actions/$base_name/action.yml.
   - def call(Map params) → inputs: (type: string, required: true/false, default if applies).
   - Lógica interna → steps: usa run: para scripts, uses: para actions estándar (e.g., checkout@v4).
   - Agrega outputs: si la lib retorna valores (e.g., value: ${{ steps.main.outputs.result }}).
   - Incluye description, branding (icon/color) para usabilidad.
2. Para Jenkinsfile principal: Convierte a Reusable Workflow en .github/workflows/$base_name.yml con on: workflow_call.
   - Incluye inputs para params, secrets para creds.
3. Si generas múltiples archivos (e.g., action + workflow caller): Sepáralos con '---ARCHIVO_SEPARATOR---'.
4. ANTES de cada YAML: '##FILE: ruta/del/archivo.yml'.
5. Reemplaza TODAS las variables: \${FILE_NAME} o \$APP_NAME → $base_name; no dejes placeholders.
6. Manejo de secretos: Si hay creds (e.g., keys, passwords), usa ${{ secrets.NAME }}; sugiere GitHub Secrets o Vault integration.
7. Siempre incluye:
   - actions/cache@v4 para caching deps (key: ${{ runner.os }}-${{ hashFiles('pom.xml') }}).
   - Error handling: if: failure() con notify (e.g., slack action) o retry.
   - Retries: Para steps fallibles, usa loop o 'retry-action' (if: failure(), run: retry command).
8. YAML válido, completo, sin explicaciones; optimizado para reutilización (inputs/outputs); NO agregues código extra.
9. Si el archivo tiene lógica condicional o loops, mapea a with/matrix o if en steps.
$extra_rules  # Reglas dinámicas basadas en detección

EJEMPLO PARA SHARED LIB (vars/buildJavaApp.groovy):
##FILE: .github/actions/buildJavaApp/action.yml
name: buildJavaApp
description: Builds Java app with Maven
inputs:
  env:
    description: Environment
    type: string
    required: true
outputs:
  artifact:
    description: Built artifact path
    value: ${{ steps.build.outputs.artifact }}
branding:
  icon: package
  color: green
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
    - name: Cache Maven
      uses: actions/cache@v4
      with:
        path: ~/.m2
        key: ${{ runner.os }}-maven-${{ hashFiles('**/pom.xml') }}
        restore-keys: ${{ runner.os }}-maven-
    - id: build
      run: mvn clean install
      shell: bash
    - if: failure()
      run: echo "Build failed" && exit 1  # O agrega retry loop

Contenido a convertir:
$content"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Enviando a Groq API..."
  
  max_retries=3
  retry=0
  success=false
  generated=""
  
  while [ $retry -lt $max_retries ] && [ "$success" = false ]; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]     [Intento $((retry + 1))/$max_retries]"
    
    response=$(curl -s -w "\n%{http_code}" https://api.groq.com/openai/v1/chat/completions \
      -H "Authorization: Bearer $GROQ_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$GROQ_MODEL\",
        \"messages\": [{\"role\": \"user\", \"content\": $(printf '%s\n' "$prompt" | jq -Rs .)}],
        \"temperature\": 0.1,  # Nuevo: Baja para más determinismo y exactitud
        \"max_tokens\": 20000  # Nuevo: Sube para shared libs complejas
      }" 2>&1) || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]    Error en curl"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry))
        continue
      }
    
    # Separar respuesta del código HTTP
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]     HTTP Code: $http_code"
    
    if [ "$http_code" = "200" ]; then
      generated=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Error parseando JSON"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry))
        continue
      }
      
      if [ -n "$generated" ]; then
        success=true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Respuesta recibida ($(echo "$generated" | wc -c) caracteres)"
        break
      fi
    else
      error_msg=$(echo "$body" | jq -r '.error.message // "Error desconocido"' 2>/dev/null)
      
      if [[ "$error_msg" == *"Rate limit"* ]]; then
        ((retry++))
        if [ $retry -lt $max_retries ]; then
          wait_time=$((RATE_LIMIT_DELAY * (2 ** retry)))  # Nuevo: Backoff exponencial para eficiencia
          echo "[$(date '+%Y-%m-%d %H:%M:%S')]     Rate limit. Esperando ${wait_time}s..."
          sleep "$wait_time"
        fi
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Error Groq: $error_msg"
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
      echo "[$(date '+%Y-%m-%d %H:%M:%S')]   No se pudo crear directorio: $output_dir"
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
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          
          # Nuevo: Validación de YAML generado
          if command -v yamllint &> /dev/null; then
            yamllint -d relaxed "$target_path" || {
              echo "[$(date '+%Y-%m-%d %H:%M:%S')]   YAML inválido en $current_file - Revisar manualmente."
            }
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ADVERTENCIA: yamllint no instalado; no se validó $current_file."
          fi
          
          echo "[$(date '+%Y-%m-%d %H:%M:%S')]     ✓ $current_file"
          ((file_count_local++))
        fi
        current_file=""
        content=""
      elif [[ "$line" =~ ^##FILE:\ * ]]; then
        # Guardar archivo anterior (mismo código que arriba)
        # ...
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
    
    # Guardar último archivo (mismo código que arriba)
    # ...
    
    rm -f "$temp_file"
    
    if [ $file_count_local -gt 0 ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Completado ($file_count_local archivo(s))"
      ((processed++))
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')]   No se generaron archivos"
      ((failed++))
    fi
    
    if [ $((processed + failed)) -lt $file_count ]; then
      sleep "$RATE_LIMIT_DELAY"
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   No se pudo procesar"
    ((failed++))
  fi
  
  echo ""
  
done <<< "$FILES_TO_MIGRATE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Resumen final ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total archivos procesados: $file_count"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Éxitos: $processed"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fallos: $failed"
echo ""

ARTIFACT_ROOT="artifacts"

if [ -d "$ARTIFACT_ROOT" ]; then
  total_files=$(find "$ARTIFACT_ROOT" -type f 2>/dev/null | wc -l)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $total_files archivos generados:"
  find "$ARTIFACT_ROOT" -type f | head -30 | sed 's/^/  /'
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ No hay archivos generados"
fi

exit 0