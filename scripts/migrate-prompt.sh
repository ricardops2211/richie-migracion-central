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

# Archivo de log con timestamp
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === DEBUG GROQ ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] GROQ_MODEL: $GROQ_MODEL"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] REPO_NAME: $REPO_NAME"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] BRANCH_NAME: $BRANCH_NAME"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] TYPE: $TYPE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PWD: $(pwd)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ==================="

# Verificar dependencias
dependencies=("curl" "jq" "mktemp" "find" "ls")  # Agregado find y ls para auto-detección
for dep in "${dependencies[@]}"; do
  if ! command -v "$dep" &> /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $dep no está instalado. Instálalo para continuar."
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
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Contenido de SOURCE_REPO_PATH (para debug):"
ls -la "$SOURCE_REPO_PATH" 2>/dev/null || echo "   No se pudo listar (dir vacío o no existe)"
echo ""

# Nuevo: Auto-detección si $FILES_TO_MIGRATE vacío
if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ADVERTENCIA: FILES_TO_MIGRATE vacío. Auto-detectando archivos en $SOURCE_REPO_PATH..."
  FILES_TO_MIGRATE=$(find "$SOURCE_REPO_PATH" -type f \( -name "Jenkinsfile*" -o -name "*.groovy" \) -printf "%P\n" 2>/dev/null)
  if [ -z "$FILES_TO_MIGRATE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No se encontraron archivos *.groovy o Jenkinsfile* en $SOURCE_REPO_PATH. Verifica si el repo se clonó correctamente (e.g., git clone falló)."
    exit 1
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Archivos auto-detectados ($(echo "$FILES_TO_MIGRATE" | wc -l)):"
  echo "$FILES_TO_MIGRATE" | nl
fi

file_count=$(echo "$FILES_TO_MIGRATE" | wc -l | tr -d ' ')
processed=0
failed=0

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando procesamiento de $file_count archivos..."
echo ""

while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue
  
  file_count_total=$((processed + failed + 1))
  file=$(echo "$file" | xargs | sed 's/[^a-zA-Z0-9./-]/_/g')
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] → [$file_count_total/$file_count] Procesando: $file"
  
  full_path="$SOURCE_REPO_PATH/$file"
  
  if [ ! -f "$full_path" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ⚠ ERROR: Archivo no encontrado: $full_path. Listando contenido de $SOURCE_REPO_PATH para debug:"
    ls -la "$SOURCE_REPO_PATH"
    ((failed++))
    continue
  fi
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ Archivo encontrado"
  
  content=$(cat "$full_path" 2>&1) || {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ❌ ERROR: No se pudo leer $full_path (verifica permisos)"
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