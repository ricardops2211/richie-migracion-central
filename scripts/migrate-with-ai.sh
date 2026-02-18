#!/usr/bin/env bash
set -euo pipefail

# Variables requeridas desde el workflow
GROQ_API_KEY="");
GROQ_MODEL="deepseek-coder-v2-lite";
REPO_NAME="unknown-repo";
BRANCH_NAME="unknown-branch";
FILES_TO_MIGRATE="";
TYPE="unknown";

# Depuración inicial
echo "=== DEBUG GROQ ===";
echo "GROQ_MODEL: $GROQ_MODEL";
echo "REPO_NAME: $REPO_NAME";
echo "BRANCH_NAME: $BRANCH_NAME";
echo "FILES_TO_MIGRATE: $FILES_TO_MIGRATE";
echo "TYPE: $TYPE";
echo "PWD: $(pwd)";
echo "===================";

if [ -z "$GROQ_API_KEY" ]; then
  echo "ERROR: GROQ_API_KEY no está definida";
  exit 1;
fi

if [ -z "$FILES_TO_MIGRATE" ]; then
  echo "No hay archivos para migrar";
  exit 0;
fi

# Verificar que source-repo existe
if [ ! -d "source-repo" ]; then
  echo "ERROR: Directorio source-repo no existe";
  ls -la;
  exit 1;
fi

OUTPUT_BASE="migrated/${REPO_NAME}/${BRANCH_NAME}";
mkdir -p "$OUTPUT_BASE";

for file in $FILES_TO_MIGRATE; do
  # Limpiar rutas: remover ./ del principio
  clean_file="${file#./}";
  rel_path="$clean_file";
  
echo "→ Procesando: $rel_path";
  
  # Construir ruta completa
  full_path="source-repo/$clean_file";
  
  # Verificar que el archivo existe
  if [ ! -f "$full_path" ]; then
    echo "  ⚠️  Archivo no encontrado: $full_path";
    
    # Crear directorio para el error si no existe
    error_dir=$(dirname "$OUTPUT_BASE/error-$rel_path.json");
    mkdir -p "$error_dir";
    
echo "{\"error\": \"archivo_no_encontrado\", \"path\": \"$rel_path\"}" > "$OUTPUT_BASE/error-$rel_path.json";
    continue;
  fi
  
echo "  ✓ Leyendo archivo: $full_path";
  
  # Leer contenido del archivo
  content=$(cat "$full_path" | jq -Rsa . 2>/dev/null || echo \"Error leyendo archivo\");
  
  # Construir el prompt (escapar variables bash dentro del aquí documento)
prompt="Eres un experto DevOps senior. Convierte este archivo ($rel_path, tipo $TYPE) a GitHub Actions YAML robusto y moderno.

Reglas estrictas:
- .groovy en vars/ → Composite Action (.github/actions/nombre/action.yml)
- src/ (Groovy/Java-like) → lógica en steps run: bash o java
- Jenkinsfile → Reusable Workflow con workflow_call
- Siempre añade: actions/cache, error handling (continue-on-error, retry), matrix si aplica
- Genera YAMLs separados por --- si hay múltiples
- Devuelve SOLO código YAML, sin explicaciones

Contenido del archivo:
$content";

  echo "  → Llamando a Groq API...";
  
  response=$(curl -s https://api.groq.com/openai/v1/chat/completions \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "model": "$GROQ_MODEL",
  "messages": [
    {
      "role": "user",
      "content": $(echo "$prompt" | jq -Rsa .)
    }
  ],
  "temperature": 0.2,
  "max_tokens": 12000
}
EOF
  )

  # Extraer el contenido generado
generated=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true);

  if [ -z "$generated" ]; then
    echo "  ✗ ERROR: Groq no devolvió respuesta válida";
    
    # Crear directorio para el error si no existe
    error_dir=$(dirname "$OUTPUT_BASE/error-$rel_path.json");
    mkdir -p "$error_dir";
    
echo "$response" > "$OUTPUT_BASE/error-$rel_path.json";
    continue;
  fi

  echo "  ✓ Respuesta recibida de Groq";

  # Crear nombre seguro para el archivo (sin extensión original)
safe_name=$(echo "$rel_path" | sed 's/[^a-zA-Z0-9._/-]/_/g' | sed 's/__/_/g' | sed 's/\.[^.]*$//');
  output_dir="$OUTPUT_BASE/$safe_name";
  mkdir -p "$output_dir";

  # Dividir si hay múltiples YAMLs separados por ---
echo "$generated" > "$output_dir/temp_combined.yml";
  
  # Usar awk para dividir por ---
  awk '
    /^---$/ && NR > 1 { 
      close(filename); 
      counter++; 
      filename = "'$output_dir'/generated_" counter ".yml"
      next
    }
    {
      if (!filename) filename = "'$output_dir'/generated_1.yml"
      print > filename
    }
  ' "$output_dir/temp_combined.yml";
  
  rm -f "$output_dir/temp_combined.yml";

  # Verificar y reportar archivos generados
generated_count=$(ls "$output_dir"/generated_*.yml 2>/dev/null | wc -l || echo 0);
echo "  ✓ Generados $generated_count archivo(s) YAML";

done

echo ""
echo "=== MIGRACIÓN FINALIZADA ===";
echo "Estructura generada:";
ls -R migrated/ 2>/dev/null || echo "No hay archivos migrados";