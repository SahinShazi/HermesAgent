# 🤖 Hermes Bot — Autonomous Telegram AI Agent

**A self-hosted, self-healing AI agent that lives in your Telegram, powered by Claude Haiku 4.5.**

Built and maintained by **[Sahin Shazi](https://github.com/SahinShazi)**

<p align="left">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.11--slim-3776AB?style=flat-square&logo=python&logoColor=white">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-Container-2496ED?style=flat-square&logo=docker&logoColor=white">
  <img alt="Node.js" src="https://img.shields.io/badge/Node.js-Gateway-339933?style=flat-square&logo=node.js&logoColor=white">
  <img alt="Render" src="https://img.shields.io/badge/Deployed%20on-Render-46E3B7?style=flat-square&logo=render&logoColor=white">
  <img alt="Model" src="https://img.shields.io/badge/Model-Claude%20Haiku%204.5-D97757?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square">
</p>

---

## 📖 Overview

**Hermes Bot** is a production-grade, always-on AI agent that runs entirely on Render's free tier and talks to you through Telegram. Under the hood, it's powered by the [Hermes Agent](https://github.com/NousResearch) framework from Nous Research, routed to **Claude Haiku 4.5** through **NaraRouter**, and engineered to survive the two things that usually kill free-tier bots: **ephemeral storage** and **strict rate limits**.

Instead of losing its memory every time Render spins the container down, Hermes Bot automatically backs itself up to a private Supabase bucket every 30 seconds — and restores itself the moment it wakes back up. No paid database. No lost conversations. No manual intervention.

---

## ✨ Key Features

- 🗨️ **Native Telegram Integration** — Full two-way conversation via long-polling, with an allow-list of authorized user IDs for privacy and access control.
- 🧠 **Claude Haiku 4.5 Intelligence** — Fast, cost-efficient reasoning accessed through NaraRouter's OpenAI-compatible endpoint, configured as a custom Hermes provider.
- 💾 **Zero-Cost Persistent Memory (Supabase Auto-Backup/Restore)** — Solves Render's ephemeral filesystem problem entirely for free:
  - On container **startup**, the agent downloads and restores the latest `.hermes` state archive from a private Supabase Storage bucket.
  - A lightweight background loop **zips and uploads** the local state directory (SQLite DB + Markdown memory files) every 30 seconds using nothing but `shutil` and `curl` — no extra dependencies.
- 🔁 **Rate-Limit Resiliency** — Custom retry logic (`api_max_retries`, `retry_backoff_base`) tuned specifically to gracefully absorb NaraRouter's 10 requests/minute ceiling without dropping messages.
- 🐳 **Single-Container Docker Deployment** — One `Dockerfile`, one `entrypoint.sh`, zero infrastructure headaches.
- 🆓 **100% Free-Tier Stack** — Render (free web service) + Supabase (free storage bucket) + NaraRouter (free model access). No credit card required to run this project.

---

## 🧩 Prerequisites & Requirements

Before deploying, make sure you have the following ready:

### 1. Telegram Bot
- Open Telegram and message **[@BotFather](https://t.me/BotFather)**
- Run `/newbot`, follow the prompts, and save the **Bot Token** it gives you
- Get your numeric Telegram user ID from **[@userinfobot](https://t.me/userinfobot)** — this goes into `TELEGRAM_ALLOWED_USERS` so only you can control the agent

### 2. Supabase Private Storage Bucket
- Create a free project at [supabase.com](https://supabase.com)
- Go to **Storage** → **New Bucket**
- Name it exactly **`hermes`** and set it to **Private**
- From **Project Settings → API**, copy your **Project URL** and **Service Role Key** (needed for read/write access to a private bucket)

### 3. NaraRouter API Key
- Sign up at [router.naraya.ai](https://router.naraya.ai)
- Generate an API key from your dashboard
- Confirm `claude-haiku-4.5` (or your chosen model) is available on your plan/tier

### 4. Accounts
- A [GitHub](https://github.com) account (to host this repo)
- A [Render](https://render.com) account (free tier is sufficient)

---

## 🔐 Environment Variables

Set these under **Render → Your Service → Environment** (never commit them directly to a public repo):

| Variable | Description | Example |
|---|---|---|
| `NARA_API_KEY` | API key for NaraRouter, used to access Claude Haiku 4.5 | `sk-nara-xxxxxxxxxxxx` |
| `TELEGRAM_BOT_TOKEN` | Token issued by BotFather for your bot | `123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated Telegram user ID(s) allowed to use the bot | `7215592040` |
| `SUPABASE_URL` | Your Supabase project URL | `https://xxxxxxxxxxxx.supabase.co` |
| `SUPABASE_KEY` | Supabase service role key (private bucket read/write access) | `eyJhbGciOi...` |

---

## 🚀 Deployment on Render (Step-by-Step)

### Step 1 — Push to GitHub
```bash
git init
git add .
git commit -m "Initial commit: Hermes Bot"
git branch -M main
git remote add origin https://github.com/SahinShazi/hermes-bot.git
git push -u origin main
```

### Step 2 — Create a New Web Service on Render
1. Log in to [Render Dashboard](https://dashboard.render.com)
2. Click **New +** → **Web Service**
3. Connect your GitHub account and select this repository
4. Render will auto-detect the `Dockerfile` — choose **Docker** as the environment

### Step 3 — Configure the Service
| Setting | Value |
|---|---|
| **Name** | `hermes-bot` (or your preferred name) |
| **Region** | Closest to you |
| **Branch** | `main` |
| **Runtime** | Docker |
| **Instance Type** | Free |

### Step 4 — Add Environment Variables
In the **Environment** tab, add all five variables listed in the [Environment Variables](#-environment-variables) section above.

### Step 5 — Set the Port
Render requires an open HTTP port to detect a healthy service on the free tier. This project starts a lightweight dummy HTTP server automatically — Render will inject the `PORT` variable and the app binds to it automatically. No manual port configuration is required.

### Step 6 — Deploy
Click **Create Web Service**. Render will build the Docker image and deploy it. Watch the **Logs** tab for:
```
┌─────────────────────────────────────────────────────────┐
│           ⚕ Hermes Gateway Starting...                 │
├─────────────────────────────────────────────────────────┤
│  Messaging platforms + cron scheduler                    │
└─────────────────────────────────────────────────────────┘
```
Once you see this, open Telegram and message your bot. 🎉

> 💡 **Tip:** Render's free tier spins down idle services. The first message after inactivity may take 30–60 seconds to respond as the container restores its state from Supabase — this is expected behavior.

---

## 📁 Directory Structure

```
hermes-bot/
├── Dockerfile              # Defines the container: Python 3.11-slim + Node.js + Hermes Agent
├── entrypoint.sh           # Boot sequence: restore state, write config, start backup loop, launch gateway
├── backup/
│   ├── restore.sh          # Downloads latest .hermes state archive from Supabase on startup
│   └── backup_loop.sh      # Zips and uploads .hermes/ to Supabase every 30 seconds
├── .hermes/                # (Runtime-generated, not committed)
│   ├── .env                # Injected credentials (Nara, Telegram, Supabase)
│   ├── config.yaml          # Hermes provider + retry configuration
│   ├── state.db             # SQLite database — conversation/agent state
│   └── memory/               # Markdown-based long-term memory files
├── .gitignore
├── LICENSE
└── README.md
```

---

## ⚙️ How the Persistence Layer Works

```
┌──────────────────┐        restore on boot        ┌────────────────────┐
│  Supabase Bucket │ ─────────────────────────────▶ │   Render Container │
│   ("hermes")     │                                │   /root/.hermes/   │
│                  │ ◀───────────────────────────── │                    │
└──────────────────┘     upload every 30 seconds    └────────────────────┘
```

1. **On startup:** `restore.sh` pulls the most recent backup archive from the private Supabase bucket and extracts it into `/root/.hermes/`.
2. **While running:** a background loop zips the entire `.hermes/` directory and uploads it via `curl` to Supabase every 30 seconds, overwriting the previous backup.
3. **On restart/redeploy:** even though Render wipes the container's disk, the next boot cycle simply restores from Supabase — so conversations, memory, and state survive indefinitely at zero additional cost.

---

## 🛡️ Rate-Limit Handling

NaraRouter's free tier enforces a **10 requests/minute** cap. Rather than failing on the first `429`, Hermes is configured to retry patiently:

```yaml
api_max_retries: 6
retry_backoff_base: 10.0
```

This gives the agent up to 6 retry attempts with exponential backoff starting at 10 seconds — smoothing over rate-limit spikes without dropping user messages or throwing errors mid-conversation.

---

## 📄 License

This project is licensed under the **MIT License** — free to use, modify, and distribute, with attribution appreciated.

```
MIT License

Copyright (c) 2026 Sahin Shazi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
```

---

<p align="center">
  Built with ☕ and persistence by <strong>Sahin Shazi</strong><br>
  <a href="https://sahinenam.com">sahinenam.com</a> · <a href="https://github.com/SahinShazi">GitHub</a>
</p>
