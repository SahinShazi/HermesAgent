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

# 3. Create the custom Python proxy with DYNAMIC Environment Scanning
cat <<'EOF' > /root/proxy.py
import http.server
import urllib.request
import urllib.error
import json
import os
import sys

# Dynamically scan all environment variables starting with "OPENROUTER_API_KEY_"
env_keys = {}
for env_name, env_val in os.environ.items():
    if env_name.startswith("OPENROUTER_API_KEY_"):
        val_clean = env_val.replace("\r", "").strip()
        if val_clean:
            try:
                # Extract index number to sort keys sequentially (e.g. 1, 2, 3...)
                index = int(env_name.replace("OPENROUTER_API_KEY_", ""))
                env_keys[index] = val_clean
            except ValueError:
                # Fallback in case of a non-numeric suffix
                env_keys[env_name] = val_clean

# Sort and compile active keys list
sorted_indices = sorted([k for k in env_keys.keys() if isinstance(k, int)])
active_keys = [env_keys[idx] for idx in sorted_indices]

# Add any non-numeric custom keys if present
for k, v in env_keys.items():
    if not isinstance(k, int):
        active_keys.append(v)

if not active_keys:
    print("Error: No active OpenRouter keys (OPENROUTER_API_KEY_*) found in environment!")
    sys.exit(1)

print(f"Custom Proxy initialized with {len(active_keys)} active OpenRouter keys in pool.")
current_key_index = 0

class OpenRouterProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        global current_key_index
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            for attempt in range(len(active_keys)):
                key_index = (current_key_index + attempt) % len(active_keys)
                api_key = active_keys[key_index]
                
                req = urllib.request.Request(
                    "https://openrouter.ai/api/v1/chat/completions",
                    data=post_data,
                    headers={
                        "Authorization": f"Bearer {api_key}",
                        "Content-Type": "application/json",
                        "HTTP-Referer": "https://github.com/",
                        "X-Title": "Pydroid 3 Bot"
                    },
                    method="POST"
                )
                
                try:
                    with urllib.request.urlopen(req, timeout=60) as response:
                        res_data = response.read()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(res_data)
                        current_key_index = key_index
                        return
                except urllib.error.HTTPError as e:
                    if e.code in [429, 402, 401, 400]:
                        print(f"Key {key_index + 1} got HTTP {e.code}. Failover to next key...")
                        continue
                    else:
                        self.send_response(e.code)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(e.read())
                        return
                except Exception as e:
                    print(f"Key {key_index + 1} connection error: {e}. Trying next...")
                    continue
            
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "All OpenRouter keys failed."}}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            models_data = {"data": [{"id": "openrouter/free", "object": "model"}]}
            self.wfile.write(json.dumps(models_data).encode('utf-8'))
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Proxy Alive")

def run(port=8001):
    server_address = ('127.0.0.1', port)
    httpd = http.server.HTTPServer(server_address, OpenRouterProxyHandler)
    print(f"Starting lightweight proxy on port {port}...")
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 4. Write local environment variables for Hermes
{
  echo "LITELLM_API_KEY=sk-dummy"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env
chmod 600 /root/.hermes/.env

# 5. Create Hermes config.yaml pointing to our local lightweight proxy
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "openrouter/free"
  provider: "local_proxy"

custom_providers:
  - name: local_proxy
    base_url: http://127.0.0.1:8001/v1
    key_env: LITELLM_API_KEY
    api_mode: chat_completions

agent:
  api_max_retries: 2
  retry_backoff_base: 5.0
EOF

# 6. Optimized Background loop (Sleep 4 Hours + Change Detection to save 99% bandwidth)
backup_loop() {
  local last_backed_up_mtime=0
  while true; do
    sleep 14400 # Check and backup every 4 hours instead of 30 seconds
    if [ -d /root/.hermes ] && [ -f /root/.hermes/state.db ]; then
      local current_mtime
      current_mtime=$(stat -c %Y /root/.hermes/state.db 2>/dev/null || echo 0)
      
      # ONLY upload if the database has actually been modified since last backup
      if [ "$current_mtime" -gt "$last_backed_up_mtime" ]; then
        echo "Database modified. Cleaning temp logs and preparing secure backup..."
        # Clean bulky logs and temporary cache files before zipping to reduce size
        python3 -c "import os, shutil; [os.remove(os.path.join(r, f)) for r, d, fs in os.walk('/root/.hermes') for f in fs if f.endswith('.log') or f.endswith('.tmp')]; shutil.make_archive('/tmp/state', 'zip', '/root/.hermes')"
        
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          -H "apikey: ${SUPABASE_KEY}" \
          -H "Authorization: Bearer ${SUPABASE_KEY}" \
          -H "Content-Type: application/zip" \
          -H "x-upsert: true" \
          --data-binary "@/tmp/state.zip" \
          "${SUPABASE_URL}/storage/v1/object/hermes/state.zip")
          
        rm -f /tmp/state.zip
        if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
          last_backed_up_mtime="$current_mtime"
          echo "Optimized backup sync completed successfully."
        fi
      fi
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

# 7. Start the custom lightweight Python proxy in the background
echo "Starting local Python proxy..."
python3 /root/proxy.py &

# 8. Start web server explicitly bound to 0.0.0.0 for Render's external health scanner
PORT="${PORT:-8000}"
python3 -m http.server --bind 0.0.0.0 "$PORT" &

# 9. Start Gateway in foreground (Ensures background jobs survive)
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run