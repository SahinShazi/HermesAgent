#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes

# ==============================================================================
# ক্রেডেনশিয়াল (Render Environment Variables থেকে আসবে, না পেলে খালি ভ্যালু নেবে)
# ==============================================================================
NARA_KEY="${NARA_API_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

# ক্লিনড ভ্যালুগুলো সরাসরি সিস্টেমে এক্সপোর্ট করা হচ্ছে (নিশ্চিত কার্যকারিতার জন্য)
export NARA_API_KEY="$(clean "$NARA_KEY")"
export TELEGRAM_BOT_TOKEN="$(clean "$BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$ALLOWED_USERS")"

# .env ফাইলে ক্রেডেনশিয়াল রাইট করা হচ্ছে
{
  echo "NARA_API_KEY=${NARA_API_KEY}"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env

chmod 600 /root/.hermes/.env

# NaraRouter কে আপনার লোকাল পাইথন স্ক্রিপ্টের কনফিগারেশন অনুযায়ী এবং সমাধান ১ সহ সেট করা হচ্ছে
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "claude-sonnet-4.5"
  provider: "nara"

custom_providers:
  - name: nara
    base_url: https://router.bynara.id/v1
    key_env: NARA_API_KEY
    api_mode: chat_completions

agent:
  api_max_retries: 6          # রিকোয়েস্ট ফেইল বা লিমিট ওভার হলে মোট ৬ বার পুনরায় চেষ্টা করবে
  retry_backoff_base: 10.0    # প্রথম রিট্রাইয়ের বিরতি ১০ সেকেন্ড এবং পরবর্তীতে তা গুণিতক হারে বাড়বে (Exponential Backoff)
EOF

# রেন্ডার পোর্টের জন্য ডামি এইচটিটিপি সার্ভার ব্যাকগ্রাউন্ডে চালু করা হচ্ছে
PORT="${PORT:-8000}"
echo "Starting dummy HTTP server on port $PORT..."
python3 -m http.server "$PORT" &

# Hermes গেটওয়ে রান করা হচ্ছে
echo "Starting Hermes Gateway..."
exec /usr/local/bin/hermes gateway run