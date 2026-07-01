#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes

# ==============================================================================
# ক্রেডেনশিয়াল (Render Environment Variables থেকে আসবে, না পেলে ডিফল্ট ভ্যালু নেবে)
# ==============================================================================
NARA_KEY="${NARA_API_KEY}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

# .env ফাইলে ক্রেডেনশিয়াল রাইট করা হচ্ছে
{
  echo "NARA_API_KEY=$(clean "$NARA_KEY")"
  echo "TELEGRAM_BOT_TOKEN=$(clean "$BOT_TOKEN")"
  echo "TELEGRAM_ALLOWED_USERS=$(clean "$ALLOWED_USERS")"
} > /root/.hermes/.env

chmod 600 /root/.hermes/.env

# NaraRouter কে কাস্টম প্রোভাইডার হিসেবে সেট করা হচ্ছে
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "claude-haiku-4.5"
  provider: "nara"

custom_providers:
  - name: nara
    base_url: https://router.naraya.ai/v1
    key_env: NARA_API_KEY
    api_mode: chat_completions
EOF

# রেন্ডার পোর্টের জন্য ডামি এইচটিটিপি সার্ভার ব্যাকগ্রাউন্ডে চালু করা হচ্ছে
PORT="${PORT:-8000}"
echo "Starting dummy HTTP server on port $PORT..."
python3 -m http.server "$PORT" &

# Hermes গেটওয়ে রান করা হচ্ছে
echo "Starting Hermes Gateway..."
exec /usr/local/bin/hermes gateway run
