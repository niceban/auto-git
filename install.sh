#!/usr/bin/env bash
#
# install.sh — Install Branch-Autonomous Git Workflow
#
# Usage:
#   git clone https://github.com/niceban/auto-git.git
#   cd auto-git
#   bash install.sh
#
# This installs the plugin to:
#   ~/.claude/plugins/branch-autonomous/    ← hook scripts
#   ~/.claude/hooks/branch-autonomous/hooks.json  ← Claude Code auto-discovers
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/.claude/plugins/branch-autonomous"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

log()   { echo "[INFO] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ─── Prerequisites ─────────────────────────────────────────────────────────────
log "Checking prerequisites..."
command -v git >/dev/null || die "git required"
command -v jq  >/dev/null || die "jq required (brew install jq)"
jq -n '{}' >/dev/null 2>&1 || die "jq broken"
[[ -d "$HOME/.claude" ]] || die "~/.claude not found. Install Claude Code first."

# ─── Install ──────────────────────────────────────────────────────────────────
log "Installing to $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/hooks"
mkdir -p "$(dirname "$HOOKS_JSON")"

# Copy scripts
cp "$SCRIPT_DIR/hooks/"*.sh "$PLUGIN_DIR/hooks/"
chmod +x "$PLUGIN_DIR/hooks/"*.sh

# Copy config to plugin dir
cp "$SCRIPT_DIR/config.json" "$PLUGIN_DIR/config.json"

# Copy manifest
cp "$SCRIPT_DIR/manifest.json" "$PLUGIN_DIR/manifest.json"

# Generate hooks.json from template, substituting ${PLUGIN_DIR} with real path
log "Creating $HOOKS_JSON"
sed "s|\${PLUGIN_DIR}|$PLUGIN_DIR|g" \
  "$SCRIPT_DIR/hooks.json" > "$HOOKS_JSON"

# ─── Verify ──────────────────────────────────────────────────────────────────
log "Verifying..."
for hook in session-start guard-bash pre-push post-tool post-tool-fail stop; do
  p="$PLUGIN_DIR/hooks/${hook}.sh"
  if [[ -x "$p" ]] && bash -n "$p" 2>/dev/null; then
    log "  ${hook}.sh OK"
  else
    die "  ${hook}.sh FAILED"
  fi
done

jq . "$HOOKS_JSON"    &>/dev/null || die "hooks.json invalid"
jq . "$PLUGIN_DIR/config.json" &>/dev/null || die "config.json invalid"

n=$(jq '[.hooks[][].hooks[]?.command?] | map(select(. != null)) | length' "$HOOKS_JSON")
log "  $n hook(s) registered"

echo ""
echo "========================================"
echo "Installation complete!"
echo ""
echo "Restart Claude Code to activate:"
echo "  exit && claude"
echo ""
echo "Plugin: $PLUGIN_DIR"
echo "Hooks:  $HOOKS_JSON"
echo "Config: $PLUGIN_DIR/config.json"
echo "========================================"
