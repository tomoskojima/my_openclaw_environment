FROM quay.io/jupyter/scipy-notebook:ubuntu-22.04

LABEL maintainer="hara"
LABEL description="Isolated OpenClaw (openclaw.ai) personal AI assistant environment based on Jupyter scipy-notebook (Ubuntu 22.04)"

ARG OPENCLAW_VERSION=latest

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
    && npm install -g "openclaw@${OPENCLAW_VERSION}" \
    && npm install -g @openai/codex \
    && openclaw --version \
    && codex --version

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

# Bake the discord-plugin version sync helper at a stable path on PATH.
# The @openclaw/discord npm package is auto-installed on first use and can drift
# ahead of the locally pinned CLI between rebuilds (notably on slower ARM builds
# like Raspberry Pi). This script realigns the plugin to whatever CLI is installed.
RUN cat > /usr/local/bin/openclaw-sync-discord-plugin.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
    echo "[openclaw] CLI not found; skipping discord plugin sync"
    exit 0
fi

CLI_VERSION="$(openclaw --version 2>/dev/null | awk '{print $2}')"
if [[ -z "${CLI_VERSION:-}" ]]; then
    echo "[openclaw] could not determine CLI version; skipping discord plugin sync"
    exit 0
fi

PLUGIN_PKG="${OPENCLAW_HOME:-/home/jovyan/.openclaw}/.openclaw/npm/node_modules/@openclaw/discord/package.json"
INSTALLED_VERSION=""
if [[ -f "$PLUGIN_PKG" ]]; then
    INSTALLED_VERSION="$(jq -r .version "$PLUGIN_PKG" 2>/dev/null || true)"
fi

if [[ "$INSTALLED_VERSION" == "$CLI_VERSION" ]]; then
    echo "[openclaw] discord plugin already matches CLI (${CLI_VERSION})"
    exit 0
fi

echo "[openclaw] syncing @openclaw/discord: installed='${INSTALLED_VERSION:-none}' -> cli='${CLI_VERSION}'"
openclaw plugins install "@openclaw/discord@${CLI_VERSION}" --force --pin
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-sync-discord-plugin.sh

# Bake the @openclaw/codex harness plugin sync helper.
# The codex harness is the default agent runner; without this plugin every
# inbound Discord/IM message fails with "Requested agent harness 'codex' is
# not registered." Installed from ClawHub into the persisted state dir.
RUN cat > /usr/local/bin/openclaw-sync-codex-plugin.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
    echo "[openclaw] CLI not found; skipping codex plugin sync"
    exit 0
fi

CLI_VERSION="$(openclaw --version 2>/dev/null | awk '{print $2}')"
if [[ -z "${CLI_VERSION:-}" ]]; then
    echo "[openclaw] could not determine CLI version; skipping codex plugin sync"
    exit 0
fi

PLUGIN_PKG="${OPENCLAW_HOME:-/home/jovyan/.openclaw}/.openclaw/extensions/codex/package.json"
INSTALLED_VERSION=""
if [[ -f "$PLUGIN_PKG" ]]; then
    INSTALLED_VERSION="$(jq -r .version "$PLUGIN_PKG" 2>/dev/null || true)"
fi

if [[ "$INSTALLED_VERSION" == "$CLI_VERSION" ]]; then
    echo "[openclaw] codex plugin already matches CLI (${CLI_VERSION})"
    exit 0
fi

echo "[openclaw] installing @openclaw/codex: installed='${INSTALLED_VERSION:-none}' -> cli='${CLI_VERSION}'"
openclaw plugins install "clawhub:@openclaw/codex" --force --pin
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-sync-codex-plugin.sh

# Bake the env-driven Discord allow-list applier.
# Reads DISCORD_GUILD_ID, DISCORD_CHANNEL_IDS (comma-separated), and optional
# DISCORD_REQUIRE_MENTION, and patches openclaw.json so the bot only replies in
# the listed channels. Safe to re-run: replaces the per-guild "channels" block
# atomically so removed entries actually disappear from the config.
RUN cat > /usr/local/bin/openclaw-apply-discord-allowlist.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

GUILD_ID="${DISCORD_GUILD_ID:-}"
CHANNEL_IDS_RAW="${DISCORD_CHANNEL_IDS:-}"
REQUIRE_MENTION_RAW="${DISCORD_REQUIRE_MENTION:-false}"

if [[ -z "$GUILD_ID" || -z "$CHANNEL_IDS_RAW" ]]; then
    echo "[openclaw] DISCORD_GUILD_ID / DISCORD_CHANNEL_IDS not set; skipping allow-list patch"
    exit 0
fi

if ! command -v openclaw >/dev/null 2>&1; then
    echo "[openclaw] CLI not on PATH; skipping allow-list patch"
    exit 0
fi

CFG_FILE="${OPENCLAW_HOME:-/home/jovyan/.openclaw}/.openclaw/openclaw.json"
if [[ ! -f "$CFG_FILE" ]]; then
    echo "[openclaw] $CFG_FILE not found; run 'openclaw configure' once before using Discord env vars"
    exit 0
fi

case "$(echo "$REQUIRE_MENTION_RAW" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) REQ_MENTION=true ;;
    *) REQ_MENTION=false ;;
esac

CHANNELS_JSON="$(printf '%s\n' "$CHANNEL_IDS_RAW" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' \
    | jq -R . \
    | jq -s --argjson req "$REQ_MENTION" 'map({ (.): { enabled: true, requireMention: $req } }) | add // {}')"

if [[ "$CHANNELS_JSON" == "{}" || -z "$CHANNELS_JSON" ]]; then
    echo "[openclaw] DISCORD_CHANNEL_IDS parsed to empty list; skipping allow-list patch"
    exit 0
fi

PATCH="$(jq -n \
    --arg guild "$GUILD_ID" \
    --argjson channels "$CHANNELS_JSON" \
    '{
        channels: {
            discord: {
                enabled: true,
                groupPolicy: "allowlist",
                token: null,
                accounts: null,
                guilds: { ($guild): { channels: $channels } }
            }
        }
    }')"

echo "[openclaw] applying Discord allow-list: guild=${GUILD_ID} channels=$(echo "$CHANNELS_JSON" | jq -r 'keys|join(",")') requireMention=${REQ_MENTION}"
printf '%s' "$PATCH" | openclaw config patch --stdin --replace-path "channels.discord.guilds.${GUILD_ID}"
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-apply-discord-allowlist.sh

# Bake the workspace-unification helper.
# Points OpenClaw's default agent workspace at the same directory that
# JupyterLab uses (/home/jovyan/work, bind-mounted from host ./work) so files
# created/edited by the agent show up in JupyterLab and vice versa.
# Path is overridable via OPENCLAW_WORKSPACE env var.
RUN cat > /usr/local/bin/openclaw-apply-workspace.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-/home/jovyan/work}"

if ! command -v openclaw >/dev/null 2>&1; then
    echo "[openclaw] CLI not on PATH; skipping workspace patch"
    exit 0
fi

CFG_FILE="${OPENCLAW_HOME:-/home/jovyan/.openclaw}/.openclaw/openclaw.json"
if [[ ! -f "$CFG_FILE" ]]; then
    echo "[openclaw] $CFG_FILE not found; run 'openclaw configure' once before unifying workspace"
    exit 0
fi

if [[ ! -d "$WORKSPACE" ]]; then
    echo "[openclaw] workspace directory $WORKSPACE missing; creating"
    mkdir -p "$WORKSPACE"
fi

CURRENT="$(jq -r '.agents.defaults.workspace // empty' "$CFG_FILE" 2>/dev/null || true)"
if [[ "$CURRENT" == "$WORKSPACE" ]]; then
    echo "[openclaw] agents.defaults.workspace already = $WORKSPACE"
    exit 0
fi

echo "[openclaw] setting agents.defaults.workspace: '${CURRENT:-unset}' -> '$WORKSPACE'"
jq -n --arg ws "$WORKSPACE" '{agents:{defaults:{workspace:$ws}}}' \
    | openclaw config patch --stdin
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-apply-workspace.sh

# Register Jupyter pre-start hooks. Numeric prefixes set execution order:
#   05-  sync discord plugin to CLI version
#   06-  apply env-driven Discord allow-list to openclaw.json
#   10-  start the gateway
RUN mkdir -p /usr/local/bin/before-notebook.d
RUN cat > /usr/local/bin/before-notebook.d/05-openclaw-plugins.sh <<'HOOK'
#!/usr/bin/env bash
# Keep installed openclaw plugins in lockstep with the CLI version.
# When the container runs as root (GRANT_SUDO=yes), ensure plugin files end up
# owned by jovyan so the gateway can load them without "suspicious ownership"
# being flagged on the next plugin scan.
run_as_jovyan() {
    if [[ "$(id -u)" == "0" ]]; then
        chown -R 1000:100 "${OPENCLAW_HOME:-/home/jovyan/.openclaw}" 2>/dev/null || true
        runuser -u jovyan --preserve-environment -- "$@"
    else
        "$@"
    fi
}
run_as_jovyan /usr/local/bin/openclaw-sync-discord-plugin.sh \
    || echo "[openclaw] discord plugin sync failed; continuing"
run_as_jovyan /usr/local/bin/openclaw-sync-codex-plugin.sh \
    || echo "[openclaw] codex plugin sync failed; continuing"
HOOK
RUN chmod +x /usr/local/bin/before-notebook.d/05-openclaw-plugins.sh

RUN cat > /usr/local/bin/before-notebook.d/06-openclaw-discord-config.sh <<'HOOK'
#!/usr/bin/env bash
# Apply the env-driven Discord guild/channel allow-list to openclaw.json
# before starting the gateway. No-op if the env vars are not set.
run_as_jovyan() {
    if [[ "$(id -u)" == "0" ]]; then
        runuser -u jovyan --preserve-environment -- "$@"
    else
        "$@"
    fi
}
run_as_jovyan /usr/local/bin/openclaw-apply-discord-allowlist.sh \
    || echo "[openclaw] discord allow-list apply failed; continuing"
HOOK
RUN chmod +x /usr/local/bin/before-notebook.d/06-openclaw-discord-config.sh

RUN cat > /usr/local/bin/before-notebook.d/07-openclaw-workspace.sh <<'HOOK'
#!/usr/bin/env bash
# Unify the OpenClaw agent workspace with the Jupyter workspace bind mount.
run_as_jovyan() {
    if [[ "$(id -u)" == "0" ]]; then
        runuser -u jovyan --preserve-environment -- "$@"
    else
        "$@"
    fi
}
run_as_jovyan /usr/local/bin/openclaw-apply-workspace.sh \
    || echo "[openclaw] workspace apply failed; continuing"
HOOK
RUN chmod +x /usr/local/bin/before-notebook.d/07-openclaw-workspace.sh

RUN cat > /usr/local/bin/before-notebook.d/10-openclaw-gateway.sh <<'HOOK'
#!/usr/bin/env bash
# Auto-start the OpenClaw gateway alongside JupyterLab.
# Always run the gateway as jovyan to keep state-dir ownership consistent.
run_as_jovyan() {
    if [[ "$(id -u)" == "0" ]]; then
        runuser -u jovyan --preserve-environment -- "$@"
    else
        "$@"
    fi
}
if command -v openclaw >/dev/null 2>&1; then
    run_as_jovyan /usr/local/bin/restart-openclaw-gateway.sh \
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
