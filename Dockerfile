FROM quay.io/jupyter/scipy-notebook:ubuntu-22.04

LABEL maintainer="hara"
LABEL description="Isolated OpenClaw (openclaw.ai) personal AI assistant environment based on Jupyter scipy-notebook (Ubuntu 22.04)"

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    OPENCLAW_HOME=/home/jovyan/.openclaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        python3-dev \
        jq \
        tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mamba install --yes -c conda-forge "nodejs>=24" \
    && mamba clean --all -f -y \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "/home/${NB_USER}" \
    && node --version \
    && npm --version

RUN npm install -g pnpm@latest \
    && npm install -g openclaw@latest \
    && openclaw --version

RUN install -d -o ${NB_UID} -g ${NB_GID} \
        /home/jovyan/.openclaw \
        /home/jovyan/.openclaw/workspace \
        /home/jovyan/.openclaw/credentials \
    && fix-permissions "/home/${NB_USER}"

# Bake the gateway restart helper into the image at a stable path on PATH.
RUN cat > /usr/local/bin/restart-openclaw-gateway.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
LOG_DIR="${OPENCLAW_GATEWAY_LOG_DIR:-${TMPDIR:-/tmp}/openclaw-gateway}"
LOG_FILE="$LOG_DIR/gateway.log"
PID_FILE="$LOG_DIR/gateway.pid"

mkdir -p "$LOG_DIR"

echo "Restarting OpenClaw gateway on ${BIND}:${PORT}..."

if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" || true)"
  if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping previous gateway pid $OLD_PID..."
    kill "$OLD_PID" || true
    for _ in {1..20}; do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Previous gateway did not exit cleanly; killing..."
      kill -9 "$OLD_PID" || true
    fi
  fi
fi

nohup openclaw gateway run --bind "$BIND" --port "$PORT" --force >"$LOG_FILE" 2>&1 &
NEW_PID="$!"
echo "$NEW_PID" > "$PID_FILE"
disown "$NEW_PID" 2>/dev/null || true

echo "Started gateway pid $NEW_PID"
echo "Logs: $LOG_FILE"

for _ in {1..30}; do
  if openclaw gateway health >/dev/null 2>&1; then
    echo "Gateway healthy."
    openclaw gateway status || true
    exit 0
  fi
  sleep 0.5
done

echo "Gateway did not become healthy in time. Recent logs:"
tail -80 "$LOG_FILE" || true
exit 1
SCRIPT
RUN chmod +x /usr/local/bin/restart-openclaw-gateway.sh

# Register a Jupyter pre-start hook so the gateway auto-starts with the notebook server.
RUN mkdir -p /usr/local/bin/before-notebook.d
RUN cat > /usr/local/bin/before-notebook.d/10-openclaw-gateway.sh <<'HOOK'
#!/usr/bin/env bash
# Auto-start the OpenClaw gateway alongside JupyterLab.
# Run as a subprocess so a failure here does not abort start-notebook.sh.
if command -v openclaw >/dev/null 2>&1; then
    /usr/local/bin/restart-openclaw-gateway.sh \
        || echo "[openclaw] gateway failed to start; continuing without it"
else
    echo "[openclaw] CLI not found on PATH; skipping gateway autostart"
fi
HOOK
RUN chmod +x /usr/local/bin/before-notebook.d/10-openclaw-gateway.sh

USER ${NB_UID}

WORKDIR /home/jovyan/work

EXPOSE 8888 18789

CMD ["start-notebook.sh"]
