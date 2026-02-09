#!/usr/bin/env bash
set -euo pipefail

GSH_URL="https://raw.githubusercontent.com/s7net/GlyNet-Shell/refs/heads/main/gsh"
ENV_URL="https://raw.githubusercontent.com/s7net/GlyNet-Shell/refs/heads/main/.gsh.env"

INSTALL_BIN_ROOT="/usr/local/bin"
INSTALL_BIN_USER="$HOME/bin"

SSH_DIR="$HOME/.ssh"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "🚀 GlyNet Shell Installer"

DL_CMD=""
if has_cmd curl; then
  DL_CMD="curl -fsSL"
elif has_cmd wget; then
  DL_CMD="wget -qO-"
else
  echo "❌ curl or wget required"
  exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ "$EUID" -eq 0 ]]; then
  echo "👑 Installing as root → $INSTALL_BIN_ROOT"

  $DL_CMD "$GSH_URL" > "$INSTALL_BIN_ROOT/gsh"
  chmod +x "$INSTALL_BIN_ROOT/gsh"

  if [[ ! -f "$SSH_DIR/.gsh.env" ]]; then
    echo "📦 Installing default env → $SSH_DIR/.gsh.env"
    $DL_CMD "$ENV_URL" > "$SSH_DIR/.gsh.env"
    chmod 600 "$SSH_DIR/.gsh.env"
  else
    echo "ℹ️  Env already exists → skipping"
  fi

  echo "✅ Installed → $INSTALL_BIN_ROOT/gsh"

else
  echo "👤 Installing as user → $INSTALL_BIN_USER"

  mkdir -p "$INSTALL_BIN_USER"

  $DL_CMD "$GSH_URL" > "$INSTALL_BIN_USER/gsh"
  chmod +x "$INSTALL_BIN_USER/gsh"

  if [[ ! -f "$SSH_DIR/.gsh.env" ]]; then
    echo "📦 Installing default env → $SSH_DIR/.gsh.env"
    $DL_CMD "$ENV_URL" > "$SSH_DIR/.gsh.env"
    chmod 600 "$SSH_DIR/.gsh.env"
  else
    echo "ℹ️  Env already exists → skipping"
  fi

  if ! echo "$PATH" | grep -q "$INSTALL_BIN_USER"; then
    echo "⚠️  $INSTALL_BIN_USER not in PATH"
    echo "Add this to ~/.bashrc or ~/.zshrc:"
    echo 'export PATH="$HOME/bin:$PATH"'
  fi

  echo "✅ Installed → $INSTALL_BIN_USER/gsh"
fi

echo
echo "🎉 GlyNet Shell installed successfully!"
echo "Run: gsh --help"
