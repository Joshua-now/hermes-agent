#!/bin/bash
# Docker entrypoint: bootstrap config files into the mounted volume, then run hermes.
set -e

# --- Start Tailscale (userspace networking; Railway containers have no TUN device) ---
# Non-fatal by design: a Tailscale problem must never stop the agent from starting.
TS_KEY="${TAILSCALE_AUTH_KEY:-${TAILSCALE_AUTHKEY:-$TS_AUTHKEY}}"
if [ -n "$TS_KEY" ]; then
    echo "Starting Tailscale (userspace networking)..."
    mkdir -p /var/lib/tailscale /var/run/tailscale
    tailscaled \
        --tun=userspace-networking \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
    set +e
    for i in $(seq 1 15); do
        tailscale --socket=/var/run/tailscale/tailscaled.sock status >/dev/null 2>&1 && break
        sleep 1
    done
    tailscale --socket=/var/run/tailscale/tailscaled.sock up \
        --authkey="$TS_KEY" \
        --hostname=railway-hermes \
        --accept-routes
    if [ $? -eq 0 ]; then
        echo "Tailscale connected."
    else
        echo "WARNING: Tailscale did not come up; continuing without it."
    fi
    set -e
else
    echo "No Tailscale auth key set; skipping Tailscale."
fi

HERMES_HOME="/opt/data"
INSTALL_DIR="/opt/hermes"

# Create essential directory structure. Cache and platform directories
# (cache/images, cache/audio, platforms/whatsapp, etc.) are created on
# demand by the application - do not pre-create them here so new installs
# get the consolidated layout from get_hermes_dir().
# The "home/" subdirectory is a per-profile HOME for subprocesses (git,
# ssh, gh, npm ...). Without it those tools write to /root which is
# ephemeral and shared across profiles. See issue #4426.
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# .env
if [ ! -f "$HERMES_HOME/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
fi

# config.yaml
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi

# SOUL.md
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
    cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
fi

# Sync bundled skills (manifest-based so user edits are preserved)
if [ -d "$INSTALL_DIR/skills" ]; then
    python3 "$INSTALL_DIR/tools/skills_sync.py"
fi

# Reconcile model routing from Railway env vars. config.yaml on the volume otherwise
# overrides env (provider/base_url/model), so we write env values into it on every boot.
# Non-fatal by design: never blocks the agent from starting.
python3 - <<'PYEOF' || echo "[entrypoint] model reconcile skipped"
import os
path = "/opt/data/config.yaml"
try:
    import yaml
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
    m = cfg.get("model")
    if not isinstance(m, dict):
        m = {}
        cfg["model"] = m
    prov  = os.environ.get("HERMES_INFERENCE_PROVIDER")
    base  = os.environ.get("OPENAI_BASE_URL")
    model = os.environ.get("HERMES_MODEL")
    key   = os.environ.get("OPENAI_API_KEY")
    if prov:  m["provider"] = prov
    if base:  m["base_url"] = base
    if model:
        m["model"] = model
        m["default"] = model
    if key:   m["api_key"] = key
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False)
    print("[entrypoint] reconciled model: provider=%s base_url=%s model=%s" % (prov, base, model))
except Exception as e:
    print("[entrypoint] model reconcile error: %s" % e)
PYEOF

# Efficiency tuning (lighter/cheaper): make Tool Search + compression explicit and
# trim unused media tools from the Telegram agent. MCP servers auto-attach on every
# platform (see hermes_cli/tools_config.py), so trimming toolsets never drops n8n/MCP.
# Idempotent and guarded: only replaces the UNTOUCHED default Telegram preset.
# Non-fatal by design: never blocks the agent from starting.
python3 - <<'PYEOF2' || echo "[entrypoint] efficiency tune skipped"
import os
path = "/opt/data/config.yaml"
try:
    import yaml
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
    changed = False

    # 1) Tool Search: progressive disclosure for MCP/plugin tools (auto = only defer
    #    when their schemas get big). Safe for free models. Explicit if unset.
    tools = cfg.get("tools")
    if not isinstance(tools, dict):
        tools = {}; cfg["tools"] = tools
    if not isinstance(tools.get("tool_search"), dict):
        tools["tool_search"] = {"enabled": "auto"}; changed = True

    # 2) Context compression on (default true) — make it explicit so it's guaranteed.
    if not isinstance(cfg.get("compression"), dict):
        cfg["compression"] = {"enabled": True}; changed = True

    # 3) Trim Telegram to a lean set: drop vision/image_gen/tts (unused), add
    #    memory + session_search (recall). Only if still the default preset.
    # Dropped `browser` (~12 tools, Browserbase-gated) — Hermes reaches Railway/Telnyx/
    # GitHub/GHL via their APIs (terminal/code/MCP), not a headless browser. Kept `web`
    # (search + read page). This carves a big chunk off the ~8.6K tool-token load.
    LEAN = ["terminal", "file", "web", "skills", "todo",
            "cronjob", "memory", "session_search", "send_message"]
    pt = cfg.get("platform_toolsets")
    if not isinstance(pt, dict):
        pt = {}; cfg["platform_toolsets"] = pt
    # Entrypoint owns the Telegram toolset — always converge to LEAN (idempotent).
    if pt.get("telegram") != LEAN:
        pt["telegram"] = LEAN; changed = True

    if changed:
        with open(path, "w") as f:
            yaml.safe_dump(cfg, f, default_flow_style=False)
    print("[entrypoint] efficiency: tool_search=%s compression=%s telegram=%s" % (
        cfg.get("tools", {}).get("tool_search"),
        cfg.get("compression"),
        cfg.get("platform_toolsets", {}).get("telegram")))
except Exception as e:
    print("[entrypoint] efficiency tune error: %s" % e)
PYEOF2

exec hermes "$@"
