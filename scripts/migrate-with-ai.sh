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
    echo "ERROR: Archivo no encontrado: $full_path"
    ((failed++))
    continue
  fi
  
  echo "Archivo encontrado"
  
  # Leer contenido del archivo
  content=$(cat "$full_path" 2>&1) || {
    echo "ERROR: No se pudo leer el archivo"
    ((failed++))
    continue
  }
  
  # Extraer nombre base del archivo para usarlo en rutas
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  
  # Construir el prompt CON SUSTITUCIONES REALES y MEJORAS PARA WORKFLOWS DE CALIDAD
  prompt="Eres un experto DevOps senior con 10+ años de experiencia en CI/CD. Convierte este archivo de Jenkins/Groovy a GitHub Actions YAML de alta calidad, siguiendo las mejores prácticas.

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
4. Para archivos .groovy en vars/ o shared libraries: Conviértelos a .github/actions/$base_name/action.yml (Composite Action con inputs, outputs, branding si aplica)
5. Para Jenkinsfile: Conviértelo a .github/workflows/${base_name}.yml (Reusable Workflow con workflow_call, inputs, outputs, secrets)
6. Cada archivo debe ser YAML válido, COMPLETO y listo para usar
7. Siempre incluye:
   - actions/checkout@v4 con persist-credentials: false si no se necesita
   - actions/cache@v4 para caching de dependencias (e.g., node_modules, .m2, pip cache)
   - Error handling: usa 'continue-on-error' donde aplique, o steps con if: failure()
   - Retry: Usa actions/retry@v3 para steps flaky
   - Permissions: Especifica permissions mínimas (e.g., contents: read)
   - Concurrency: Agrega concurrency para evitar runs duplicados
   - Matrix: Usa strategy.matrix para paralelismo si hay builds multi-plataforma o multi-versión
   - Secrets: Maneja secrets con ${{ secrets.MY_SECRET }}
   - Testing: Incluye steps de lint, test, security scans (e.g., actions/setup-node, npm test, codeql)
   - Notifications: Agrega slack/teams notifications en failure si aplica
   - Best practices: Usa runners ubuntu-latest, self-hosted si especificado; optimiza para velocidad; agrega descriptions detalladas
8. Haz los workflows modulares, reutilizables y escalables
9. NO incluyas explicaciones fuera del YAML, SOLO el YAML con headers

EJEMPLO DE SALIDA:
##FILE: .github/actions/$base_name/action.yml
name: $base_name Action
description: Acción compuesta para $base_name - realiza build y test
inputs:
  input1:
    description: 'Entrada ejemplo'
    required: true
outputs:
  output1:
    description: 'Salida ejemplo'
    value: ${{ steps.example.outputs.result }}
runs:
  using: composite
  steps:
    - name: Checkout
      uses: actions/checkout@v4
    - name: Cache dependencies
      uses: actions/cache@v4
      with:
        path: ~/.npm
        key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
    - name: Install
      shell: bash
      run: npm ci
    - name: Run action
      id: example
      shell: bash
      run: echo \"result=done\" >> $GITHUB_OUTPUT

---ARCHIVO_SEPARATOR---

##FILE: .github/workflows/${base_name}.yml
name: ${base_name} Workflow
on:
  workflow_call:
    inputs:
      env:
        type: string
        required: true
    secrets:
      MY_SECRET:
        required: true
    outputs:
      status:
        description: 'Estado del workflow'
        value: ${{ jobs.deploy.outputs.status }}
permissions:
  contents: read
concurrency:
  group: ${{ github.workflow }}-${{ inputs.env }}
  cancel-in-progress: true
jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: [18.x, 20.x]
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: 'npm'
      - run: npm ci
      - run: npm test
  deploy:
    needs: build
    runs-on: ubuntu-latest
    outputs:
      status: success
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        uses: ./.github/actions/$base_name
        with:
          input1: ${{ inputs.env }}
        env:
          SECRET: ${{ secrets.MY_SECRET }}
      - name: Notify on failure
        if: failure()
        uses: slackapi/slack-github-action@v1.26.0
        with:
          payload: '{\"text\": \"Deploy failed!\"}'

Contenido a convertir:
$content"

  echo "  Enviando a Groq API..."
  
  max_retries=5  # Aumentado para más resiliencia
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
        \"temperature\": 0.1,  # Reducido para más precisión
        \"max_tokens\": 16384  # Aumentado para respuestas más complejas
      }" 2>&1) || {
        echo "Error en curl"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry * 2))
        continue
      }
    
    # Separar respuesta del código HTTP
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    echo "    HTTP Code: $http_code"
    
    if [ "$http_code" = "200" ]; then
      generated=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
        echo "Error parseando JSON"
        ((retry++))
        [ $retry -lt $max_retries ] && sleep $((RATE_LIMIT_DELAY + retry * 2))
        continue
      }
      
      if [ -n "$generated" ]; then
        success=true
        echo "Respuesta recibida ($(echo "$generated" | wc -c) caracteres)"
        break
      fi
    else
      error_msg=$(echo "$body" | jq -r '.error.message // "Error desconocido"' 2>/dev/null)
      
      if [[ "$error_msg" == *"Rate limit"* ]]; then
        ((retry++))
        if [ $retry -lt $max_retries ]; then
          wait_time=$((RATE_LIMIT_DELAY + retry * 3))  # Espera exponencial
          echo "Rate limit. Esperando ${wait_time}s..."
          sleep "$wait_time"
        fi
      elif [[ "$error_msg" == *"context_length_exceeded"* ]]; then
        echo "Error: Contexto demasiado largo. Saltando..."
        ((failed++))
        success=false
        break
      else
        echo "Error Groq: $error_msg"
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
    
    # Procesar la salida con bash
    temp_file=$(mktemp)
    echo "$generated" > "$temp_file"
    
    current_file=""
    content=""
    file_count_local=0
    
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "---ARCHIVO_SEPARATOR---" ]; then
        if [ -n "$current_file" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          # Validar YAML básico
          if command -v yq >/dev/null; then
            yq e '.' "$target_path" >/dev/null 2>&1 || echo "    ⚠ YAML inválido en $current_file"
          fi
          echo "    ✓ $current_file"
          ((file_count_local++))
        fi
        current_file=""
        content=""
      elif [[ "$line" =~ ^##FILE:\ * ]]; then
        if [ -n "$current_file" ]; then
          target_path="$output_dir/$current_file"
          target_dir=$(dirname "$target_path")
          mkdir -p "$target_dir" || {
            echo "No se pudo crear $target_dir"
            continue
          }
          echo "$content" > "$target_path"
          if command -v yq >/dev/null; then
            yq e '.' "$target_path" >/dev/null 2>&1 || echo "    ⚠ YAML inválido en $current_file"
          fi
          echo "    ✓ $current_file"
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
    if [ -n "$current_file" ]; then
      target_path="$output_dir/$current_file"
      target_dir=$(dirname "$target_path")
      mkdir -p "$target_dir" || {
        echo "No se pudo crear $target_dir"
      }
      echo "$content" > "$target_path"
      if command -v yq >/dev/null; then
        yq e '.' "$target_path" >/dev/null 2>&1 || echo "    ⚠ YAML inválido en $current_file"
      fi
      echo "    ✓ $current_file"
      ((file_count_local++))
    fi
    
    rm -f "$temp_file"
    
    if [ $file_count_local -gt 0 ]; then
      echo "Completado ($file_count_local archivo(s))"
      ((processed++))
    else
      echo "No se generaron archivos"
      ((failed++))
    fi
    
    if [ $((processed + failed)) -lt $file_count ]; then
      sleep "$RATE_LIMIT_DELAY"
    fi
  else
    echo "No se pudo procesar"
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
  echo "No hay archivos generados"
fi

# Set GitHub outputs
echo "processed=$processed" >> $GITHUB_OUTPUT
echo "failed=$failed" >> $GITHUB_OUTPUT

exit 0
