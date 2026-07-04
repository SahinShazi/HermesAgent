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
export TELEGRAM_ALLOWED_USERS="$(clean "$ALLOWED_USERS")"

export KEY_1="$(clean "$OPENROUTER_API_KEY_1")"
export KEY_2="$(clean "$OPENROUTER_API_KEY_2")"
export KEY_3="$(clean "$OPENROUTER_API_KEY_3")"
export KEY_4="$(clean "$OPENROUTER_API_KEY_4")"
export KEY_5="$(clean "$OPENROUTER_API_KEY_5")"
export KEY_6="$(clean "$OPENROUTER_API_KEY_6")"

# 3. Dynamically install LiteLLM with proxy dependencies if not present
if ! python3 -c "import litellm.proxy" &> /dev/null; then
echo "Installing LiteLLM proxy and dependencies..."
if command -v uv &> /dev/null; then
uv pip install --system "litellm[proxy]" || pip install "litellm[proxy]"
else
pip install "litellm[proxy]"
fi
fi

# 4. Generate LiteLLM configuration file with custom headers matching your test script
cat <<EOF> /root/litellm_config.yaml
  model_list:
  EOF
  
  add_key_to_litellm() {
  local key="$1"
  if [ -n "$key" ]; then
  cat <<EOF>> /root/litellm_config.yaml
    - model_name: "openrouter/free"
    litellm_params:
    model: "openai/openrouter/free"
    api_base: "https://openrouter.ai/api/v1"
    api_key: "${key}"
    custom_headers:
    HTTP-Referer: "https://github.com/"
    X-Title: "Pydroid 3 Bot"
    EOF
    fi
    }
    
    add_key_to_litellm "$KEY_1"
    add_key_to_litellm "$KEY_2"
    add_key_to_litellm "$KEY_3"
    add_key_to_litellm "$KEY_4"
    add_key_to_litellm "$KEY_5"
    add_key_to_litellm "$KEY_6"
    
    cat <<EOF>> /root/litellm_config.yaml
      router_settings:
      routing_strategy: "simple-shuffle"
      num_retries: 5
      EOF
      
      # 5. Write local environment variables for Hermes
      {
      echo "LITELLM_API_KEY=sk-dummy"
      echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
      echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
      } > /root/.hermes/.env
      chmod 600 /root/.hermes/.env
      
      # 6. Create Hermes config.yaml pointing to the local LiteLLM proxy
      cat <<EOF> /root/.hermes/config.yaml
        model:
        default: "openrouter/free"
        provider: "litellm_proxy"
        
        custom_providers:
        - name: litellm_proxy
        base_url: http://127.0.0.1:8001/v1
        key_env: LITELLM_API_KEY
        api_mode: chat_completions
        
        agent:
        api_max_retries: 2
        retry_backoff_base: 5.0
        EOF
        
        # 7. Background loop to sync backup to Supabase
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
        
        # 8. Start LiteLLM proxy on local port 8001 (Highly Optimized for RAM usage)
        echo "Starting LiteLLM proxy..."
        export LITELLM_TELEMETRY=False
        export DISABLE_LITELLM_TELEMETRY=True
        litellm --config /root/litellm_config.yaml --port 8001 --host 127.0.0.1 --num_workers 1 &
        
        # 9. Start web server explicitly bound to 0.0.0.0 for Render's external health scanner
        PORT="${PORT:-8000}"
        python3 -m http.server --bind 0.0.0.0 "$PORT" &
        
        # 10. Start Gateway in foreground (Ensures background jobs survive)
        echo "Starting Hermes Gateway..."
        /usr/local/bin/hermes gateway run