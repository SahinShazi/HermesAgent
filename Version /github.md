#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_KEY="${SUPABASE_KEY:-}"

# 1. Restore state from Supabase if credentials exist
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  echo "Checking Supabase backup..."
  HTTP_STATUS=$(curl -s -o /tmp/state.zip -w "%{http_code}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    "${SUPABASE_URL}/storage/v1/object/authenticated/hermes/state.zip")

  if [ "$HTTP_STATUS" -eq 200 ] && [ -f /tmp/state.zip ]; then
    echo "Restoring state..."
    python3 -c "import shutil; shutil.unpack_archive('/tmp/state.zip', '/root/.hermes')"
    rm -f /tmp/state.zip
  else
    echo "No backup found (HTTP ${HTTP_STATUS}). Starting fresh."
    rm -f /tmp/state.zip
  fi
fi

# 2. Setup environment variables and cleanup (Supports GITHUB_TOKEN)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

export TELEGRAM_BOT_TOKEN="$(clean "$TELEGRAM_BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$TELEGRAM_ALLOWED_USERS")"
export GITHUB_TOKEN="$(clean "$GITHUB_TOKEN")"

# 3. Write local environment variables for Hermes
{
  echo "GITHUB_TOKEN=${GITHUB_TOKEN}"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env
chmod 600 /root/.hermes/.env

# 4. Create config.yaml pointing directly to GitHub Models (Azure AI Inference API)
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "gpt-4o"
  provider: "github_models"

custom_providers:
  - name: "github_models"
    base_url: "https://models.inference.ai.azure.com"
    key_env: "GITHUB_TOKEN"
    api_mode: "chat_completions"

agent:
  api_max_retries: 2
  retry_backoff_base: 5.0
EOF

# 5. Background loop to sync backup to Supabase
backup_loop() {
  while true; do
    sleep 30
    if [ -d /root/.hermes ] && [ -f /root/.hermes/state.db ]; then
      python3 -c "import shutil; shutil.make_archive('/tmp/state', 'zip', '/root/.hermes')"
      
      curl -s -o /dev/null -X POST \
        -H "apikey: ${SUPABASE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_KEY}" \
        -H "Content-Type: application/zip" \
        -H "x-upsert: true" \
        --data-binary "@/tmp/state.zip" \
        "${SUPABASE_URL}/storage/v1/object/hermes/state.zip"
        
      rm -f /tmp/state.zip
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

# 6. Start web server explicitly bound to 0.0.0.0 for Render's external health scanner
PORT="${PORT:-8000}"
python3 -m http.server --bind 0.0.0.0 "$PORT" &

# 7. Start Gateway in foreground
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run