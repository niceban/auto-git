#!/usr/bin/env bash
#
# install.sh — Install Branch-Autonomous Git Workflow (hooks-omni v2.0 Python)
#
# Usage:
#   git clone https://github.com/niceban/auto-git.git
#   cd auto-git
#   bash install.sh
#
# This installs the plugin to:
#   ~/.claude/plugins/branch-autonomous/  ← hook scripts + lib + manifest.json
#   ~/.claude/hooks/branch-autonomous/hooks.json  ← Claude Code auto-discovers
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/.claude/plugins/branch-autonomous"
HOOKS_JSON="$HOME/.claude/hooks/branch-autonomous/hooks.json"
HOOKS_OMNI="$SCRIPT_DIR/hooks-omni"

log()   { echo "[INFO] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ─── Prerequisites ─────────────────────────────────────────────────────────────
log "Checking prerequisites..."
command -v git >/dev/null || die "git required"
command -v jq  >/dev/null || die "jq required (brew install jq)"
jq -n '{}' >/dev/null 2>&1 || die "jq broken"
[[ -d "$HOME/.claude" ]] || die "~/.claude not found. Install Claude Code first."
command -v python3 >/dev/null || die "python3 required"

# ─── Install ─────────────────────────────────────────────────────────────────
log "Installing to $PLUGIN_DIR"

if [[ ! -d "$HOOKS_OMNI" ]]; then
  die "hooks-omni/ directory not found."
fi

mkdir -p "$PLUGIN_DIR/hooks"
mkdir -p "$PLUGIN_DIR/lib"
mkdir -p "$(dirname "$HOOKS_JSON")"

# Copy Python hooks (hooks/)
for hook in session_start semantic_trigger guard_bash pre_push post_tool post_tool_fail stop; do
  src="$HOOKS_OMNI/hooks/${hook}.py"
  dst="$PLUGIN_DIR/hooks/${hook}.py"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
    chmod +x "$dst"
    # Verify Python syntax
    if python3 -m py_compile "$dst" 2>/dev/null; then
      log "  ${hook}.py OK"
    else
      die "  ${hook}.py SYNTAX ERROR"
    fi
  else
    die "  missing ${hook}.py in hooks-omni/hooks/"
  fi
done

# Copy shared libraries (lib/)
for lib in state config git hook logger; do
  src="$HOOKS_OMNI/lib/${lib}.py"
  dst="$PLUGIN_DIR/lib/${lib}.py"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
    chmod +x "$dst"
    if python3 -m py_compile "$dst" 2>/dev/null; then
      log "  lib/${lib}.py OK"
    else
      die "  lib/${lib}.py SYNTAX ERROR"
    fi
  else
    die "  missing lib/${lib}.py"
  fi
done

# Copy manifest.json
cp "$HOOKS_OMNI/manifest.json" "$PLUGIN_DIR/manifest.json"

# Generate hooks.json from manifest, substituting ${PLUGIN_DIR}
log "Creating $HOOKS_JSON"
sed "s|\${PLUGIN_DIR}|$PLUGIN_DIR|g" \
  "$HOOKS_OMNI/manifest.json" > "$HOOKS_JSON"

# ─── Verify ──────────────────────────────────────────────────────────────────
log "Verifying..."
jq . "$HOOKS_JSON"       &>/dev/null || die "hooks.json invalid"
jq . "$PLUGIN_DIR/manifest.json" &>/dev/null || die "manifest.json invalid"

n=$(jq '[.hooks[][].hooks[]?.command?] | map(select(. != null)) | length' "$HOOKS_JSON")
log "  $n hook(s) registered (expected 7)"

echo ""
echo "========================================"
echo "Installation complete! (hooks-omni v2.0 Python)"
echo ""
echo "Restart Claude Code to activate:"
echo "  exit && claude"
echo ""
echo "Plugin: $PLUGIN_DIR"
echo "Hooks:  $HOOKS_JSON"
echo "Manifest: $PLUGIN_DIR/manifest.json"
echo "========================================"
