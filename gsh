#!/usr/bin/env bash
set -euo pipefail

APP="gsh"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
GSH_ENV_FILE="$SSH_DIR/.gsh.env"

BIN_DIR="$HOME/bin"

mkdir -p "$SSH_DIR" "$BIN_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Defaults (overridden by ~/.ssh/.gsh.env)
DEFAULT_IDENTITY="$HOME/.ssh/id_ed25519"
SETUP_SSH_URL="https://scripts.glynet.org/setup-ssh.sh"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
BACKUP_ZIP_PASS=""
RESOLVE_HOST_BEFORE_CONNECT="1"
RESOLVE_PREFER="ipv4" # ipv4|ipv6|any

# Load env (only source of truth)
if [[ -f "$GSH_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$GSH_ENV_FILE"
fi

has_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local label="$1" default="${2:-}"
  local v
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " v
    echo "${v:-$default}"
  else
    read -r -p "$label: " v
    echo "$v"
  fi
}

prompt_secret() {
  local label="$1" default="${2:-}"
  local v
  if [[ -n "$default" ]]; then
    read -r -s -p "$label [set]: " v
    echo
    echo "${v:-$default}"
  else
    read -r -s -p "$label: " v
    echo
    echo "$v"
  fi
}

save_gsh_env() {
  umask 077
  cat > "$GSH_ENV_FILE" <<EOF
DEFAULT_IDENTITY="$(printf '%q' "$DEFAULT_IDENTITY")"
SETUP_SSH_URL="$(printf '%q' "$SETUP_SSH_URL")"
TG_BOT_TOKEN="$(printf '%q' "$TG_BOT_TOKEN")"
TG_CHAT_ID="$(printf '%q' "$TG_CHAT_ID")"
BACKUP_ZIP_PASS="$(printf '%q' "$BACKUP_ZIP_PASS")"
RESOLVE_HOST_BEFORE_CONNECT="$(printf '%q' "$RESOLVE_HOST_BEFORE_CONNECT")"
RESOLVE_PREFER="$(printf '%q' "$RESOLVE_PREFER")"
EOF
  chmod 600 "$GSH_ENV_FILE"
}

upsert_ssh_config() {
  local name="$1" host="$2" user="$3" port="$4" identity="$5"

  local tmp
  tmp="$(mktemp)"

  awk -v h="Host $name" '
    BEGIN{skip=0}
    $0 ~ /^Host[[:space:]]+/ {
      if ($0==h) {skip=1; next}
      else skip=0
    }
    skip==0 {print}
  ' "$SSH_CONFIG" > "$tmp"

  cat >> "$tmp" <<EOF

Host $name
  HostName $host
  User $user
  Port $port
  IdentityFile $identity
  PreferredAuthentications publickey,password
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking accept-new
EOF

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
}

remove_host() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v h="Host $name" '
    BEGIN{skip=0}
    /^Host[[:space:]]+/ {
      if ($0==h) {skip=1; next}
      else skip=0
    }
    skip==0 {print}
  ' "$SSH_CONFIG" > "$tmp"

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
}

list_hosts() {
  awk '
    $1=="Host" && NF>=2 {
      for(i=2;i<=NF;i++){
        h=$i
        if(h ~ /[\*\?\[]/) continue
        print h
      }
    }
  ' "$SSH_CONFIG" | sort -fu
}

sort_config() {
  local tmp
  tmp="$(mktemp)"

  # Header (before first Host)
  awk '
    BEGIN{inhost=0}
    /^Host[[:space:]]+/ {inhost=1}
    inhost==0 {print}
  ' "$SSH_CONFIG" > "$tmp"

  # Blocks sorted by first alias
  awk '
    function flush(){
      if(block!=""){
        split(first,a,/[[:space:]]+/)
        key=a[2]
        if(key!="") print key "\t" block
      }
      block=""; first=""
    }
    BEGIN{block=""; first=""}
    /^Host[[:space:]]+/{
      flush()
      first=$0
      block=$0 "\n"
      next
    }
    { if(first!="") block=block $0 "\n" }
    END{flush()}
  ' "$SSH_CONFIG" | sort -f | cut -f2- >> "$tmp"

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  echo "✅ Sorted ~/.ssh/config"
}

# --- resolve hostname to fresh IP before connect (avoid relying on DNS cache/TTL behavior)
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]]; }
is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }

resolve_fresh_ip() {
  local host="$1"
  local prefer="${2:-ipv4}"
  local ip=""

  if has_cmd getent; then
    case "$prefer" in
      ipv4) ip="$(getent ahosts "$host" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')" ;;
      ipv6) ip="$(getent ahosts "$host" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')" ;;
      any|*) ip="$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1; exit}')" ;;
    esac
  fi

  if [[ -z "$ip" ]] && has_cmd host; then
    case "$prefer" in
      ipv4) ip="$(host -t A "$host" 2>/dev/null | awk '{print $NF; exit}')" ;;
      ipv6) ip="$(host -t AAAA "$host" 2>/dev/null | awk '{print $NF; exit}')" ;;
      any|*) ip="$(host "$host" 2>/dev/null | awk '{print $NF; exit}')" ;;
    esac
  fi

  echo "$ip"
}

connect_with_resolve_if_needed() {
  local alias="$1"

  local hostname
  hostname="$(ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"

  if [[ -z "$hostname" ]]; then
    exec ssh "$alias"
  fi

  if [[ "$RESOLVE_HOST_BEFORE_CONNECT" != "1" ]] || is_ip "$hostname"; then
    exec ssh "$alias"
  fi

  local ip
  ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
  if [[ -z "$ip" ]]; then
    exec ssh "$alias"
  fi

  exec ssh \
    -o HostName="$ip" \
    -o HostKeyAlias="$hostname" \
    -o CheckHostIP=yes \
    "$alias"
}

cmd_init() {
  DEFAULT_IDENTITY="$(prompt "Default identity path" "$DEFAULT_IDENTITY")"
  SETUP_SSH_URL="$(prompt "Setup script URL" "$SETUP_SSH_URL")"

  TG_BOT_TOKEN="$(prompt_secret "Telegram bot token (optional)" "$TG_BOT_TOKEN")"
  TG_CHAT_ID="$(prompt "Telegram chat_id (optional)" "$TG_CHAT_ID")"
  BACKUP_ZIP_PASS="$(prompt_secret "Backup ZIP password (optional)" "$BACKUP_ZIP_PASS")"

  RESOLVE_HOST_BEFORE_CONNECT="$(prompt "Resolve hostname before connect? (1/0)" "$RESOLVE_HOST_BEFORE_CONNECT")"
  RESOLVE_PREFER="$(prompt "Resolve prefer (ipv4/ipv6/any)" "$RESOLVE_PREFER")"

  save_gsh_env
  echo "✅ Saved: $GSH_ENV_FILE"
}

cmd_add() {
  local name ip port user identity pub

  name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(prompt "Alias name")"
  fi

  ip="$(prompt "IP / Host")"
  port="$(prompt "Port" "22")"
  user="$(prompt "User" "root")"
  identity="$(prompt "Identity file" "$DEFAULT_IDENTITY")"

  if [[ -z "$name" || -z "$ip" ]]; then
    echo "❌ Name and IP/Host are required."
    exit 1
  fi

  if [[ ! -f "${identity}.pub" ]]; then
    echo "❌ Public key missing → ${identity}.pub"
    echo "Generate: ssh-keygen -t ed25519 -f \"$identity\""
    exit 1
  fi

  pub="$(cat "${identity}.pub")"

  upsert_ssh_config "$name" "$ip" "$user" "$port" "$identity"

  echo
  echo "Run on server (as root) after password login:"
  echo "curl -fsSL $SETUP_SSH_URL | bash -s -- '$pub'"
  echo
}

cmd_update() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(prompt "Host name to update")"
  fi

  local ip port user identity
  ip="$(prompt "New IP / Host")"
  port="$(prompt "New Port" "22")"
  user="$(prompt "New User" "root")"
  identity="$(prompt "New Identity" "$DEFAULT_IDENTITY")"

  if [[ -z "$name" || -z "$ip" ]]; then
    echo "❌ Name and IP/Host are required."
    exit 1
  fi

  upsert_ssh_config "$name" "$ip" "$user" "$port" "$identity"
  echo "✅ Updated $name"
}

cmd_rm() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP rm <name>"
    exit 1
  fi
  remove_host "$name"
  echo "✅ Removed $name"
}

zip_encrypt() {
  local src_dir="$1" zip_path="$2" pass="$3"
  if has_cmd zip; then
    (cd "$src_dir" && zip -qr -P "$pass" "$zip_path" .)
    return 0
  fi
  if has_cmd 7z; then
    (cd "$src_dir" && 7z a -tzip -p"$pass" -mem=AES256 "$zip_path" . >/dev/null)
    return 0
  fi
  echo "❌ Need zip or 7z to create password-protected zip." >&2
  return 2
}

unzip_decrypt() {
  local zip_path="$1" dest_dir="$2" pass="$3"
  mkdir -p "$dest_dir"
  if has_cmd unzip; then
    unzip -q -o -P "$pass" "$zip_path" -d "$dest_dir"
    return 0
  fi
  if has_cmd 7z; then
    7z x -y -p"$pass" -o"$dest_dir" "$zip_path" >/dev/null
    return 0
  fi
  echo "❌ Need unzip or 7z to extract password-protected zip." >&2
  return 2
}

tg_send_file() {
  local file="$1" caption="${2:-}"
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    echo "⚠️  Telegram not configured. Set TG_BOT_TOKEN and TG_CHAT_ID via: $APP init"
    return 2
  fi
  if ! has_cmd curl; then
    echo "❌ curl not found. Can't send to Telegram." >&2
    return 2
  fi
  curl -fsSL \
    -F "chat_id=$TG_CHAT_ID" \
    -F "caption=$caption" \
    -F "document=@$file" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" >/dev/null
}

cmd_backup() {
  local pass="${BACKUP_ZIP_PASS:-}"
  if [[ -z "$pass" ]]; then
    pass="$(prompt_secret "ZIP password (required)")"
  fi
  if [[ -z "$pass" ]]; then
    echo "❌ Password required."
    exit 1
  fi

  local ts base tmpdir zipfile outdir
  ts="$(date +%Y%m%d-%H%M%S)"
  base="gsh-backup-$ts"
  outdir="$HOME"
  zipfile="$outdir/$base.zip"
  tmpdir="$(mktemp -d)"

  mkdir -p "$tmpdir/home/.ssh" "$tmpdir/home/bin" "$tmpdir/meta"
  [[ -d "$HOME/.ssh" ]] && cp -a "$HOME/.ssh/." "$tmpdir/home/.ssh/" 2>/dev/null || true
  [[ -d "$HOME/bin"  ]] && cp -a "$HOME/bin/."  "$tmpdir/home/bin/"  2>/dev/null || true

  printf "created_at=%s\nhost=%s\nuser=%s\n" "$(date -Is)" "$(hostname)" "$(whoami)" > "$tmpdir/meta/info.txt"

  zip_encrypt "$tmpdir" "$zipfile" "$pass"
  rm -rf "$tmpdir"

  echo "✅ Backup created: $zipfile"

  if tg_send_file "$zipfile" "GSH backup $ts"; then
    echo "✅ Sent to Telegram"
  else
    echo "ℹ️  Not sent to Telegram (configure via: $APP init)"
  fi
}

cmd_restore() {
  local zip_path="${1:-}"
  if [[ -z "$zip_path" ]]; then
    echo "Usage: $APP restore <backup.zip>"
    exit 1
  fi
  if [[ ! -f "$zip_path" ]]; then
    echo "❌ File not found: $zip_path"
    exit 1
  fi

  local pass="${BACKUP_ZIP_PASS:-}"
  if [[ -z "$pass" ]]; then
    pass="$(prompt_secret "ZIP password")"
  fi
  if [[ -z "$pass" ]]; then
    echo "❌ Password required."
    exit 1
  fi

  local ts tmpdir ssh_bak bin_bak
  ts="$(date +%Y%m%d-%H%M%S)"
  tmpdir="$(mktemp -d)"

  unzip_decrypt "$zip_path" "$tmpdir" "$pass"

  if [[ ! -d "$tmpdir/home/.ssh" && ! -d "$tmpdir/home/bin" ]]; then
    echo "❌ Backup structure invalid (expected home/.ssh or home/bin inside zip)."
    rm -rf "$tmpdir"
    exit 1
  fi

  if [[ -d "$HOME/.ssh" ]]; then
    ssh_bak="$HOME/.ssh.bak.$ts"
    mv "$HOME/.ssh" "$ssh_bak"
    echo "✅ Moved current ~/.ssh -> $ssh_bak"
  fi
  if [[ -d "$HOME/bin" ]]; then
    bin_bak="$HOME/bin.bak.$ts"
    mv "$HOME/bin" "$bin_bak"
    echo "✅ Moved current ~/bin -> $bin_bak"
  fi

  mkdir -p "$HOME/.ssh" "$HOME/bin"
  chmod 700 "$HOME/.ssh"

  [[ -d "$tmpdir/home/.ssh" ]] && cp -a "$tmpdir/home/.ssh/." "$HOME/.ssh/"
  [[ -d "$tmpdir/home/bin"  ]] && cp -a "$tmpdir/home/bin/."  "$HOME/bin/"

  chmod 700 "$HOME/.ssh" || true
  [[ -f "$HOME/.ssh/config" ]] && chmod 600 "$HOME/.ssh/config" || true
  [[ -f "$HOME/.ssh/authorized_keys" ]] && chmod 600 "$HOME/.ssh/authorized_keys" || true
  [[ -f "$HOME/.ssh/.gsh.env" ]] && chmod 600 "$HOME/.ssh/.gsh.env" || true
  [[ -f "$HOME/bin/gsh" ]] && chmod +x "$HOME/bin/gsh" || true

  rm -rf "$tmpdir"
  echo "✅ Restore complete."
}

usage() {
  cat <<EOF
GlyNet Shell (gsh)

SSH:
  gsh add <name>
  gsh update <name>
  gsh rm <name>
  gsh ls
  gsh sort
  gsh init
  gsh <name>

Backup/Restore:
  gsh backup
  gsh restore <backup.zip>

Config:
  ~/.ssh/.gsh.env
EOF
}

main() {
  case "${1:-}" in
    add) shift; cmd_add "${1:-}" ;;
    update) shift; cmd_update "${1:-}" ;;
    rm) shift; cmd_rm "${1:-}" ;;
    ls) cmd_ls() { list_hosts; }; cmd_ls ;;
    sort) sort_config ;;
    init) cmd_init ;;
    backup) cmd_backup ;;
    restore) shift; cmd_restore "${1:-}" ;;
    ""|-h|--help) usage ;;
    *)
      connect_with_resolve_if_needed "$1"
    ;;
  esac
}

main "$@"

