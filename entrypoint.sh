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

# 3. Create the custom Python proxy with DYNAMIC Key Scanning & Failover
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
                index = int(env_name.replace("OPENROUTER_API_KEY_", ""))
                env_keys[index] = val_clean
            except ValueError:
                env_keys[env_name] = val_clean

sorted_indices = sorted([k for k in env_keys.keys() if isinstance(k, int)])
active_keys = [env_keys[idx] for idx in sorted_indices]

for k, v in env_keys.items():
    if not isinstance(k, int):
        active_keys.append(v)

if not active_keys:
    print("Error: No active OpenRouter keys (OPENROUTER_API_KEY_*) found in environment!", file=sys.stderr)
    sys.exit(1)

print(f"Custom Proxy initialized with {len(active_keys)} active keys.", file=sys.stderr)
current_key_index = 0

class OpenRouterProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        global current_key_index
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            # Intercept and optimize payload (capping tokens and pruning massive history)
            try:
                payload = json.loads(post_data.decode('utf-8'))
                modified = False
                
                # Cap max_tokens to 4096 (perfectly safe within OpenRouter's limits)
                if "max_tokens" in payload and isinstance(payload["max_tokens"], int) and payload["max_tokens"] > 4096:
                    payload["max_tokens"] = 4096
                    modified = True
                    
                if "max_completion_tokens" in payload and isinstance(payload["max_completion_tokens"], int) and payload["max_completion_tokens"] > 4096:
                    payload["max_completion_tokens"] = 4096
                    modified = True

                # Prune massive chat history to stay safely under limits
                if "messages" in payload and isinstance(payload["messages"], list) and len(payload["messages"]) > 6:
                    system_message = None
                    if payload["messages"][0].get("role") == "system":
                        system_message = payload["messages"][0]
                    
                    last_messages = payload["messages"][-4:]
                    new_messages = []
                    if system_message:
                        new_messages.append(system_message)
                    new_messages.extend(last_messages)
                    payload["messages"] = new_messages
                    modified = True
                    
                if modified:
                    post_data = json.dumps(payload).encode('utf-8')
            except Exception as pe:
                print(f"Payload parsing warning: {pe}", file=sys.stderr)

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
                    err_msg = e.read().decode('utf-8', errors='ignore')
                    print(f"Key {key_index + 1} failed with HTTP {e.code}: {err_msg}", file=sys.stderr)
                    if e.code in [429, 402, 401, 400, 413]:
                        continue
                    else:
                        self.send_response(e.code)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(err_msg.encode('utf-8'))
                        return
                except Exception as e:
                    print(f"Key {key_index + 1} connection error: {e}", file=sys.stderr)
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
    print(f"Starting lightweight proxy on port {port}...", file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 4. Create the ultimate Python HTTP server to serve the Custom Status Dashboard
cat <<'EOF' > /root/reverse_proxy.py
import http.server
import socketserver
import os
import sys

PORT = int(os.environ.get("PORT", 10000))
ALLOWED_USER_ID = os.environ.get("TELEGRAM_ALLOWED_USERS", "Unknown ID")

STATUS_HTML = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hermes Boss Agent Dashboard</title>
    <style>
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #0b0f19;
            color: #f3f4f6;
            margin: 0;
            padding: 40px 20px;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            box-sizing: border-box;
        }}
        .container {{
            max-width: 650px;
            width: 100%;
            background-color: #111827;
            border-radius: 12px;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.5);
            border-top: 5px solid #10b981;
            padding: 35px;
            box-sizing: border-box;
        }}
        h1 {{
            margin: 0 0 10px 0;
            font-size: 26px;
            color: #ffffff;
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .status-badge {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            font-size: 14px;
            background-color: rgba(16, 185, 129, 0.1);
            color: #10b981;
            padding: 6px 14px;
            border-radius: 20px;
            font-weight: 600;
            border: 1px solid rgba(16, 185, 129, 0.2);
            margin-bottom: 25px;
        }}
        .pulse-dot {{
            width: 8px;
            height: 8px;
            background-color: #10b981;
            border-radius: 50%;
            animation: pulse 1.8s infinite;
        }}
        @keyframes pulse {{
            0% {{ transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }}
            70% {{ transform: scale(1); box-shadow: 0 0 0 8px rgba(16, 185, 129, 0); }}
            100% {{ transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }}
        }}
        p {{
            line-height: 1.6;
            color: #9ca3af;
            font-size: 15px;
            margin: 0 0 25px 0;
        }}
        .card {{
            background-color: #1f2937;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 25px;
            border: 1px solid #374151;
        }}
        .card h2 {{
            margin: 0 0 15px 0;
            font-size: 18px;
            color: #ffffff;
            border-bottom: 1px solid #374151;
            padding-bottom: 8px;
        }}
        .info-row {{
            display: flex;
            justify-content: space-between;
            margin-bottom: 12px;
            font-size: 14px;
        }}
        .info-row:last-child {{
            margin-bottom: 0;
        }}
        .label {{
            color: #9ca3af;
            font-weight: 500;
        }}
        .value {{
            color: #e5e7eb;
            font-family: monospace;
            background-color: #111827;
            padding: 2px 8px;
            border-radius: 4px;
            word-break: break-all;
        }}
        .footer {{
            text-align: center;
            font-size: 12px;
            color: #4b5563;
            margin-top: 30px;
            border-top: 1px solid #1f2937;
            padding-top: 15px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>⚕️ Hermes Boss Agent</h1>
        <div class="status-badge">
            <div class="pulse-dot"></div> Live & Healthy
        </div>
        <p>
            Your lightweight, highly optimized autonomous AI agent is running successfully on Render. It is fully connected to Telegram and its database and memories are preserved permanently.
        </p>

        <div class="card">
            <h2>👥 Telegram Configuration</h2>
            <div class="info-row">
                <span class="label">Telegram Platform:</span>
                <span class="value">Active (Long Polling)</span>
            </div>
            <div class="info-row">
                <span class="label">Allowed User ID:</span>
                <span class="value">{ALLOWED_USER_ID}</span>
            </div>
            <div class="info-row">
                <span class="label">Default Model:</span>
                <span class="value">openrouter/free</span>
            </div>
        </div>

        <div class="card">
            <h2>💾 System Status</h2>
            <div class="info-row">
                <span class="label">Load Balancer:</span>
                <span class="value">Dynamic Multi-Key Pool Active</span>
            </div>
            <div class="info-row">
                <span class="label">Supabase Sync:</span>
                <span class="value">Active (Every 4 Hours if modified)</span>
            </div>
            <div class="info-row">
                <span class="label">Local Proxy Port:</span>
                <span class="value">8001</span>
            </div>
        </div>

        <div class="footer">
            Developed and maintained by your custom configuration • © 2026
        </div>
    </div>
</body>
</html>
"""

class StatusDashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(STATUS_HTML.encode('utf-8'))

    def do_POST(self):
        self.send_response(200)
        self.end_headers()

    def do_PUT(self):
        self.do_POST()
    def do_DELETE(self):
        self.do_POST()

def run():
    socketserver.TCPServer.allow_reuse_address = True
    server_address = ('0.0.0.0', PORT)
    httpd = socketserver.TCPServer(server_address, StatusDashboardHandler)
    print(f"Starting lightweight dashboard on port {PORT}...", file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 5. Write local environment variables for Hermes
{
  echo "LITELLM_API_KEY=sk-dummy"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env
chmod 600 /root/.hermes/.env

# 6. Create Hermes config.yaml pointing to our local proxy
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

# 7. Background loop to sync backup to Supabase
backup_loop() {
  local last_backed_up_mtime=0
  while true; do
    sleep 14400 # Backup every 4 hours instead of 30 seconds
    if [ -d /root/.hermes ] && [ -f /root/.hermes/state.db ]; then
      local current_mtime
      current_mtime=$(stat -c %Y /root/.hermes/state.db 2>/dev/null || echo 0)
      
      if [ "$current_mtime" -gt "$last_backed_up_mtime" ]; then
        echo "Database modified. Cleaning logs and syncing secure backup..."
        python3 -c "import os, shutil; [os.remove(os.path.join(r, f)) for r, d, fs in os.walk('/root/.hermes') for f in fs if f.endswith('.log') or f.endswith('.tmp')]; shutil.make_archive('/tmp/state', 'zip', '/root/.hermes')"
        
        HTTP_STATUS=$(curl -s -o /dev/null -X POST \
          -H "apikey: ${SUPABASE_KEY}" \
          -H "Authorization: Bearer ${SUPABASE_KEY}" \
          -H "Content-Type: application/zip" \
          -H "x-upsert: true" \
          --data-binary "@/tmp/state.zip" \
          "${SUPABASE_URL}/storage/v1/object/hermes/state.zip")
          
        rm -f /tmp/state.zip
        if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
          last_backed_up_mtime="$current_mtime"
          echo "Sync complete."
        fi
      fi
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

# 8. Start local Python proxies
echo "Starting local OpenRouter failover proxy..."
python3 /root/proxy.py &

# 9. Start Hermes Gateway internally
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run &

# 10. Start the Custom Status Dashboard in foreground (Handles public port 10000)
python3 /root/reverse_proxy.py