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

# 2. Setup environment variables and cleanup (Supports up to 6 keys)
OPENROUTER_API_KEY_1="${OPENROUTER_API_KEY_1:-}"
OPENROUTER_API_KEY_2="${OPENROUTER_API_KEY_2:-}"
OPENROUTER_API_KEY_3="${OPENROUTER_API_KEY_3:-}"
OPENROUTER_API_KEY_4="${OPENROUTER_API_KEY_4:-}"
OPENROUTER_API_KEY_5="${OPENROUTER_API_KEY_5:-}"
OPENROUTER_API_KEY_6="${OPENROUTER_API_KEY_6:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

export TELEGRAM_BOT_TOKEN="$(clean "$TELEGRAM_BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$TELEGRAM_ALLOWED_USERS")"

export KEY_1="$(clean "$OPENROUTER_API_KEY_1")"
export KEY_2="$(clean "$OPENROUTER_API_KEY_2")"
export KEY_3="$(clean "$OPENROUTER_API_KEY_3")"
export KEY_4="$(clean "$OPENROUTER_API_KEY_4")"
export KEY_5="$(clean "$OPENROUTER_API_KEY_5")"
export KEY_6="$(clean "$OPENROUTER_API_KEY_6")"

# Function to write active key to .env
write_env() {
  local active_key="$1"
  {
    echo "OPENROUTER_API_KEY=${active_key}"
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
  } > /root/.hermes/.env
  chmod 600 /root/.hermes/.env
}

# Helper function to get active key based on Bangladesh time (6 Shifts - 4 hours each)
get_active_key() {
  local hour=$(date +%H)
  local hour_int=$((10#$hour))
  
  if [ $hour_int -ge 6 ] && [ $hour_int -lt 10 ]; then
    echo "${KEY_1}:KEY_1"
  elif [ $hour_int -ge 10 ] && [ $hour_int -lt 14 ]; then
    echo "${KEY_2:-$KEY_1}:KEY_2"
  elif [ $hour_int -ge 14 ] && [ $hour_int -lt 18 ]; then
    echo "${KEY_3:-$KEY_1}:KEY_3"
  elif [ $hour_int -ge 18 ] && [ $hour_int -lt 22 ]; then
    echo "${KEY_4:-$KEY_1}:KEY_4"
  elif [ $hour_int -ge 22 ] || [ $hour_int -lt 2 ]; then
    echo "${KEY_5:-$KEY_1}:KEY_5"
  else
    echo "${KEY_6:-$KEY_1}:KEY_6"
  fi
}

# 3. Determine initial active key
ACTIVE_DETAILS=$(get_active_key)
ACTIVE_KEY="${ACTIVE_DETAILS%%:*}"
ACTIVE_NAME="${ACTIVE_DETAILS##*:}"

write_env "$ACTIVE_KEY"

# 4. Create config.yaml utilizing native OpenRouter Free Models Router
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "openrouter/free"
  provider: "openrouter"

custom_providers:
  - name: openrouter
    base_url: https://openrouter.ai/api/v1
    key_env: OPENROUTER_API_KEY
    api_mode: chat_completions

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

# 6. Background loop to check time and rotate keys (Checks every 5 minutes)
key_rotator_loop() {
  local current_active_name="$1"
  
  while true; do
    sleep 300
    
    local target_details=$(get_active_key)
    local target_key="${target_details%%:*}"
    local target_name="${target_details##*:}"
    
    if [ "$target_name" != "$current_active_name" ]; then
      echo "Time shift detected. Swapping to $target_name key..."
      write_env "$target_key"
      current_active_name="$target_name"
      
      # Restart the gateway gracefully to load new env
      /usr/local/bin/hermes gateway restart || true
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

key_rotator_loop "$ACTIVE_NAME" &

# 7. Start web server explicitly bound to 0.0.0.0 for Render's external health scanner
PORT="${PORT:-8000}"
python3 -m http.server --bind 0.0.0.0 "$PORT" &

# 8. Start Gateway in foreground (Ensures background jobs survive)
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run