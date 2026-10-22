FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system utilities & Node.js
RUN apt-get update && apt-get install -y --no-install-recommends \
curl \
git \
ffmpeg \
ripgrep \
procps \
&& curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
&& apt-get install -y --no-install-recommends nodejs \
&& rm -rf /var/lib/apt/lists/*

# Install uv globally
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Install hermes launcher
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
ENV PATH="/usr/local/bin:${PATH}"

# Install Telegram extension for Hermes Agent
RUN if [ -f "/usr/local/lib/hermes-agent/venv/bin/python" ]; then \
uv pip install --python /usr/local/lib/hermes-agent/venv/bin/python "hermes-agent[telegram]"; \
elif [ -f "/usr/local/lib/hermes-agent/.venv/bin/python" ]; then \
uv pip install --python /usr/local/lib/hermes-agent/.venv/bin/python "hermes-agent[telegram]"; \
else \
uv pip install --system "hermes-agent[all]"; \
fi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]