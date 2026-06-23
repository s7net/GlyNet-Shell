#!/usr/bin/env bash
set -euo pipefail

APP="gsh"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
GSH_ENV_FILE="$SSH_DIR/.gsh.env"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

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

confirm_yn() {
  local q="$1"
  local ans
  while true; do
    read -r -p "$q (y/n): " ans
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
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

# ── SSH Config helpers ──────────────────────────────────────────────────────

host_exists() {
  local name="$1"
  awk -v h="Host $name" '$0==h{found=1} END{exit !found}' "$SSH_CONFIG" 2>/dev/null
}

# Read a single directive value for a given Host block
get_host_field() {
  local name="$1" field="$2"
  awk -v h="Host $name" -v f="$field" '
    $0==h{in_block=1; next}
    in_block && /^Host[[:space:]]/{in_block=0}
    in_block{
      gsub(/^[[:space:]]+/,"")
      if(tolower($1)==tolower(f)){print $2; exit}
    }
  ' "$SSH_CONFIG" 2>/dev/null
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

  awk '
    BEGIN{inhost=0}
    /^Host[[:space:]]+/ {inhost=1}
    inhost==0 {print}
  ' "$SSH_CONFIG" > "$tmp"

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

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

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

ssh_try_connect() {
  local alias="$1"
  local hostname="${2:-}"
  local ip="${3:-}"

  local err tmp
  tmp="$(mktemp)"

  set +e
  ssh "$alias" 2> "$tmp"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    rm -f "$tmp"
    return 0
  fi

  err="$(cat "$tmp")"
  rm -f "$tmp"

  if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$err" || \
     grep -q "Host key verification failed" <<<"$err"; then

    echo "⚠️  SSH Host Key changed for: $alias"
    [[ -n "$hostname" ]] && echo "   HostKeyAlias/Host: $hostname"
    [[ -n "$ip" ]] && echo "   Target IP: $ip"
    echo
    echo "This usually happens after reinstall/reimage, or IP/host was reassigned."
    echo "If you trust this server, I can remove old keys and retry."
    echo

    if confirm_yn "Remove old known_hosts entries and retry?"; then
      echo "🧹 Cleaning known_hosts entries..."
      ssh-keygen -R "$alias" >/dev/null 2>&1 || true
      if [[ -n "$hostname" ]]; then
        ssh-keygen -R "$hostname" >/dev/null 2>&1 || true
      fi
      if [[ -n "$ip" ]]; then
        ssh-keygen -R "$ip" >/dev/null 2>&1 || true
        local port
        port="$(ssh -G "$alias" 2>/dev/null | awk '$1=="port"{print $2; exit}')"
        if [[ -n "${port:-}" ]]; then
          ssh-keygen -R "[$ip]:$port" >/dev/null 2>&1 || true
        fi
      fi
      echo "✅ Removed old keys. Retrying connection..."
      exec ssh "$alias"
    else
      echo "❌ Connection aborted (to keep you safe)."
      return 255
    fi
  fi

  echo "$err" >&2
  return "$rc"
}

# ── FIX #1: Check alias exists before connecting ────────────────────────────
connect_with_resolve_if_needed() {
  local alias="$1"

  # Guard: alias must exist in ssh config
  if ! host_exists "$alias"; then
    echo "❌ Unknown host: '$alias'"
    echo "   Use 'gsh ls' to list hosts, or 'gsh add $alias' to add it."
    exit 1
  fi

  local hostname
  hostname="$(ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"

  if [[ -z "$hostname" ]]; then
    exec ssh "$alias"
  fi

  if [[ "$RESOLVE_HOST_BEFORE_CONNECT" != "1" ]] || is_ip "$hostname"; then
    ssh_try_connect "$alias" "$hostname" ""
    exit $?
  fi

  local ip
  ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
  if [[ -z "$ip" ]]; then
    ssh_try_connect "$alias" "$hostname" ""
    exit $?
  fi

  set +e
  ssh -o HostName="$ip" -o HostKeyAlias="$hostname" -o CheckHostIP=yes "$alias"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    exit 0
  fi

  ssh_try_connect "$alias" "$hostname" "$ip"
  exit $?
}

# ── Commands ─────────────────────────────────────────────────────────────────

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
    echo "   Generate: ssh-keygen -t ed25519 -f \"$identity\""
    exit 1
  fi

  pub="$(cat "${identity}.pub")"
  upsert_ssh_config "$name" "$ip" "$user" "$port" "$identity"

  echo
  echo "Run on server (as root) after password login:"
  echo "curl -fsSL $SETUP_SSH_URL | bash -s -- '$pub'"
  echo
}

# ── FIX #2: update reads current values as defaults ─────────────────────────
cmd_update() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(prompt "Host name to update")"
  fi

  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found in config. Use 'gsh add $name' to add it."
    exit 1
  fi

  # Read existing values from config as defaults
  local cur_ip cur_port cur_user cur_identity
  cur_ip="$(get_host_field "$name" "hostname")"
  cur_port="$(get_host_field "$name" "port")"
  cur_user="$(get_host_field "$name" "user")"
  cur_identity="$(get_host_field "$name" "identityfile")"

  # Fall back to global defaults if config is somehow empty
  [[ -z "$cur_port" ]]     && cur_port="22"
  [[ -z "$cur_user" ]]     && cur_user="root"
  [[ -z "$cur_identity" ]] && cur_identity="$DEFAULT_IDENTITY"

  local ip port user identity
  ip="$(prompt       "IP / Host"      "$cur_ip")"
  port="$(prompt     "Port"           "$cur_port")"
  user="$(prompt     "User"           "$cur_user")"
  identity="$(prompt "Identity file"  "$cur_identity")"

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
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  if confirm_yn "Remove host '$name'?"; then
    remove_host "$name"
    echo "✅ Removed $name"
  else
    echo "Cancelled."
  fi
}

# ── NEW: gsh info <name> ─────────────────────────────────────────────────────
cmd_info() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP info <name>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  echo "🔍 Host: $name"
  ssh -G "$name" 2>/dev/null | awk '
    $1=="hostname"     {print "   HostName:  " $2}
    $1=="user"         {print "   User:      " $2}
    $1=="port"         {print "   Port:      " $2}
    $1=="identityfile" {print "   Identity:  " $2}
  '
}

# ── NEW: gsh rename <old> <new> ──────────────────────────────────────────────
cmd_rename() {
  local old="${1:-}" new="${2:-}"
  if [[ -z "$old" || -z "$new" ]]; then
    echo "Usage: $APP rename <old> <new>"
    exit 1
  fi
  if ! host_exists "$old"; then
    echo "❌ Host '$old' not found."
    exit 1
  fi
  if host_exists "$new"; then
    echo "❌ Host '$new' already exists."
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  sed "s/^Host $old$/Host $new/" "$SSH_CONFIG" > "$tmp"
  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  echo "✅ Renamed '$old' → '$new'"
}

# ── NEW: gsh duplicate <src> <dst> ───────────────────────────────────────────
cmd_duplicate() {
  local src="${1:-}" dst="${2:-}"
  if [[ -z "$src" || -z "$dst" ]]; then
    echo "Usage: $APP duplicate <source> <new-name>"
    exit 1
  fi
  if ! host_exists "$src"; then
    echo "❌ Host '$src' not found."
    exit 1
  fi
  if host_exists "$dst"; then
    echo "❌ Host '$dst' already exists."
    exit 1
  fi

  local ip port user identity
  ip="$(get_host_field "$src" "hostname")"
  port="$(get_host_field "$src" "port")"
  user="$(get_host_field "$src" "user")"
  identity="$(get_host_field "$src" "identityfile")"

  [[ -z "$port" ]]     && port="22"
  [[ -z "$user" ]]     && user="root"
  [[ -z "$identity" ]] && identity="$DEFAULT_IDENTITY"

  upsert_ssh_config "$dst" "$ip" "$user" "$port" "$identity"
  echo "✅ Duplicated '$src' → '$dst'"
}

# ── NEW: gsh ping <name> ─────────────────────────────────────────────────────
cmd_ping() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP ping <name>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi

  local hostname
  hostname="$(get_host_field "$name" "hostname")"
  local target="$hostname"

  if ! is_ip "$hostname"; then
    local ip
    ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
    [[ -n "$ip" ]] && target="$ip"
  fi

  echo "📡 Pinging $name ($target)..."
  if has_cmd ping; then
    ping -c 4 "$target"
  else
    echo "❌ ping not available."
    exit 1
  fi
}

# ── NEW: gsh test-all ────────────────────────────────────────────────────────
cmd_test_all() {
  local hosts
  mapfile -t hosts < <(list_hosts)

  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "No hosts configured."
    exit 0
  fi

  local ok=0 fail=0
  for h in "${hosts[@]}"; do
    printf "  %-30s" "$h"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
           "$h" true 2>/dev/null; then
      echo "✅ OK"
      (( ok++ )) || true
    else
      echo "❌ FAIL"
      (( fail++ )) || true
    fi
  done

  echo
  echo "Results: $ok ok, $fail failed (out of ${#hosts[@]})"
}

# ── NEW: gsh copy-id <name> ──────────────────────────────────────────────────
cmd_copy_id() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP copy-id <name>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi

  local identity
  identity="$(get_host_field "$name" "identityfile")"
  [[ -z "$identity" ]] && identity="$DEFAULT_IDENTITY"

  if [[ ! -f "${identity}.pub" ]]; then
    echo "❌ Public key not found: ${identity}.pub"
    exit 1
  fi

  echo "📤 Copying public key to $name..."
  ssh-copy-id -i "${identity}.pub" "$name"
  echo "✅ Done."
}

# ── NEW: gsh exec <name> <command...> ────────────────────────────────────────
cmd_exec() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP exec <name> <command>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  shift
  if [[ $# -eq 0 ]]; then
    echo "Usage: $APP exec <name> <command>"
    exit 1
  fi
  ssh "$name" "$@"
}

# ── NEW: gsh tunnel <name> <local_port>:<remote_host>:<remote_port> ──────────
cmd_tunnel() {
  local name="${1:-}" spec="${2:-}"
  if [[ -z "$name" || -z "$spec" ]]; then
    echo "Usage: $APP tunnel <name> <local_port>:<remote_host>:<remote_port>"
    echo "Example: $APP tunnel myserver 8080:localhost:80"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  echo "🚇 Tunnel: localhost:${spec%%:*} → ${spec#*:} via $name"
  echo "   Press Ctrl+C to stop."
  ssh -N -L "$spec" "$name"
}

# ── NEW: gsh keygen ───────────────────────────────────────────────────────────
cmd_keygen() {
  local path type comment
  path="$(prompt "Key path" "$DEFAULT_IDENTITY")"
  type="$(prompt "Key type (ed25519/rsa/ecdsa)" "ed25519")"
  comment="$(prompt "Comment" "$(whoami)@$(hostname)")"

  if [[ -f "$path" ]]; then
    if ! confirm_yn "⚠️  Key already exists at $path. Overwrite?"; then
      echo "Cancelled."
      exit 0
    fi
  fi

  ssh-keygen -t "$type" -f "$path" -C "$comment"
  echo
  echo "✅ Key generated: $path"
  echo "📋 Public key:"
  cat "${path}.pub"
}

# ── NEW: gsh key <name> [add|show|rm] ────────────────────────────────────────
cmd_key() {
  local sub="${1:-show}"

  case "$sub" in
    show|list)
      echo "🔑 SSH Keys in $SSH_DIR:"
      for f in "$SSH_DIR"/*.pub "$SSH_DIR"/**/*.pub 2>/dev/null; do
        [[ -f "$f" ]] || continue
        local keyfile="${f%.pub}"
        local exists=""
        [[ -f "$keyfile" ]] && exists="✅" || exists="⚠️  (private missing)"
        echo "  $exists ${f##$HOME/}"
        awk '{print "      " $1 " " substr($2,1,20) "... " $3}' "$f" 2>/dev/null || true
      done
      ;;
    add|gen|generate)
      cmd_keygen
      ;;
    fingerprint|fp)
      local kpath="${2:-$DEFAULT_IDENTITY}"
      if [[ -f "${kpath}.pub" ]]; then
        ssh-keygen -lf "${kpath}.pub"
      elif [[ -f "$kpath" ]]; then
        ssh-keygen -lf "$kpath"
      else
        echo "❌ Key not found: $kpath"
        exit 1
      fi
      ;;
    *)
      echo "Usage: $APP key [show|add|fingerprint <keypath>]"
      ;;
  esac
}

# ── NEW: gsh copy <src> <dst> (scp wrapper) ──────────────────────────────────
cmd_copy() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: $APP copy <src> <dst>"
    echo "Example: $APP copy myserver:/etc/nginx.conf ./nginx.conf"
    echo "Example: $APP copy ./file.txt myserver:/tmp/"
    exit 1
  fi
  scp -r "$@"
}

# ── NEW: gsh export [name] ───────────────────────────────────────────────────
cmd_export() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    if ! host_exists "$name"; then
      echo "❌ Host '$name' not found."
      exit 1
    fi
    awk -v h="Host $name" '
      $0==h{in_block=1; print; next}
      in_block && /^Host[[:space:]]/{in_block=0}
      in_block{print}
    ' "$SSH_CONFIG"
  else
    cat "$SSH_CONFIG"
  fi
}

# ── NEW: gsh import <file> ───────────────────────────────────────────────────
cmd_import() {
  local file="${1:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "Usage: $APP import <ssh_config_snippet>"
    exit 1
  fi

  local count=0
  local hosts
  mapfile -t hosts < <(awk '$1=="Host" && NF==2 && $2 !~ /[\*\?\[]/{print $2}' "$file")

  for h in "${hosts[@]}"; do
    if host_exists "$h"; then
      echo "⚠️  Skipping '$h' (already exists)"
    else
      cat "$file" >> "$SSH_CONFIG"
      (( count++ )) || true
      echo "✅ Imported '$h'"
    fi
  done

  chmod 600 "$SSH_CONFIG"
  echo "Done. $count host(s) imported."
}

# ── NEW: gsh tag <name> <tag> / untag / ls-tags ──────────────────────────────
GSH_TAGS_FILE="$SSH_DIR/.gsh.tags"

cmd_tag() {
  local name="${1:-}" tag="${2:-}"
  if [[ -z "$name" || -z "$tag" ]]; then
    echo "Usage: $APP tag <name> <tag>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  touch "$GSH_TAGS_FILE"
  # Remove existing then re-add
  grep -v "^$name " "$GSH_TAGS_FILE" > "${GSH_TAGS_FILE}.tmp" || true
  # Merge existing tags with new one
  local existing
  existing="$(grep "^$name " "$GSH_TAGS_FILE" | cut -d' ' -f2- || true)"
  local merged
  if [[ -n "$existing" ]]; then
    merged="$existing $tag"
  else
    merged="$tag"
  fi
  echo "$name $merged" >> "${GSH_TAGS_FILE}.tmp"
  mv "${GSH_TAGS_FILE}.tmp" "$GSH_TAGS_FILE"
  chmod 600 "$GSH_TAGS_FILE"
  echo "✅ Tagged '$name' with '$tag'"
}

cmd_untag() {
  local name="${1:-}" tag="${2:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP untag <name> [tag]"
    exit 1
  fi
  touch "$GSH_TAGS_FILE"
  if [[ -n "$tag" ]]; then
    awk -v h="$name" -v t="$tag" '
      $1==h {
        printf $1
        for(i=2;i<=NF;i++) if($i!=t) printf " " $i
        print ""
        next
      }
      {print}
    ' "$GSH_TAGS_FILE" > "${GSH_TAGS_FILE}.tmp"
  else
    grep -v "^$name " "$GSH_TAGS_FILE" > "${GSH_TAGS_FILE}.tmp" || true
  fi
  mv "${GSH_TAGS_FILE}.tmp" "$GSH_TAGS_FILE"
  chmod 600 "$GSH_TAGS_FILE"
  echo "✅ Untagged '$name'"
}

cmd_ls_tags() {
  local filter="${1:-}"
  if [[ ! -f "$GSH_TAGS_FILE" ]]; then
    echo "No tags defined."
    return
  fi

  if [[ -n "$filter" ]]; then
    echo "🏷  Hosts tagged '$filter':"
    awk -v t="$filter" '
      {for(i=2;i<=NF;i++) if($i==t){print "  " $1; break}}
    ' "$GSH_TAGS_FILE"
  else
    echo "🏷  All tags:"
    awk '{
      for(i=2;i<=NF;i++) print "  " $1 "\t" $i
    }' "$GSH_TAGS_FILE" | column -t
  fi
}

# ── NEW: gsh health <name> ───────────────────────────────────────────────────
cmd_health() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP health <name>"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi

  local hostname port
  hostname="$(get_host_field "$name" "hostname")"
  port="$(get_host_field "$name" "port")"
  [[ -z "$port" ]] && port="22"

  echo "🏥 Health check: $name ($hostname:$port)"
  echo

  # Ping
  printf "  %-20s" "Ping:"
  local ip="$hostname"
  if ! is_ip "$hostname"; then
    ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
  fi
  if [[ -n "$ip" ]] && ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
    echo "✅ Reachable ($ip)"
  else
    echo "❌ Unreachable"
  fi

  # TCP port
  printf "  %-20s" "TCP port $port:"
  if has_cmd nc; then
    if nc -z -w3 "$hostname" "$port" 2>/dev/null; then
      echo "✅ Open"
    else
      echo "❌ Closed / filtered"
    fi
  else
    echo "⚠️  nc not available"
  fi

  # SSH login
  printf "  %-20s" "SSH login:"
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$name" true 2>/dev/null; then
    echo "✅ OK"
  else
    echo "❌ Failed"
  fi

  # Uptime (if ssh works)
  printf "  %-20s" "Uptime:"
  local up
  up="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$name" uptime 2>/dev/null || echo "")"
  if [[ -n "$up" ]]; then
    echo "$up"
  else
    echo "N/A"
  fi
}

# ── NEW: gsh logs <name> [lines] ─────────────────────────────────────────────
cmd_logs() {
  local name="${1:-}" lines="${2:-50}"
  if [[ -z "$name" ]]; then
    echo "Usage: $APP logs <name> [lines]"
    exit 1
  fi
  if ! host_exists "$name"; then
    echo "❌ Host '$name' not found."
    exit 1
  fi
  echo "📜 Last $lines lines of auth log on $name:"
  ssh "$name" "
    if [[ -f /var/log/auth.log ]]; then
      tail -n $lines /var/log/auth.log
    elif [[ -f /var/log/secure ]]; then
      tail -n $lines /var/log/secure
    else
      journalctl -u sshd -n $lines --no-pager 2>/dev/null || echo 'No SSH log found.'
    fi
  "
}

# ── Backup / Restore ──────────────────────────────────────────────────────────

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
    echo "❌ curl not found." >&2
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

  printf "created_at=%s\nhost=%s\nuser=%s\n" "$(date -Is)" "$(hostname)" "$(whoami)" \
    > "$tmpdir/meta/info.txt"

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

  local ts tmpdir
  ts="$(date +%Y%m%d-%H%M%S)"
  tmpdir="$(mktemp -d)"

  unzip_decrypt "$zip_path" "$tmpdir" "$pass"

  if [[ ! -d "$tmpdir/home/.ssh" && ! -d "$tmpdir/home/bin" ]]; then
    echo "❌ Backup structure invalid."
    rm -rf "$tmpdir"
    exit 1
  fi

  if [[ -d "$HOME/.ssh" ]]; then
    local ssh_bak="$HOME/.ssh.bak.$ts"
    mv "$HOME/.ssh" "$ssh_bak"
    echo "✅ Moved current ~/.ssh → $ssh_bak"
  fi
  if [[ -d "$HOME/bin" ]]; then
    local bin_bak="$HOME/bin.bak.$ts"
    mv "$HOME/bin" "$bin_bak"
    echo "✅ Moved current ~/bin → $bin_bak"
  fi

  mkdir -p "$HOME/.ssh" "$HOME/bin"
  chmod 700 "$HOME/.ssh"
  [[ -d "$tmpdir/home/.ssh" ]] && cp -a "$tmpdir/home/.ssh/." "$HOME/.ssh/"
  [[ -d "$tmpdir/home/bin"  ]] && cp -a "$tmpdir/home/bin/."  "$HOME/bin/"

  chmod 700 "$HOME/.ssh" || true
  [[ -f "$HOME/.ssh/config" ]]          && chmod 600 "$HOME/.ssh/config"
  [[ -f "$HOME/.ssh/authorized_keys" ]] && chmod 600 "$HOME/.ssh/authorized_keys"
  [[ -f "$HOME/.ssh/.gsh.env" ]]        && chmod 600 "$HOME/.ssh/.gsh.env"
  [[ -f "$HOME/bin/gsh" ]]              && chmod +x  "$HOME/bin/gsh"

  rm -rf "$tmpdir"
  echo "✅ Restore complete."
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
GlyNet Shell (gsh) — SSH manager

Connection:
  gsh <name>                      Connect to host
  gsh exec <name> <cmd>           Run command on host
  gsh tunnel <name> <lp>:<rh>:<rp>  Local port-forward tunnel
  gsh copy <src> <dst>            SCP file copy (supports host:path)

Host management:
  gsh add [name]                  Add a new host
  gsh update [name]               Update host (keeps existing values as defaults)
  gsh rm <name>                   Remove host
  gsh rename <old> <new>          Rename host alias
  gsh duplicate <src> <new>       Duplicate host entry
  gsh ls                          List all hosts
  gsh sort                        Sort config alphabetically
  gsh info <name>                 Show host details

Keys:
  gsh key show                    List all SSH keys
  gsh key add                     Generate a new SSH key
  gsh key fingerprint [keypath]   Show key fingerprint
  gsh copy-id <name>              Push public key to host (ssh-copy-id)

Diagnostics:
  gsh ping <name>                 Ping host
  gsh health <name>               Full health check (ping / tcp / ssh / uptime)
  gsh test-all                    Test SSH connectivity to all hosts
  gsh logs <name> [lines]         Tail SSH auth log on remote host

Tags:
  gsh tag <name> <tag>            Tag a host
  gsh untag <name> [tag]          Remove tag (or all tags)
  gsh ls-tags [tag]               List tags (or hosts with a given tag)

Backup / Restore:
  gsh backup                      Backup ~/.ssh and ~/bin (encrypted zip)
  gsh restore <backup.zip>        Restore from backup

Config:
  gsh init                        Configure gsh settings
  gsh export [name]               Print config (or one host block) to stdout
  gsh import <file>               Import host blocks from a config snippet

  Config file: ~/.ssh/.gsh.env
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    add)        shift; cmd_add "${1:-}" ;;
    update)     shift; cmd_update "${1:-}" ;;
    rm|remove)  shift; cmd_rm "${1:-}" ;;
    rename)     shift; cmd_rename "${1:-}" "${2:-}" ;;
    duplicate)  shift; cmd_duplicate "${1:-}" "${2:-}" ;;
    ls|list)    list_hosts ;;
    sort)       sort_config ;;
    init)       cmd_init ;;
    info)       shift; cmd_info "${1:-}" ;;
    ping)       shift; cmd_ping "${1:-}" ;;
    health)     shift; cmd_health "${1:-}" ;;
    test-all)   cmd_test_all ;;
    exec)       shift; cmd_exec "$@" ;;
    tunnel)     shift; cmd_tunnel "${1:-}" "${2:-}" ;;
    copy)       shift; cmd_copy "$@" ;;
    copy-id)    shift; cmd_copy_id "${1:-}" ;;
    key)        shift; cmd_key "${1:-show}" "${2:-}" ;;
    keygen)     cmd_keygen ;;
    export)     shift; cmd_export "${1:-}" ;;
    import)     shift; cmd_import "${1:-}" ;;
    tag)        shift; cmd_tag "${1:-}" "${2:-}" ;;
    untag)      shift; cmd_untag "${1:-}" "${2:-}" ;;
    ls-tags)    shift; cmd_ls_tags "${1:-}" ;;
    logs)       shift; cmd_logs "${1:-}" "${2:-50}" ;;
    backup)     cmd_backup ;;
    restore)    shift; cmd_restore "${1:-}" ;;
    ""|-h|--help) usage ;;
    *)
      connect_with_resolve_if_needed "$1"
      ;;
  esac
}

main "$@"
