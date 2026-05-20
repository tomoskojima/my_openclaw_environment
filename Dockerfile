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
        v4l-utils \
        ffmpeg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN /opt/conda/bin/pip install --no-cache-dir opencv-python-headless

# Put jovyan in the host's "video" group inside /etc/group so any subprocess
# that drops privileges via sudo/su (e.g. the codex harness sandbox) still
# inherits permission to read /dev/video*. The docker-compose `group_add: 44`
# only affects the container's initial process; supplementary groups are reset
# on user switch unless the group membership is recorded in /etc/group itself.
# (Debian/Ubuntu/Raspberry Pi OS all ship the "video" group with GID 44.)
RUN usermod -aG video ${NB_USER}

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

# Bake the "openclaw-camera" tool plugin source into the image. Installed via
# `openclaw plugins install --link` by the 08- pre-start hook.
RUN install -d /opt/openclaw-plugins/openclaw-camera

RUN cat > /opt/openclaw-plugins/openclaw-camera/openclaw.plugin.json <<'JSON'
{
  "id": "openclaw-camera",
  "name": "OpenClaw Camera",
  "description": "Capture a still frame from the host camera (V4L2 / ffmpeg). The image is saved into the shared workspace and the path is returned to the agent so vision-capable models can read it.",
  "version": "0.1.0",
  "activation": { "onStartup": true },
  "contracts": { "tools": ["capture_camera_frame"] },
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
JSON

RUN cat > /opt/openclaw-plugins/openclaw-camera/package.json <<'JSON'
{
  "name": "openclaw-plugin-camera",
  "version": "0.1.0",
  "type": "module",
  "private": true,
  "main": "./index.js",
  "files": ["index.js", "openclaw.plugin.json"],
  "peerDependencies": {
    "openclaw": ">=2026.5.0"
  },
  "openclaw": {
    "extensions": ["./index.js"]
  }
}
JSON

RUN cat > /opt/openclaw-plugins/openclaw-camera/index.js <<'JS'
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { Type } from "typebox";
import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";

const DEFAULT_WORKSPACE = process.env.OPENCLAW_WORKSPACE || "/home/jovyan/work";

function runFfmpeg(device, size, outPath) {
  return new Promise((resolve, reject) => {
    const args = [
      "-nostdin", "-hide_banner", "-loglevel", "error",
      "-f", "v4l2", "-video_size", size, "-i", device,
      "-frames", "1", "-y", outPath,
    ];
    const proc = spawn("ffmpeg", args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    proc.stderr.on("data", (d) => { stderr += d.toString(); });
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg failed (exit ${code}): ${stderr.trim()}`));
    });
    proc.on("error", reject);
  });
}

export default defineToolPlugin({
  id: "openclaw-camera",
  name: "OpenClaw Camera",
  description: "Capture a still frame from the host camera via ffmpeg.",
  tools: (tool) => [
    tool({
      name: "capture_camera_frame",
      description:
        "Capture one frame from the host webcam (V4L2) and save it into the workspace. " +
        "Returns the absolute and workspace-relative path; vision-capable models can then read the image.",
      parameters: Type.Object({
        filename: Type.Optional(
          Type.String({
            description:
              "Output file name inside the workspace. Default: camera_<ISO timestamp>.jpg.",
          }),
        ),
        device: Type.Optional(
          Type.String({ description: "V4L2 device path. Default: /dev/video0." }),
        ),
        resolution: Type.Optional(
          Type.String({
            description: "Resolution like 640x480 or 1280x720. Default: 640x480.",
          }),
        ),
      }),
      execute: async ({ filename, device, resolution }) => {
        const dev = device ?? "/dev/video0";
        const size = resolution ?? "640x480";
        const fname =
          filename ?? `camera_${new Date().toISOString().replace(/[:.]/g, "-")}.jpg`;
        const outPath = path.isAbsolute(fname)
          ? fname
          : path.join(DEFAULT_WORKSPACE, fname);
        await fs.mkdir(path.dirname(outPath), { recursive: true });
        await runFfmpeg(dev, size, outPath);
        const stat = await fs.stat(outPath);
        return {
          path: outPath,
          relative: path.relative(DEFAULT_WORKSPACE, outPath),
          bytes: stat.size,
          device: dev,
          resolution: size,
        };
      },
    }),
  ],
});
JS

# Ensure the plugin source tree is readable to jovyan (heredocs ran as root).
RUN chown -R ${NB_UID}:${NB_GID} /opt/openclaw-plugins

# Installer hook: links the baked plugin into openclaw on every container start.
RUN cat > /usr/local/bin/openclaw-install-camera-plugin.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_SRC="/opt/openclaw-plugins/openclaw-camera"
PLUGIN_ID="openclaw-camera"
TOOL_NAME="capture_camera_frame"
CFG_FILE="${OPENCLAW_HOME:-/home/jovyan/.openclaw}/.openclaw/openclaw.json"

if [[ ! -f "$PLUGIN_SRC/index.js" ]]; then
    echo "[openclaw] camera plugin source missing at $PLUGIN_SRC; skipping"
    exit 0
fi

if ! command -v openclaw >/dev/null 2>&1; then
    echo "[openclaw] CLI not on PATH; skipping camera plugin install"
    exit 0
fi

needs_install=true
if openclaw plugins inspect "$PLUGIN_ID" >/dev/null 2>&1; then
    CURRENT_SRC="$(openclaw plugins inspect "$PLUGIN_ID" 2>/dev/null | awk -F': ' '/^Source path:/ {print $2; exit}')"
    if [[ "$CURRENT_SRC" == "$PLUGIN_SRC" ]]; then
        echo "[openclaw] camera plugin already registered from $PLUGIN_SRC"
        needs_install=false
    fi
fi

if [[ "$needs_install" == "true" ]]; then
    echo "[openclaw] linking camera plugin from $PLUGIN_SRC"
    # The plugin spawns ffmpeg via child_process, which trips the unsafe-pattern
    # guard. The plugin source is shipped inside this image (not from the network),
    # so we explicitly bypass the guard.
    openclaw plugins install --link --force --dangerously-force-unsafe-install "$PLUGIN_SRC"
fi

# Plugin tools are gated by the agent tool profile. The default "coding" profile
# does NOT expose our custom tool, so the agent (codex harness) refuses to call
# it. Merge the tool name into tools.alsoAllow so the harness sees it.
if [[ -f "$CFG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    if jq -e --arg t "$TOOL_NAME" '.tools.alsoAllow // [] | index($t)' "$CFG_FILE" >/dev/null 2>&1; then
        echo "[openclaw] $TOOL_NAME already in tools.alsoAllow"
    else
        echo "[openclaw] adding $TOOL_NAME to tools.alsoAllow"
        EXISTING="$(jq -c '.tools.alsoAllow // []' "$CFG_FILE")"
        UPDATED="$(jq -nc --argjson cur "$EXISTING" --arg t "$TOOL_NAME" '$cur + [$t] | unique')"
        printf '{"tools":{"alsoAllow":%s}}' "$UPDATED" \
            | openclaw config patch --stdin --replace-path tools.alsoAllow
    fi
fi
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-install-camera-plugin.sh

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

RUN cat > /usr/local/bin/before-notebook.d/08-openclaw-camera-plugin.sh <<'HOOK'
#!/usr/bin/env bash
# Link the baked openclaw-camera plugin into the agent's extensions dir.
run_as_jovyan() {
    if [[ "$(id -u)" == "0" ]]; then
        runuser -u jovyan --preserve-environment -- "$@"
    else
        "$@"
    fi
}
run_as_jovyan /usr/local/bin/openclaw-install-camera-plugin.sh \
    || echo "[openclaw] camera plugin install failed; continuing"
HOOK
RUN chmod +x /usr/local/bin/before-notebook.d/08-openclaw-camera-plugin.sh

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
