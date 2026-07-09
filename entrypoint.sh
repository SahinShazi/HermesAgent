#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes
mkdir -p /root/.pi/agent/extensions
mkdir -p /root/.hermes/extensions

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
            
            try:
                payload = json.loads(post_data.decode('utf-8'))
                modified = False
                
                if "max_tokens" in payload and isinstance(payload["max_tokens"], int) and payload["max_tokens"] > 4096:
                    payload["max_tokens"] = 4096
                    modified = True
                    
                if "max_completion_tokens" in payload and isinstance(payload["max_completion_tokens"], int) and payload["max_completion_tokens"] > 4096:
                    payload["max_completion_tokens"] = 4096
                    modified = True

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

# 4. Create the ultimate Python HTTP Reverse Proxy with custom visual dashboard, file manager & backup control
cat <<'EOF' > /root/reverse_proxy.py
import http.server
import urllib.request
import urllib.error
import socketserver
import os
import sys
import json
import subprocess
import shutil
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", 10000))
PASSWORD = "sk-hermes-boss-key"

INDEX_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hermes - Advanced Control Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        .terminal-box { font-family: 'Courier New', monospace; background-color: #05070f; color: #10b981; }
    </style>
</head>
<body class="bg-slate-950 text-slate-100 min-h-screen">
    <!-- LOGIN BOX -->
    <div id="login-container" class="flex items-center justify-center min-h-screen px-4">
        <div class="bg-slate-900 border-t-4 border-blue-500 rounded-xl p-8 max-w-sm w-full shadow-2xl text-center">
            <h2 class="text-2xl font-bold text-white mb-6">🔒 Admin Access Required</h2>
            <input type="password" id="password-input" placeholder="Enter sk-hermes-boss-key..." class="w-full bg-slate-950 border border-slate-700 rounded-lg p-3 text-white font-mono text-center mb-6 focus:outline-none focus:border-blue-500">
            <button onclick="login()" class="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold p-3 rounded-lg transition duration-200">Access Dashboard</button>
        </div>
    </div>

    <!-- MAIN CONTAINER -->
    <div id="main-container" class="max-w-6xl mx-auto px-4 py-8" style="display: none;">
        <header class="flex flex-col md:flex-row md:items-center md:justify-between mb-8 pb-4 border-b border-slate-800">
            <div>
                <h1 class="text-3xl font-extrabold text-white flex items-center gap-2">⚕️ Hermes Boss Panel</h1>
                <p class="text-slate-400 text-sm mt-1">Lightweight, fully responsive server administration interface</p>
            </div>
            <span class="mt-4 md:mt-0 inline-flex items-center gap-2 bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 px-3 py-1.5 rounded-full text-xs font-semibold">
                <span class="w-2 h-2 bg-emerald-400 rounded-full animate-pulse"></span> Active & Online
            </span>
        </header>

        <!-- TABS NAV -->
        <div class="flex border-b border-slate-800 mb-6 overflow-x-auto gap-2">
            <button class="tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200 active text-blue-500 border-blue-500" onclick="switchTab('overview')">Overview</button>
            <button class="tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200" onclick="switchTab('files')">File Manager</button>
            <button class="tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200" onclick="switchTab('backup')">Backup & Sync</button>
            <button class="tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200" onclick="switchTab('terminal')">Terminal</button>
            <button class="tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200" onclick="switchTab('logs')">Live Logs</button>
        </div>

        <!-- OVERVIEW TAB -->
        <div id="overview" class="tab-content block">
            <div class="grid md:grid-cols-2 gap-6">
                <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg">
                    <h2 class="text-lg font-bold text-white mb-4 border-b border-slate-800 pb-2">📊 Server Status</h2>
                    <div class="space-y-3">
                        <div class="flex justify-between text-sm"><span class="text-slate-400">Allowed Telegram ID:</span><span class="font-mono text-white bg-slate-950 px-2 py-0.5 rounded">{ALLOWED_USER_ID}</span></div>
                        <div class="flex justify-between text-sm"><span class="text-slate-400">Active Resources:</span><span class="font-mono text-white bg-slate-950 px-2 py-0.5 rounded" id="system-stats">Loading...</span></div>
                    </div>
                </div>
            </div>
        </div>

        <!-- FILE MANAGER TAB -->
        <div id="files" class="tab-content hidden">
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg">
                <h2 class="text-lg font-bold text-white mb-4 border-b border-slate-800 pb-2">📁 Advanced File Explorer</h2>
                
                <!-- Search & Breadcrumb -->
                <div class="flex flex-col md:flex-row gap-3 mb-6">
                    <input type="text" id="search-input" placeholder="Search files by path or keyword..." class="flex-grow bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm focus:outline-none focus:border-blue-500 animate-fade">
                    <button onclick="searchFiles()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold px-5 py-2.5 rounded-lg text-sm transition duration-200">Search</button>
                </div>
                
                <div class="flex items-center gap-2 mb-4 bg-slate-950 p-2.5 rounded-lg text-xs font-mono text-slate-400 overflow-x-auto">
                    <button onclick="goUpFolder()" class="text-blue-400 hover:underline">↩ [Up]</button>
                    <span id="current-path">/root/.hermes</span>
                </div>

                <!-- Grid/List Folder View -->
                <div id="file-grid" class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3 max-h-[300px] overflow-y-auto mb-6 p-1">
                    <!-- Dynamic Files and Folders go here -->
                </div>

                <!-- Active Editor Box -->
                <div id="editor-container" class="hidden border-t border-slate-800 pt-6 animate-fade">
                    <h3 class="font-bold text-white text-sm mb-2" id="editing-filename">Editing: config.yaml</h3>
                    <textarea id="file-content" rows="12" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm font-mono text-emerald-400 focus:outline-none focus:border-blue-500 mb-4"></textarea>
                    <button id="save-btn" onclick="saveFile()" class="bg-emerald-600 hover:bg-emerald-700 text-white font-bold px-4 py-2.5 rounded-lg text-sm transition duration-200">Save & Restart Gateway</button>
                </div>
            </div>
        </div>

        <!-- BACKUP TAB -->
        <div id="backup" class="tab-content hidden">
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg">
                <h2 class="text-lg font-bold text-white mb-4 border-b border-slate-800 pb-2">☁️ Disaster Recovery & Cloud Sync</h2>
                <p class="text-sm text-slate-400 mb-6">Manually synchronize your active agent session, chat databases, and memories with your private cloud storage or download them directly to your phone.</p>
                
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-6">
                    <!-- Sync button -->
                    <button onclick="syncToSupabase()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold p-4 rounded-xl flex flex-col items-center justify-center gap-2 transition duration-200">
                        <span class="text-2xl">☁️</span>
                        <span>Sync to Supabase Now</span>
                        <span class="text-xs font-normal text-blue-200">Overwrites your cloud backup file</span>
                    </button>
                    
                    <!-- Download button -->
                    <button onclick="downloadBackupZip()" class="bg-amber-600 hover:bg-amber-700 text-white font-bold p-4 rounded-xl flex flex-col items-center justify-center gap-2 transition duration-200">
                        <span class="text-2xl">📥</span>
                        <span>Download Backup Zip</span>
                        <span class="text-xs font-normal text-amber-200">Saves a zip file directly to your device</span>
                    </button>
                </div>
                
                <div class="border-t border-slate-800 pt-6">
                    <h3 class="font-bold text-white text-sm mb-3">🔄 Upload & Restore Backup File</h3>
                    <p class="text-xs text-slate-400 mb-4">Restore your agent from a previously downloaded .zip backup. This will completely replace all current files and database history.</p>
                    <div class="flex flex-col sm:flex-row gap-3">
                        <input type="file" id="backup-file-input" accept=".zip" class="flex-grow bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm focus:outline-none focus:border-blue-500">
                        <button onclick="restoreBackupZip()" class="bg-emerald-600 hover:bg-emerald-700 text-white font-bold px-6 py-2.5 rounded-lg text-sm transition duration-200">Restore Now</button>
                    </div>
                </div>
            </div>
        </div>

        <!-- TERMINAL TAB -->
        <div id="terminal" class="tab-content hidden">
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg">
                <h2 class="text-lg font-bold text-white mb-4 border-b border-slate-800 pb-2">⚡ Bash Command Terminal</h2>
                <div class="terminal-box rounded-lg p-4 h-64 overflow-y-auto text-xs whitespace-pre-wrap mb-4" id="terminal-output">Ready...</div>
                <div class="flex gap-2">
                    <input type="text" id="cmd-input" placeholder="Type bash command (e.g. ls, free -m)..." class="flex-grow bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm focus:outline-none focus:border-blue-500" onkeydown="if(event.key==='Enter') runCommand()">
                    <button onclick="runCommand()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold px-5 py-2.5 rounded-lg text-sm transition duration-200">Execute</button>
                </div>
            </div>
        </div>

        <!-- LOGS TAB -->
        <div id="logs" class="tab-content hidden">
            <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 shadow-lg">
                <h2 class="text-lg font-bold text-white mb-4 border-b border-slate-800 pb-2">📋 Live Gateway Logs</h2>
                <div class="terminal-box rounded-lg p-4 h-96 overflow-y-auto text-xs whitespace-pre-wrap mb-4" id="logs-output">Loading logs...</div>
                <button onclick="loadLogs()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold px-4 py-2.5 rounded-lg text-sm transition duration-200">Refresh Logs</button>
            </div>
        </div>
    </div>

    <script>
        let token = "";
        let currentPath = "/root/.hermes";

        function login() {
            const pwd = document.getElementById("password-input").value;
            fetch("/api/login", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ password: pwd })
            }).then(res => {
                if(res.status === 200) {
                    token = pwd;
                    document.getElementById("login-container").style.display = "none";
                    document.getElementById("main-container").style.display = "block";
                    loadStats();
                    loadFolder(currentPath);
                } else {
                    alert("Invalid Password!");
                }
            });
        }

        function switchTab(tabId) {
            document.querySelectorAll(".tab-btn").forEach(btn => {
                btn.className = "tab-btn py-2.5 px-4 font-bold text-slate-400 hover:text-white border-b-2 border-transparent transition duration-200";
            });
            document.querySelectorAll(".tab-content").forEach(c => {
                c.className = "tab-content hidden";
            });
            
            event.target.className = "tab-btn py-2.5 px-4 font-bold text-blue-500 border-blue-500 border-b-2 transition duration-200";
            document.getElementById(tabId).className = "tab-content block";

            if(tabId === "logs") loadLogs();
            if(tabId === "files") loadFolder(currentPath);
        }

        function loadStats() {
            fetch("/api/stats", { headers: { "Authorization": token } })
            .then(res => res.json())
            .then(data => {
                document.getElementById("system-stats").innerText = data.stats;
            });
        }

        function renderCustomHTMLList(items) {
            let html = "";
            items.forEach(item => {
                const icon = item.is_dir ? "📁" : "📄";
                const onclick_action = item.is_dir ? `changeDirectory('${item.path}')` : `openFileDirectly('${item.path}')`;
                const size_str = item.is_dir ? "" : " (" + (item.size / 1024).toFixed(1) + " KB)";
                
                let dl_btn = "";
                if(!item.is_dir) {
                    const dl_key_url = "/api/files/download?path=" + encodeURIComponent(item.path) + "&token=" + token;
                    dl_btn = `<a href="${dl_key_url}" style="background-color: #1e293b; color: #3b82f6; border: 1px solid #2563eb; padding: 4px 8px; border-radius: 4px; font-size: 11px; text-decoration: none; font-weight: bold;" onclick="event.stopPropagation();">📥 Download</a>`;
                }
                
                html += `
                <div class="bg-slate-950/50 hover:bg-slate-800/50 border border-slate-800 rounded-lg p-3 flex items-center justify-between cursor-pointer transition" onclick="${onclick_action}">
                    <span class="flex items-center gap-2 text-sm truncate font-semibold text-white">
                        ${icon} ${item.name}<span class="text-xs text-slate-500 font-normal">${size_str}</span>
                    </span>
                    ${dl_btn}
                </div>`;
            });
            document.getElementById("file-grid").innerHTML = html || "<div class='text-slate-500 text-sm col-span-full text-center py-4'>Empty Directory</div>";
        }

        function changeDirectory(path) {
            loadFolder(path);
        }

        function goUpFolder() {
            if(currentPath === "/root") return;
            const parts = currentPath.split("/");
            parts.pop();
            const parent = parts.join("/") || "/root";
            loadFolder(parent);
        }

        function searchFiles() {
            const query = document.getElementById("search-input").value;
            if(!query) {
                loadFolder(currentPath);
                return;
            }
            fetch("/api/files/search", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ query: query })
            }).then(res => res.json())
            .then(data => {
                renderCustomHTMLList(data.matches);
            });
        }

        function openFileDirectly(path) {
            fetch("/api/file/read", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ file: path })
            }).then(res => res.json())
            .then(data => {
                document.getElementById("editing-filename").innerText = "Editing: " + path;
                document.getElementById("editing-filename").setAttribute("data-active-path", path);
                document.getElementById("file-content").value = data.content;
                document.getElementById("editor-container").classList.remove("hidden");
                document.getElementById("editor-container").scrollIntoView({ behavior: 'smooth' });
            });
        }

        function saveFile() {
            const file = document.getElementById("editing-filename").getAttribute("data-active-path");
            const content = document.getElementById("file-content").value;
            fetch("/api/file/write", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ file: file, content: content })
            }).then(res => res.json())
            .then(data => {
                if(data.success) {
                    alert("File saved and Gateway restarted successfully!");
                } else {
                    alert("Failed to save file.");
                }
            });
        }

        function loadFolder(path) {
            currentPath = path;
            document.getElementById("current-path").innerText = path;
            
            fetch("/api/files/list", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ path: path })
            }).then(res => res.json())
            .then(data => {
                renderCustomHTMLList(data.items);
            });
        }

        function runCommand() {
            const cmd = document.getElementById("cmd-input").value;
            if(!cmd) return;
            document.getElementById("terminal-output").innerText += "\\n$ " + cmd + "\\nRunning...";
            
            fetch("/api/command", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ command: cmd })
            }).then(res => res.json())
            .then(data => {
                document.getElementById("terminal-output").innerText = data.output;
            });
        }

        function loadLogs() {
            fetch("/api/logs", { headers: { "Authorization": token } })
            .then(res => res.json())
            .then(data => {
                document.getElementById("logs-output").innerText = data.logs;
            });
        }

        function syncToSupabase() {
            if(!confirm("Are you sure you want to push current state to Supabase?")) return;
            fetch("/api/backup/supabase", {
                method: "POST",
                headers: { "Authorization": token }
            }).then(res => res.json())
            .then(data => {
                if(data.success) alert("Successfully synced to Supabase!");
                else alert("Sync failed: " + data.error);
            });
        }

        function downloadBackupZip() {
            window.location.href = "/api/backup/download?token=" + encodeURIComponent(token);
        }

        function restoreBackupZip() {
            const fileInput = document.getElementById("backup-file-input");
            if(fileInput.files.length === 0) {
                alert("Please select a .zip backup file first.");
                return;
            }
            if(!confirm("WARNING: This will completely replace your current bot state and chat history. Proceed?")) return;
            
            const file = fileInput.files[0];
            fetch("/api/backup/restore", {
                method: "POST",
                headers: { "Authorization": token, "Content-Type": "application/octet-stream" },
                body: file
            }).then(res => res.json())
            .then(data => {
                if(data.success) {
                    alert("Backup restored successfully! The gateway is restarting now.");
                    location.reload();
                } else {
                    alert("Restore failed: " + data.error);
                }
            });
        }

        // Reload Stats periodically
        setInterval(() => {
            if(token && document.getElementById("overview").classList.contains("block")) {
                loadStats();
            }
        }, 8000);
    </script>
</body>
</html>
"""

class ReverseProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def handle_request(self, target_url):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else None
        
        headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ['host', 'content-length']:
                headers[k] = v
                
        req = urllib.request.Request(
            target_url,
            data=body,
            headers=headers,
            method=self.command
        )
        
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                self.send_response(response.status)
                hop_by_hop = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailers', 'transfer-encoding', 'upgrade']
                for k, v in response.headers.items():
                    if k.lower() not in hop_by_hop:
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(response.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Proxy error: {e}".encode('utf-8'))

    def do_GET(self):
        parsed_url = urlparse(self.path)
        params = parse_qs(parsed_url.query)
        
        if self.path.startswith("/v1"):
            self.handle_request(f"http://127.0.0.1:8642{self.path}")
        elif parsed_url.path == "/api/files/download":
            token_val = params.get("token", [""])[0]
            if token_val != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            file_path = params.get("path", [""])[0]
            if file_path.startswith("/root") and os.path.isfile(file_path):
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(file_path)}"')
                self.end_headers()
                try:
                    with open(file_path, "rb") as f:
                        self.wfile.write(f.read())
                except Exception as e:
                    self.wfile.write(str(e).encode('utf-8'))
            else:
                self.send_response(404)
                self.end_headers()
        elif parsed_url.path == "/api/backup/download":
            token_val = params.get("token", [""])[0]
            if token_val != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            try:
                # Clean logs and temps before packaging to minimize file size
                for r, d, fs in os.walk('/root/.hermes'):
                    for f in fs:
                        if f.endswith('.log') or f.endswith('.tmp'):
                            try: os.remove(os.path.join(r, f))
                            except: pass
                shutil.make_archive('/tmp/manual_state', 'zip', '/root/.hermes')
                
                self.send_response(200)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Disposition", 'attachment; filename="hermes_state_backup.zip"')
                self.end_headers()
                with open("/tmp/manual_state.zip", "rb") as f:
                    self.wfile.write(f.read())
                try: os.remove("/tmp/manual_state.zip")
                except: pass
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode('utf-8'))
        elif self.path == "/api/stats":
            if self.headers.get("Authorization") != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            try:
                storage = subprocess.check_output("df -h / | tail -1 | awk '{print $4}'", shell=True).decode('utf-8').strip()
                mem = subprocess.check_output("free -m | grep Mem | awk '{print $4}'", shell=True).decode('utf-8').strip()
                uptime = subprocess.check_output("uptime -p", shell=True).decode('utf-8').strip()
                stats_str = f"Free RAM: {mem} MB | Free Storage: {storage} | {uptime}"
            except:
                stats_str = "Memory: OK | Storage: OK"
            self.wfile.write(json.dumps({"stats": stats_str}).encode('utf-8'))
        elif self.path == "/api/logs":
            if self.headers.get("Authorization") != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            log_content = ""
            if os.path.exists("/root/.hermes/gateway.log"):
                try:
                    with open("/root/.hermes/gateway.log", "r") as f:
                        log_content = "".join(f.readlines()[-100:])
                except Exception as e:
                    log_content = f"Error reading logs: {e}"
            else:
                log_content = "Console logs not found."
            self.wfile.write(json.dumps({"logs": log_content}).encode('utf-8'))
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            allowed_user_id = os.environ.get("TELEGRAM_ALLOWED_USERS", "Unknown ID")
            self.wfile.write(INDEX_HTML.replace("{ALLOWED_USER_ID}", allowed_user_id).encode('utf-8'))

    def do_POST(self):
        if self.path.startswith("/v1"):
            self.handle_request(f"http://127.0.0.1:8642{self.path}")
            return
            
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b""

        # Simple endpoint checker to see if payload has JSON
        payload = {}
        if content_length > 0 and self.headers.get("Content-Type", "") == "application/json":
            try: payload = json.loads(post_data.decode('utf-8'))
            except: pass

        if self.path == "/api/login":
            if payload.get("password") == PASSWORD:
                self.send_response(200)
            else:
                self.send_response(401)
            self.end_headers()
            return

        if self.headers.get("Authorization") != PASSWORD:
            self.send_response(401)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        if self.path == "/api/command":
            cmd = payload.get("command")
            try:
                output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, timeout=30).decode('utf-8')
            except Exception as e:
                output = str(e)
            self.wfile.write(json.dumps({"output": output}).encode('utf-8'))

        elif self.path == "/api/files/list":
            path = payload.get("path", "/root/.hermes")
            if not path.startswith("/root"):
                path = "/root"
            items = []
            if os.path.exists(path) and os.path.isdir(path):
                try:
                    for entry in os.scandir(path):
                        items.append({
                            "name": entry.name,
                            "path": entry.path,
                            "is_dir": entry.is_dir(),
                            "size": entry.stat().st_size if entry.is_file() else 0
                        })
                    items.sort(key=lambda x: (not x["is_dir"], x["name"].lower()))
                except Exception as e:
                    print(f"List error: {e}", file=sys.stderr)
            self.wfile.write(json.dumps({"items": items}).encode('utf-8'))

        elif self.path == "/api/files/search":
            query = payload.get("query", "").lower()
            matches = []
            try:
                for root, dirs, files in os.walk("/root"):
                    for file in files:
                        full_path = os.path.join(root, file)
                        if query in file.lower() or query in full_path.lower():
                            matches.append({
                                "name": file,
                                "path": full_path,
                                "is_dir": False,
                                "size": os.path.getsize(full_path)
                            })
                            if len(matches) > 50:
                                break
                    if len(matches) > 50:
                        break
            except Exception as e:
                print(f"Search error: {e}", file=sys.stderr)
            self.wfile.write(json.dumps({"matches": matches}).encode('utf-8'))

        elif self.path == "/api/file/read":
            file_path = payload.get("file")
            content = ""
            if os.path.exists(file_path):
                try:
                    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                        content = f.read()
                except Exception as e:
                    content = f"Error: {e}"
            self.wfile.write(json.dumps({"content": content}).encode('utf-8'))

        elif self.path == "/api/file/write":
            file_path = payload.get("file")
            content = payload.get("content")
            success = False
            try:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(content)
                success = True
                subprocess.Popen("/usr/local/bin/hermes gateway restart", shell=True)
            except Exception as e:
                print(f"File write error: {e}", file=sys.stderr)
            self.wfile.write(json.dumps({"success": success}).encode('utf-8'))

        elif self.path == "/api/backup/supabase":
            try:
                for r, d, fs in os.walk('/root/.hermes'):
                    for f in fs:
                        if f.endswith('.log') or f.endswith('.tmp'):
                            try: os.remove(os.path.join(r, f))
                            except: pass
                shutil.make_archive('/tmp/manual_state', 'zip', '/root/.hermes')
                
                with open('/tmp/manual_state.zip', 'rb') as f:
                    zip_data = f.read()
                
                sub_url = os.environ.get("SUPABASE_URL", "")
                sub_key = os.environ.get("SUPABASE_KEY", "")
                
                req = urllib.request.Request(
                    f"{sub_url}/storage/v1/object/hermes/state.zip",
                    data=zip_data,
                    headers={
                        "apikey": sub_key,
                        "Authorization": f"Bearer {sub_key}",
                        "Content-Type": "application/zip",
                        "x-upsert": "true"
                    },
                    method="POST"
                )
                with urllib.request.urlopen(req, timeout=60) as response:
                    status = response.status
                
                try: os.remove("/tmp/manual_state.zip")
                except: pass
                
                self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            except Exception as e:
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))

        elif self.path == "/api/backup/restore":
            try:
                with open("/tmp/uploaded_state.zip", "wb") as f:
                    f.write(post_data)
                
                # Clear current directory before restore
                for item in os.listdir("/root/.hermes"):
                    item_path = os.path.join("/root/.hermes", item)
                    if os.path.isdir(item_path):
                        shutil.rmtree(item_path)
                    else:
                        os.remove(item_path)
                
                shutil.unpack_archive("/tmp/uploaded_state.zip", "/root/.hermes")
                try: os.remove("/tmp/uploaded_state.zip")
                except: pass
                
                subprocess.Popen("/usr/local/bin/hermes gateway restart", shell=True)
                self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            except Exception as e:
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))

    def do_PUT(self):
        self.do_POST()
    def do_DELETE(self):
        self.do_POST()

def run():
    socketserver.TCPServer.allow_reuse_address = True
    server_address = ('0.0.0.0', PORT)
    httpd = socketserver.TCPServer(server_address, ReverseProxyHandler)
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

# 7. Optimized Background loop (Sleep 4 Hours + Change Detection to save 99% bandwidth)
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

# 9. Start Hermes Gateway internally (Automatically spins up API Server on port 8642, redirects logs to file)
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run > /root/.hermes/gateway.log 2>&1 &

# 10. Start the Custom Status Dashboard in foreground (Handles public port 10000)
python3 /root/reverse_proxy.py