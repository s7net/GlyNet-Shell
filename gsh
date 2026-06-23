#!/usr/bin/env bash
set -euo pipefail

APP="gsh"
VERSION="2.2.0"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
GSH_ENV_FILE="$SSH_DIR/.gsh.env"
GSH_TAGS_FILE="$SSH_DIR/.gsh.tags"

BIN_DIR="$HOME/bin"

mkdir -p "$SSH_DIR" "$BIN_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# ── Defaults (overridden by GSH_ENV_FILE) ────────────────────────────────────
DEFAULT_IDENTITY="$HOME/.ssh/id_ed25519"
SETUP_SSH_URL="https://scripts.glynet.org/setup-ssh.sh"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
BACKUP_ZIP_PASS=""
RESOLVE_HOST_BEFORE_CONNECT="1"
RESOLVE_PREFER="ipv4"   # ipv4 | ipv6 | any

if [[ -f "$GSH_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$GSH_ENV_FILE"
fi

# ── UI helpers ────────────────────────────────────────────────────────────────
# FIX: avoid process substitution for colors (breaks in jailed shells lacking /dev/fd)
# Colors are stored as variables and printed directly — no subshell needed.

if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_RED='\033[31m'
  C_CYAN='\033[36m'
  C_BLUE='\033[34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW=''
  C_RED=''   C_CYAN='' C_BLUE=''
fi

ok()   { printf "${C_GREEN}✅${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}⚠️ ${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}❌${C_RESET} %s\n" "$*" >&2; }
info() { printf "${C_CYAN}ℹ️ ${C_RESET} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

divider() {
  local label="${1:-}"
  if [[ -n "$label" ]]; then
    printf "${C_DIM}── %s ──────────────────────────────────────${C_RESET}\n" "$label"
  else
    printf "${C_DIM}────────────────────────────────────────────${C_RESET}\n"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local label="$1" default="${2:-}"
  local v
  if [[ -n "$default" ]]; then
    printf "${C_BOLD}%s${C_RESET} [${C_DIM}%s${C_RESET}]: " "$label" "$default" >&2
    read -r v
    echo "${v:-$default}"
  else
    printf "${C_BOLD}%s${C_RESET}: " "$label" >&2
    read -r v
    echo "$v"
  fi
}

prompt_secret() {
  local label="$1" default="${2:-}"
  local v
  if [[ -n "$default" ]]; then
    printf "${C_BOLD}%s${C_RESET} [${C_DIM}set${C_RESET}]: " "$label" >&2
    read -r -s v
    echo >&2
    echo "${v:-$default}"
  else
    printf "${C_BOLD}%s${C_RESET}: " "$label" >&2
    read -r -s v
    echo >&2
    echo "$v"
  fi
}

confirm_yn() {
  local q="$1" default="${2:-}"
  local ans prompt_str
  case "${default,,}" in
    y) prompt_str="[Y/n]" ;;
    n) prompt_str="[y/N]" ;;
    *) prompt_str="[y/n]" ;;
  esac
  while true; do
    printf "${C_BOLD}%s${C_RESET} %s: " "$q" "$prompt_str" >&2
    read -r ans
    [[ -z "$ans" && -n "$default" ]] && ans="$default"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

# ── Env persistence ───────────────────────────────────────────────────────────

save_gsh_env() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  {
    echo "DEFAULT_IDENTITY=$(printf '%s' "$DEFAULT_IDENTITY" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    echo "SETUP_SSH_URL=$(printf '%s'   "$SETUP_SSH_URL"     | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    echo "TG_BOT_TOKEN=$(printf '%s'    "$TG_BOT_TOKEN"      | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    echo "TG_CHAT_ID=$(printf '%s'      "$TG_CHAT_ID"        | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    echo "BACKUP_ZIP_PASS=$(printf '%s' "$BACKUP_ZIP_PASS"   | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    echo "RESOLVE_HOST_BEFORE_CONNECT='$RESOLVE_HOST_BEFORE_CONNECT'"
    echo "RESOLVE_PREFER='$RESOLVE_PREFER'"
  } > "$GSH_ENV_FILE"
  chmod 600 "$GSH_ENV_FILE"
  umask "$old_umask"
}

# ── SSH Config low-level helpers ──────────────────────────────────────────────

host_exists() {
  local name="$1"
  awk -v h="Host $name" '$0==h{found=1} END{exit !found}' "$SSH_CONFIG" 2>/dev/null
}

get_host_field() {
  local name="$1" field="$2"
  awk -v h="Host $name" -v f="$field" '
    $0==h          { in_block=1; next }
    in_block && /^Host[[:space:]]/ { in_block=0 }
    in_block {
      gsub(/^[[:space:]]+/, "")
      if (tolower($1) == tolower(f)) { print $2; exit }
    }
  ' "$SSH_CONFIG" 2>/dev/null
}

upsert_ssh_config() {
  local name="$1" host="$2" user="$3" port="$4" identity="$5"
  local tmp
  tmp="$(mktemp)"

  awk -v h="Host $name" '
    BEGIN { skip=0 }
    /^Host[[:space:]]+/ { skip = ($0 == h) ? 1 : 0; if (skip) next }
    !skip { print }
  ' "$SSH_CONFIG" | sed -e 's/[[:space:]]*$//' | \
    awk 'BEGIN{bl=0} /^$/{bl++; next} {while(bl-->0) print ""; bl=0; print}' \
    > "$tmp"

  printf '\nHost %s\n'           "$name"     >> "$tmp"
  printf '  HostName %s\n'       "$host"     >> "$tmp"
  printf '  User %s\n'           "$user"     >> "$tmp"
  printf '  Port %s\n'           "$port"     >> "$tmp"
  printf '  IdentityFile %s\n'   "$identity" >> "$tmp"
  printf '  PreferredAuthentications publickey,password\n' >> "$tmp"
  printf '  ServerAliveInterval 30\n'        >> "$tmp"
  printf '  ServerAliveCountMax 3\n'         >> "$tmp"
  printf '  StrictHostKeyChecking accept-new\n' >> "$tmp"

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
}

remove_host() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v h="Host $name" '
    BEGIN { skip=0 }
    /^Host[[:space:]]+/ { skip = ($0 == h) ? 1 : 0; if (skip) next }
    !skip { print }
  ' "$SSH_CONFIG" > "$tmp"
  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
}

list_hosts() {
  awk '
    $1=="Host" && NF>=2 {
      for (i=2; i<=NF; i++) {
        h = $i
        if (h ~ /[\*\?\[]/) continue
        print h
      }
    }
  ' "$SSH_CONFIG" | sort -fu
}

sort_config() {
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { inhost=0 }
    /^Host[[:space:]]+/ { inhost=1 }
    !inhost { print }
  ' "$SSH_CONFIG" > "$tmp"

  awk '
    function flush() {
      if (block != "") {
        split(first, a, /[[:space:]]+/)
        if (a[2] != "") print a[2] "\t" block
      }
      block = ""; first = ""
    }
    BEGIN { block=""; first="" }
    /^Host[[:space:]]+/ { flush(); first=$0; block=$0 "\n"; next }
    first != ""          { block = block $0 "\n" }
    END { flush() }
  ' "$SSH_CONFIG" | sort -f | cut -f2- >> "$tmp"

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  ok "Sorted ~/.ssh/config"
}

# ── Network helpers ───────────────────────────────────────────────────────────

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

resolve_fresh_ip() {
  local host="$1" prefer="${2:-ipv4}" ip=""

  if has_cmd getent; then
    case "$prefer" in
      ipv4) ip="$(getent ahosts "$host" 2>/dev/null | awk '$1~/^[0-9]+\./{print $1;exit}')" ;;
      ipv6) ip="$(getent ahosts "$host" 2>/dev/null | awk '$1~/:/{print $1;exit}')" ;;
      *)    ip="$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1;exit}')" ;;
    esac
  fi

  if [[ -z "$ip" ]] && has_cmd host; then
    case "$prefer" in
      ipv4) ip="$(host -t A    "$host" 2>/dev/null | awk '/has address/{print $NF;exit}')" ;;
      ipv6) ip="$(host -t AAAA "$host" 2>/dev/null | awk '/has IPv6/{print $NF;exit}')" ;;
      *)    ip="$(host         "$host" 2>/dev/null | awk '/has address/{print $NF;exit}')" ;;
    esac
  fi

  echo "$ip"
}

# ── SSH connection logic ──────────────────────────────────────────────────────

ssh_try_connect() {
  local alias="$1" hostname="${2:-}" ip="${3:-}"
  local err tmp rc

  tmp="$(mktemp)"
  set +e
  ssh "$alias" 2>"$tmp"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then rm -f "$tmp"; return 0; fi

  err="$(cat "$tmp")"; rm -f "$tmp"

  if echo "$err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED\|Host key verification failed"; then
    echo
    warn "SSH host key changed for: ${C_BOLD}${alias}${C_RESET}"
    [[ -n "$hostname" ]] && info "Hostname : $hostname"
    [[ -n "$ip"       ]] && info "Target IP: $ip"
    echo
    info "This usually means the server was reinstalled or the IP was reassigned."

    if confirm_yn "Remove old known_hosts entries and retry?" "n"; then
      echo "🧹 Cleaning known_hosts entries..."
      ssh-keygen -R "$alias"    >/dev/null 2>&1 || true
      [[ -n "$hostname" ]] && ssh-keygen -R "$hostname" >/dev/null 2>&1 || true
      if [[ -n "$ip" ]]; then
        ssh-keygen -R "$ip" >/dev/null 2>&1 || true
        local port
        port="$(ssh -G "$alias" 2>/dev/null | awk '$1=="port"{print $2;exit}')"
        [[ -n "${port:-}" ]] && ssh-keygen -R "[$ip]:$port" >/dev/null 2>&1 || true
      fi
      ok "Old keys removed. Retrying..."
      exec ssh "$alias"
    else
      err "Connection aborted."
      return 255
    fi
  fi

  echo "$err" >&2
  return "$rc"
}

connect_with_resolve_if_needed() {
  local alias="$1"

  if ! host_exists "$alias"; then
    err "Unknown host: '${C_BOLD}${alias}${C_RESET}'"
    info "Use 'gsh ls' to list hosts, or 'gsh add $alias' to add it."
    exit 1
  fi

  local hostname
  hostname="$(ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2;exit}')"

  if [[ -z "$hostname" ]]; then
    ssh_try_connect "$alias" "" ""
    exit $?
  fi

  if [[ "$RESOLVE_HOST_BEFORE_CONNECT" != "1" ]] || is_ip "$hostname"; then
    ssh_try_connect "$alias" "$hostname" ""
    exit $?
  fi

  local ip
  ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
  if [[ -z "$ip" ]]; then
    warn "Could not resolve '$hostname', connecting anyway..."
    ssh_try_connect "$alias" "$hostname" ""
    exit $?
  fi

  set +e
  ssh -o HostName="$ip" -o HostKeyAlias="$hostname" -o CheckHostIP=yes "$alias"
  local rc=$?
  set -e

  [[ $rc -eq 0 ]] && exit 0

  ssh_try_connect "$alias" "$hostname" "$ip"
  exit $?
}

# ── cmd: init ────────────────────────────────────────────────────────────────

cmd_init() {
  divider "GSH Configuration"
  echo
  DEFAULT_IDENTITY="$(prompt    "Default identity path"            "$DEFAULT_IDENTITY")"
  SETUP_SSH_URL="$(prompt       "Setup script URL"                 "$SETUP_SSH_URL")"
  echo
  TG_BOT_TOKEN="$(prompt_secret "Telegram bot token (optional)"    "$TG_BOT_TOKEN")"
  TG_CHAT_ID="$(prompt          "Telegram chat_id (optional)"      "$TG_CHAT_ID")"
  BACKUP_ZIP_PASS="$(prompt_secret "Backup ZIP password"           "$BACKUP_ZIP_PASS")"
  echo
  RESOLVE_HOST_BEFORE_CONNECT="$(prompt "Resolve hostname before connect? (1/0)" "$RESOLVE_HOST_BEFORE_CONNECT")"
  RESOLVE_PREFER="$(prompt              "Resolve prefer (ipv4/ipv6/any)"          "$RESOLVE_PREFER")"
  echo
  save_gsh_env
  ok "Saved: $GSH_ENV_FILE"
}

# ── Key picker (shared helper) ────────────────────────────────────────────────
# Prints the chosen identity path to stdout.
# Usage: pick_identity [current_default]
pick_identity() {
  local default="${1:-$DEFAULT_IDENTITY}"
  local keys=()
  local f

  # Collect all pub keys found in SSH_DIR
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    keys+=("${f%.pub}")
  done < <(find "$SSH_DIR" -maxdepth 2 -name "*.pub" 2>/dev/null | sort)

  if [[ ${#keys[@]} -eq 0 ]]; then
    # No keys found — fall back to prompt
    prompt "Identity file" "$default"
    return
  fi

  echo >&2
  printf "${C_BOLD}  Select SSH key:${C_RESET}\n" >&2

  local i=1
  for k in "${keys[@]}"; do
    local fp="" mark=" "
    fp="$(ssh-keygen -lf "${k}.pub" 2>/dev/null | awk '{print $2, $4}' || true)"
    [[ "$k" == "$default" ]] && mark="${C_GREEN}*${C_RESET}"
    printf "  ${C_BOLD}[%d]${C_RESET} %b %-40s ${C_DIM}%s${C_RESET}\n" \
      "$i" "$mark" "$k" "$fp" >&2
    (( i++ )) || true
  done
  printf "  ${C_BOLD}[%d]${C_RESET}   Enter path manually\n" "$i" >&2
  echo >&2

  local choice
  while true; do
    printf "${C_BOLD}Choice${C_RESET} [${C_DIM}1${C_RESET}]: " >&2
    read -r choice
    [[ -z "$choice" ]] && choice=1
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice <= ${#keys[@]} )); then
        echo "${keys[$((choice-1))]}"
        return
      elif (( choice == i )); then
        prompt "Identity file" "$default"
        return
      fi
    fi
    warn "Please enter a number between 1 and $i." >&2
  done
}

# ── cmd: add ─────────────────────────────────────────────────────────────────

cmd_add() {
  local name="${1:-}"
  divider "Add Host"
  echo

  [[ -z "$name" ]] && name="$(prompt "Alias name")"
  [[ -z "$name" ]] && die "Alias name is required."

  if host_exists "$name"; then
    warn "Host '$name' already exists."
    confirm_yn "Overwrite?" "n" || { echo "Cancelled."; exit 0; }
  fi

  local ip port user identity
  ip="$(prompt   "IP / Hostname"  "")"
  port="$(prompt "Port"           "22")"
  user="$(prompt "User"           "root")"

  # Interactive key picker
  identity="$(pick_identity "$DEFAULT_IDENTITY")"

  [[ -z "$ip" ]] && die "IP / Hostname is required."

  if [[ ! -f "${identity}.pub" ]]; then
    err "Public key missing → ${identity}.pub"
    info "Generate one with: gsh key add"
    exit 1
  fi

  local pub
  pub="$(cat "${identity}.pub")"
  upsert_ssh_config "$name" "$ip" "$user" "$port" "$identity"

  echo
  ok "Host '$name' added."
  divider "Next step"
  echo "  Run this on the server as root (after password login):"
  echo
  printf "  ${C_CYAN}%s${C_RESET}\n" \
    "curl -fsSL $SETUP_SSH_URL | bash -s -- '$pub'"
  echo
}

# ── cmd: update ──────────────────────────────────────────────────────────────

cmd_update() {
  local name="${1:-}"
  [[ -z "$name" ]] && name="$(prompt "Host alias to update")"
  [[ -z "$name" ]] && die "Alias is required."
  host_exists "$name" || die "Host '$name' not found. Use 'gsh add $name' to create it."

  divider "Update: $name"
  echo

  local cur_ip cur_port cur_user cur_identity
  cur_ip="$(get_host_field       "$name" "hostname")"
  cur_port="$(get_host_field     "$name" "port")"
  cur_user="$(get_host_field     "$name" "user")"
  cur_identity="$(get_host_field "$name" "identityfile")"
  [[ -z "$cur_port"     ]] && cur_port="22"
  [[ -z "$cur_user"     ]] && cur_user="root"
  [[ -z "$cur_identity" ]] && cur_identity="$DEFAULT_IDENTITY"

  info "Press Enter to keep current value."
  echo

  local ip port user identity
  ip="$(prompt   "IP / Hostname"  "$cur_ip")"
  port="$(prompt "Port"           "$cur_port")"
  user="$(prompt "User"           "$cur_user")"

  # Interactive key picker (current key pre-selected)
  identity="$(pick_identity "$cur_identity")"

  [[ -z "$ip" ]] && die "IP / Hostname is required."

  upsert_ssh_config "$name" "$ip" "$user" "$port" "$identity"
  ok "Updated '$name'"
}

# ── cmd: rm ──────────────────────────────────────────────────────────────────

cmd_rm() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP rm <name>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."
  confirm_yn "Remove host '${C_BOLD}${name}${C_RESET}'?" "n" || { echo "Cancelled."; exit 0; }
  remove_host "$name"
  ok "Removed '$name'"
}

# ── cmd: ls ──────────────────────────────────────────────────────────────────

cmd_ls() {
  local host_list
  host_list="$(list_hosts)"

  if [[ -z "$host_list" ]]; then
    info "No hosts configured. Use 'gsh add' to add one."
    return
  fi

  local count
  count="$(echo "$host_list" | wc -l | tr -d ' ')"
  divider "Hosts ($count)"
  echo

  echo "$host_list" | while IFS= read -r h; do
    local hostname port user identity tags_str="" identity_short="" resolved_ip=""
    hostname="$(get_host_field  "$h" "hostname")"
    port="$(get_host_field      "$h" "port")"
    user="$(get_host_field      "$h" "user")"
    identity="$(get_host_field  "$h" "identityfile")"
    [[ -z "$port"     ]] && port="22"
    [[ -z "$user"     ]] && user="root"
    [[ -z "$identity" ]] && identity="$DEFAULT_IDENTITY"

    identity_short="$(basename "${identity%.pub}")"

    # Resolve IP for hostnames (not raw IPs)
    if ! is_ip "$hostname"; then
      resolved_ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER" 2>/dev/null || true)"
    fi

    # Tags
    if [[ -f "$GSH_TAGS_FILE" ]]; then
      local raw
      raw="$(awk -v hh="$h" '$1==hh{$1=""; print}' "$GSH_TAGS_FILE" | xargs)"
      [[ -n "$raw" ]] && tags_str="$raw"
    fi

    # ── Row: alias  user@host:port  key  [tags]
    #   alias (bold, fixed 12 chars) │ connection string │ key (dim)
    local conn="${user}@${hostname}"
    [[ "$port" != "22" ]] && conn="${conn}:${port}"

    printf "  ${C_BOLD}%-14s${C_RESET}  ${C_CYAN}%s${C_RESET}" "$h" "$conn"

    # Port badge only when non-default
    [[ "$port" != "22" ]] || printf "  ${C_DIM}:22${C_RESET}"

    # Resolved IP inline (only for hostnames)
    if [[ -n "$resolved_ip" && "$resolved_ip" != "$hostname" ]]; then
      printf "  ${C_DIM}→ %s${C_RESET}" "$resolved_ip"
    fi

    echo

    # Second line: key + tags (indented under alias)
    local line2="  ${C_DIM}              🔑 ${identity_short}${C_RESET}"
    [[ -n "$tags_str" ]] && line2="${line2}  ${C_DIM}[${tags_str}]${C_RESET}"
    printf "%b\n" "$line2"

    echo
  done

  local key_count=0
  key_count="$(find "$SSH_DIR" -maxdepth 2 -name "*.pub" 2>/dev/null | wc -l | tr -d ' ')"
  printf "  ${C_DIM}%d hosts  ·  %d keys  ·  %s${C_RESET}\n" "$count" "$key_count" "$SSH_CONFIG"
  echo
}

# ── cmd: info ────────────────────────────────────────────────────────────────

cmd_info() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP info <name>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."

  divider "Info: $name"
  echo

  local hostname port user identity
  hostname="$(get_host_field  "$name" "hostname")"
  port="$(get_host_field      "$name" "port")"
  user="$(get_host_field      "$name" "user")"
  identity="$(get_host_field  "$name" "identityfile")"

  printf "  %-14s ${C_BOLD}%s${C_RESET}\n"  "Alias:"    "$name"
  printf "  %-14s %s\n"                      "HostName:" "$hostname"
  printf "  %-14s %s\n"                      "User:"     "$user"
  printf "  %-14s %s\n"                      "Port:"     "$port"
  printf "  %-14s %s\n"                      "Identity:" "$identity"

  # Resolved IP
  if [[ -n "$hostname" ]] && ! is_ip "$hostname"; then
    local rip
    rip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER" 2>/dev/null || true)"
    [[ -n "$rip" ]] && printf "  %-14s %s\n" "Resolved IP:" "$rip"
  fi

  # Tags
  if [[ -f "$GSH_TAGS_FILE" ]]; then
    local tags
    tags="$(awk -v h="$name" '$1==h{$1=""; print}' "$GSH_TAGS_FILE" | xargs)"
    [[ -n "$tags" ]] && printf "  %-14s %s\n" "Tags:" "$tags"
  fi

  # Key fingerprint
  if [[ -n "$identity" && -f "${identity}.pub" ]]; then
    local fp
    fp="$(ssh-keygen -lf "${identity}.pub" 2>/dev/null | awk '{print $2, $4}')"
    [[ -n "$fp" ]] && printf "  %-14s %s\n" "Fingerprint:" "$fp"
  fi

  echo
}

# ── cmd: rename ──────────────────────────────────────────────────────────────

cmd_rename() {
  local old="${1:-}" new="${2:-}"
  [[ -z "$old" || -z "$new" ]] && { err "Usage: $APP rename <old> <new>"; exit 1; }
  host_exists "$old" || die "Host '$old' not found."
  host_exists "$new" && die "Host '$new' already exists."

  local tmp
  tmp="$(mktemp)"
  awk -v old="Host $old" -v new="Host $new" \
    '$0==old{print new; next} {print}' "$SSH_CONFIG" > "$tmp"
  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  if [[ -f "$GSH_TAGS_FILE" ]]; then
    local ttmp
    ttmp="$(mktemp)"
    awk -v old="$old" -v new="$new" '$1==old{$1=new} {print}' "$GSH_TAGS_FILE" > "$ttmp"
    mv "$ttmp" "$GSH_TAGS_FILE"
    chmod 600 "$GSH_TAGS_FILE"
  fi

  ok "Renamed '$old' → '$new'"
}

# ── cmd: duplicate ───────────────────────────────────────────────────────────

cmd_duplicate() {
  local src="${1:-}" dst="${2:-}"
  [[ -z "$src" || -z "$dst" ]] && { err "Usage: $APP duplicate <source> <new-name>"; exit 1; }
  host_exists "$src" || die "Host '$src' not found."
  host_exists "$dst" && die "Host '$dst' already exists."

  local ip port user identity
  ip="$(get_host_field       "$src" "hostname")"
  port="$(get_host_field     "$src" "port")"
  user="$(get_host_field     "$src" "user")"
  identity="$(get_host_field "$src" "identityfile")"
  [[ -z "$port"     ]] && port="22"
  [[ -z "$user"     ]] && user="root"
  [[ -z "$identity" ]] && identity="$DEFAULT_IDENTITY"

  upsert_ssh_config "$dst" "$ip" "$user" "$port" "$identity"
  ok "Duplicated '$src' → '$dst'"
}

# ── cmd: ping ────────────────────────────────────────────────────────────────

cmd_ping() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP ping <name>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."

  local hostname target
  hostname="$(get_host_field "$name" "hostname")"
  target="$hostname"

  if ! is_ip "$hostname"; then
    local ip
    ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
    [[ -n "$ip" ]] && target="$ip"
  fi

  info "Pinging $name ($target)..."
  has_cmd ping || die "ping is not available on this system."
  ping -c 4 "$target"
}

# ── cmd: test-all ────────────────────────────────────────────────────────────

cmd_test_all() {
  local hosts=()
  # FIX: avoid mapfile; use while+read for jailed shell compatibility
  while IFS= read -r h; do
    [[ -n "$h" ]] && hosts+=("$h")
  done < <(list_hosts)

  if [[ ${#hosts[@]} -eq 0 ]]; then
    info "No hosts configured."
    return
  fi

  divider "SSH Connectivity Test"
  printf "  ${C_BOLD}%-28s %-10s %s${C_RESET}\n" "HOST" "STATUS" "LATENCY"
  divider

  local ok_n=0 fail_n=0
  for h in "${hosts[@]}"; do
    printf "  %-28s" "$h"
    local t_start t_end ms
    t_start="$(date +%s%3N 2>/dev/null || date +%s)"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
           "$h" true 2>/dev/null; then
      t_end="$(date +%s%3N 2>/dev/null || date +%s)"
      ms=$(( t_end - t_start ))
      printf "${C_GREEN}%-10s${C_RESET} %dms\n" "OK" "$ms"
      (( ok_n++   )) || true
    else
      printf "${C_RED}%s${C_RESET}\n" "FAIL"
      (( fail_n++ )) || true
    fi
  done

  divider
  printf "  Total: %d  |  ${C_GREEN}%d ok${C_RESET}  |  ${C_RED}%d failed${C_RESET}\n" \
    "${#hosts[@]}" "$ok_n" "$fail_n"
  echo
}

# ── cmd: copy-id ─────────────────────────────────────────────────────────────

cmd_copy_id() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP copy-id <name>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."

  local identity
  identity="$(get_host_field "$name" "identityfile")"
  [[ -z "$identity" ]] && identity="$DEFAULT_IDENTITY"

  [[ -f "${identity}.pub" ]] || die "Public key not found: ${identity}.pub"

  info "Copying public key to $name..."
  ssh-copy-id -i "${identity}.pub" "$name"
  ok "Done."
}

# ── cmd: exec ────────────────────────────────────────────────────────────────

cmd_exec() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP exec <name> <command>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."
  shift
  [[ $# -eq 0 ]] && { err "Usage: $APP exec <name> <command>"; exit 1; }
  ssh "$name" -- "$@"
}

# ── cmd: tunnel ──────────────────────────────────────────────────────────────

cmd_tunnel() {
  local name="${1:-}" spec="${2:-}"
  if [[ -z "$name" || -z "$spec" ]]; then
    err "Usage: $APP tunnel <name> <local_port>:<remote_host>:<remote_port>"
    info "Example: gsh tunnel myserver 8080:localhost:80"
    exit 1
  fi
  host_exists "$name" || die "Host '$name' not found."

  [[ "$spec" =~ ^[0-9]+:.+:[0-9]+$ ]] || die "Invalid tunnel spec. Expected: localport:remotehost:remoteport"

  local lport remote
  lport="${spec%%:*}"
  remote="${spec#*:}"

  info "Tunnel: localhost:$lport → $remote via $name"
  info "Press Ctrl+C to stop."
  echo
  ssh -N -L "$spec" "$name"
}

# ── cmd: keygen ──────────────────────────────────────────────────────────────

cmd_keygen() {
  divider "Generate SSH Key"
  echo
  local kpath ktype comment
  kpath="$(prompt   "Key path"                       "$DEFAULT_IDENTITY")"
  ktype="$(prompt   "Key type (ed25519/rsa/ecdsa)"   "ed25519")"
  comment="$(prompt "Comment"                         "$(whoami)@$(hostname)")"

  if [[ -f "$kpath" ]]; then
    warn "Key already exists at $kpath"
    confirm_yn "Overwrite?" "n" || { echo "Cancelled."; exit 0; }
  fi

  echo
  ssh-keygen -t "$ktype" -f "$kpath" -C "$comment"
  echo
  ok "Key generated: $kpath"
  echo
  info "Public key:"
  cat "${kpath}.pub"
}

# ── cmd: key ─────────────────────────────────────────────────────────────────

cmd_key() {
  local sub="${1:-show}"

  case "$sub" in
    show|list)
      divider "SSH Keys"
      local found=0
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        found=1
        local keyfile="${f%.pub}"
        local status fp
        if [[ -f "$keyfile" ]]; then
          status="${C_GREEN}✅${C_RESET}"
        else
          status="${C_YELLOW}⚠️ ${C_RESET} (private missing)"
        fi
        fp="$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2, $4}' || true)"
        printf "  %b  ${C_BOLD}%s${C_RESET}\n" "$status" "${f##$HOME/}"
        [[ -n "$fp" ]] && printf "       ${C_DIM}%s${C_RESET}\n" "$fp"
      done < <(find "$SSH_DIR" -maxdepth 2 -name "*.pub" 2>/dev/null | sort)
      [[ $found -eq 0 ]] && info "No keys found. Use 'gsh key add' to generate one."
      echo
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
        die "Key not found: $kpath"
      fi
      ;;
    *)
      err "Usage: $APP key [show|add|fingerprint [keypath]]"
      exit 1
      ;;
  esac
}

# ── cmd: copy (scp wrapper) ──────────────────────────────────────────────────

cmd_copy() {
  if [[ $# -lt 2 ]]; then
    err "Usage: $APP copy <src> <dst>"
    info "Examples:"
    info "  gsh copy myserver:/etc/nginx.conf ./nginx.conf"
    info "  gsh copy ./file.txt myserver:/tmp/"
    exit 1
  fi
  scp -r "$@"
}

# ── cmd: export ──────────────────────────────────────────────────────────────

cmd_export() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    host_exists "$name" || die "Host '$name' not found."
    awk -v h="Host $name" '
      $0==h         { in_block=1; print; next }
      in_block && /^Host[[:space:]]/ { in_block=0 }
      in_block      { print }
    ' "$SSH_CONFIG"
  else
    cat "$SSH_CONFIG"
  fi
}

# ── cmd: import ──────────────────────────────────────────────────────────────

cmd_import() {
  local file="${1:-}"
  [[ -z "$file" || ! -f "$file" ]] && { err "Usage: $APP import <ssh_config_snippet>"; exit 1; }

  local imported=0 skipped=0
  local host_names=()
  while IFS= read -r h; do
    [[ -n "$h" ]] && host_names+=("$h")
  done < <(awk '$1=="Host" && NF==2 && $2!~/[\*\?\[]/{print $2}' "$file")

  [[ ${#host_names[@]} -eq 0 ]] && die "No valid host entries found in '$file'."

  for h in "${host_names[@]}"; do
    if host_exists "$h"; then
      warn "Skipping '$h' (already exists)"
      (( skipped++ )) || true
      continue
    fi

    local block
    block="$(awk -v hh="Host $h" '
      $0==hh        { in_block=1; print; next }
      in_block && /^Host[[:space:]]/ { in_block=0 }
      in_block      { print }
    ' "$file")"

    printf '\n%s\n' "$block" >> "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    ok "Imported '$h'"
    (( imported++ )) || true
  done

  echo
  info "$imported imported, $skipped skipped."
}

# ── cmd: tag / untag / ls-tags ───────────────────────────────────────────────

cmd_tag() {
  local name="${1:-}" tag="${2:-}"
  [[ -z "$name" || -z "$tag" ]] && { err "Usage: $APP tag <name> <tag>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."

  touch "$GSH_TAGS_FILE"
  chmod 600 "$GSH_TAGS_FILE"

  local existing
  existing="$(awk -v h="$name" '$1==h{$1=""; print}' "$GSH_TAGS_FILE" | xargs)"

  for t in $existing; do
    if [[ "$t" == "$tag" ]]; then
      warn "Host '$name' is already tagged '$tag'."
      return 0
    fi
  done

  local tmp
  tmp="$(mktemp)"
  grep -v "^$name " "$GSH_TAGS_FILE" > "$tmp" || true

  local merged
  [[ -n "$existing" ]] && merged="$existing $tag" || merged="$tag"
  echo "$name $merged" >> "$tmp"

  mv "$tmp" "$GSH_TAGS_FILE"
  chmod 600 "$GSH_TAGS_FILE"
  ok "Tagged '$name' with '$tag'"
}

cmd_untag() {
  local name="${1:-}" tag="${2:-}"
  [[ -z "$name" ]] && { err "Usage: $APP untag <name> [tag]"; exit 1; }

  touch "$GSH_TAGS_FILE"
  local tmp
  tmp="$(mktemp)"

  if [[ -n "$tag" ]]; then
    awk -v h="$name" -v t="$tag" '
      $1==h {
        line = $1
        for (i=2; i<=NF; i++) if ($i != t) line = line " " $i
        if (line != $1) print line
        next
      }
      { print }
    ' "$GSH_TAGS_FILE" > "$tmp"
    ok "Removed tag '$tag' from '$name'"
  else
    grep -v "^$name " "$GSH_TAGS_FILE" > "$tmp" || true
    ok "Removed all tags from '$name'"
  fi

  mv "$tmp" "$GSH_TAGS_FILE"
  chmod 600 "$GSH_TAGS_FILE"
}

cmd_ls_tags() {
  local filter="${1:-}"

  if [[ ! -f "$GSH_TAGS_FILE" ]] || [[ ! -s "$GSH_TAGS_FILE" ]]; then
    info "No tags defined. Use 'gsh tag <name> <tag>' to add one."
    return
  fi

  if [[ -n "$filter" ]]; then
    divider "Hosts tagged: $filter"
    awk -v t="$filter" '
      { for (i=2; i<=NF; i++) if ($i==t) { print "  " $1; break } }
    ' "$GSH_TAGS_FILE"
  else
    divider "All Tags"
    printf "  ${C_BOLD}%-22s %s${C_RESET}\n" "HOST" "TAGS"
    divider
    while IFS= read -r line; do
      local h tags_rest
      h="${line%% *}"
      tags_rest="${line#* }"
      printf "  %-22s ${C_DIM}%s${C_RESET}\n" "$h" "$tags_rest"
    done < "$GSH_TAGS_FILE"
  fi
  echo
}

# ── cmd: health ──────────────────────────────────────────────────────────────

cmd_health() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: $APP health <name>"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."

  local hostname port
  hostname="$(get_host_field "$name" "hostname")"
  port="$(get_host_field     "$name" "port")"
  [[ -z "$port" ]] && port="22"

  divider "Health: $name"
  printf "  %-22s %s:%s\n\n" "Target:" "$hostname" "$port"

  local ip="$hostname"
  if ! is_ip "$hostname"; then
    ip="$(resolve_fresh_ip "$hostname" "$RESOLVE_PREFER")"
  fi

  printf "  %-22s" "Ping:"
  if [[ -n "$ip" ]] && ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
    printf "${C_GREEN}Reachable${C_RESET} (%s)\n" "$ip"
  else
    printf "${C_RED}Unreachable${C_RESET}\n"
  fi

  printf "  %-22s" "Port $port/tcp:"
  if has_cmd nc; then
    if nc -z -w3 "${ip:-$hostname}" "$port" 2>/dev/null; then
      printf "${C_GREEN}Open${C_RESET}\n"
    else
      printf "${C_RED}Closed${C_RESET}\n"
    fi
  else
    printf "${C_YELLOW}N/A${C_RESET} (nc not installed)\n"
  fi

  printf "  %-22s" "SSH + uptime:"
  local ssh_out rc
  set +e
  ssh_out="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$name" \
    'echo SSH_OK; uptime' 2>/dev/null)"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]] && grep -q "^SSH_OK" <<<"$ssh_out"; then
    local up
    up="$(grep -v "^SSH_OK" <<<"$ssh_out" | xargs)"
    printf "${C_GREEN}OK${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$up"
  else
    printf "${C_RED}Failed${C_RESET}\n"
  fi

  echo
}

# ── cmd: logs ────────────────────────────────────────────────────────────────

cmd_logs() {
  local name="${1:-}" lines="${2:-50}"
  [[ -z "$name" ]] && { err "Usage: $APP logs <name> [lines]"; exit 1; }
  host_exists "$name" || die "Host '$name' not found."
  [[ "$lines" =~ ^[0-9]+$ ]] || die "lines must be a positive integer."

  info "Last $lines lines of SSH auth log on $name:"
  echo

  ssh "$name" "sh -c '
    if [ -f /var/log/auth.log ]; then
      tail -n '"$lines"' /var/log/auth.log
    elif [ -f /var/log/secure ]; then
      tail -n '"$lines"' /var/log/secure
    elif command -v journalctl >/dev/null 2>&1; then
      journalctl -u sshd -n '"$lines"' --no-pager 2>/dev/null
    else
      echo \"No SSH log found.\"
    fi
  '"
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
  die "Need zip or 7z to create encrypted backup."
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
  die "Need unzip or 7z to decrypt backup."
}

tg_send_file() {
  local file="$1" caption="${2:-}"
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    warn "Telegram not configured. Run 'gsh init' to set it up."
    return 2
  fi
  has_cmd curl || { err "curl not found."; return 2; }
  curl -fsSL \
    -F "chat_id=$TG_CHAT_ID" \
    -F "caption=$caption" \
    -F "document=@$file" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" >/dev/null
}

cmd_backup() {
  local pass="${BACKUP_ZIP_PASS:-}"
  [[ -z "$pass" ]] && pass="$(prompt_secret "ZIP password (required)")"
  [[ -z "$pass" ]] && die "Password is required for backup."

  local ts base outdir zipfile tmpdir
  ts="$(date +%Y%m%d-%H%M%S)"
  base="gsh-backup-$ts"
  outdir="$HOME"
  zipfile="$outdir/$base.zip"
  tmpdir="$(mktemp -d)"

  if [[ -f "$zipfile" ]]; then
    warn "Output file already exists: $zipfile"
    confirm_yn "Overwrite?" "n" || { rm -rf "$tmpdir"; echo "Cancelled."; exit 0; }
  fi

  info "Creating backup..."
  mkdir -p "$tmpdir/home/.ssh" "$tmpdir/home/bin" "$tmpdir/meta"
  [[ -d "$HOME/.ssh" ]] && cp -a "$HOME/.ssh/." "$tmpdir/home/.ssh/" 2>/dev/null || true
  [[ -d "$HOME/bin"  ]] && cp -a "$HOME/bin/."  "$tmpdir/home/bin/"  2>/dev/null || true
  printf 'created_at=%s\nhost=%s\nuser=%s\n' \
    "$(date -Is 2>/dev/null || date)" "$(hostname)" "$(whoami)" \
    > "$tmpdir/meta/info.txt"

  zip_encrypt "$tmpdir" "$zipfile" "$pass"
  rm -rf "$tmpdir"
  ok "Backup created: $zipfile"

  if tg_send_file "$zipfile" "GSH backup $ts"; then
    ok "Sent to Telegram"
  else
    info "Not sent to Telegram (configure via: gsh init)"
  fi
}

cmd_restore() {
  local zip_path="${1:-}"
  [[ -z "$zip_path" ]] && { err "Usage: $APP restore <backup.zip>"; exit 1; }
  [[ -f "$zip_path" ]] || die "File not found: $zip_path"

  local pass="${BACKUP_ZIP_PASS:-}"
  [[ -z "$pass" ]] && pass="$(prompt_secret "ZIP password")"
  [[ -z "$pass" ]] && die "Password is required."

  local ts tmpdir
  ts="$(date +%Y%m%d-%H%M%S)"
  tmpdir="$(mktemp -d)"

  info "Extracting backup..."
  if ! unzip_decrypt "$zip_path" "$tmpdir" "$pass"; then
    rm -rf "$tmpdir"
    die "Failed to extract. Wrong password or corrupt file."
  fi

  if [[ ! -d "$tmpdir/home/.ssh" && ! -d "$tmpdir/home/bin" ]]; then
    rm -rf "$tmpdir"
    die "Invalid backup structure (expected home/.ssh or home/bin inside zip)."
  fi

  if [[ -d "$HOME/.ssh" ]]; then
    mv "$HOME/.ssh" "$HOME/.ssh.bak.$ts"
    ok "Backed up current ~/.ssh → ~/.ssh.bak.$ts"
  fi
  if [[ -d "$HOME/bin" ]]; then
    mv "$HOME/bin" "$HOME/bin.bak.$ts"
    ok "Backed up current ~/bin → ~/bin.bak.$ts"
  fi

  mkdir -p "$HOME/.ssh" "$HOME/bin"
  chmod 700 "$HOME/.ssh"
  [[ -d "$tmpdir/home/.ssh" ]] && cp -a "$tmpdir/home/.ssh/." "$HOME/.ssh/"
  [[ -d "$tmpdir/home/bin"  ]] && cp -a "$tmpdir/home/bin/."  "$HOME/bin/"

  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  [[ -f "$HOME/.ssh/config"          ]] && chmod 600 "$HOME/.ssh/config"
  [[ -f "$HOME/.ssh/authorized_keys" ]] && chmod 600 "$HOME/.ssh/authorized_keys"
  [[ -f "$HOME/.ssh/.gsh.env"        ]] && chmod 600 "$HOME/.ssh/.gsh.env"
  [[ -f "$HOME/bin/gsh"              ]] && chmod +x  "$HOME/bin/gsh"

  rm -rf "$tmpdir"
  ok "Restore complete."
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  local b="$C_BOLD" r="$C_RESET" d="$C_DIM" c="$C_CYAN"
  printf "${b}GlyNet Shell (gsh) v%s${r} — SSH connection manager\n\n" "$VERSION"

  printf "${b}CONNECT${r}\n"
  printf "  gsh ${b}<name>${r}                          Connect to host\n"
  printf "  gsh exec   ${b}<name> <cmd>${r}             Run command on remote host\n"
  printf "  gsh tunnel ${b}<name> <lp>:<rh>:<rp>${r}    Local port-forward\n"
  printf "  gsh copy   ${b}<src> <dst>${r}              SCP file copy (host:path)\n\n"

  printf "${b}MANAGE HOSTS${r}\n"
  printf "  gsh add       ${d}[name]${r}               Add a host (interactive, key picker)\n"
  printf "  gsh update    ${d}[name]${r}               Update a host (key picker)\n"
  printf "  gsh rm        ${b}<name>${r}               Remove a host\n"
  printf "  gsh rename    ${b}<old> <new>${r}          Rename host alias\n"
  printf "  gsh duplicate ${b}<src> <new>${r}          Clone a host entry\n"
  printf "  gsh ls                               List all hosts (full details)\n"
  printf "  gsh info      ${b}<name>${r}               Show full host info + resolved IP\n"
  printf "  gsh sort                             Sort config alphabetically\n"
  printf "  gsh export    ${d}[name]${r}               Print config to stdout\n"
  printf "  gsh import    ${b}<file>${r}               Import hosts from config file\n\n"

  printf "${b}KEYS${r}\n"
  printf "  gsh key show                         List all local SSH keys\n"
  printf "  gsh key add                          Generate a new SSH key\n"
  printf "  gsh key fingerprint ${d}[keypath]${r}      Show key fingerprint\n"
  printf "  gsh copy-id  ${b}<name>${r}               Push public key to host\n\n"

  printf "${b}DIAGNOSTICS${r}\n"
  printf "  gsh ping     ${b}<name>${r}               Ping host\n"
  printf "  gsh health   ${b}<name>${r}               Full check: ping / port / ssh / uptime\n"
  printf "  gsh test-all                         Test SSH to all hosts\n"
  printf "  gsh logs     ${b}<name>${r} ${d}[lines]${r}       Tail remote SSH auth log\n\n"

  printf "${b}TAGS${r}\n"
  printf "  gsh tag      ${b}<name> <tag>${r}          Tag a host\n"
  printf "  gsh untag    ${b}<name>${r} ${d}[tag]${r}           Remove tag (or all tags)\n"
  printf "  gsh ls-tags  ${d}[tag]${r}                List tags / hosts by tag\n\n"

  printf "${b}BACKUP${r}\n"
  printf "  gsh backup                           Backup ~/.ssh + ~/bin (encrypted zip)\n"
  printf "  gsh restore  ${b}<backup.zip>${r}          Restore from backup\n\n"

  printf "${b}CONFIG${r}\n"
  printf "  gsh init                             Configure gsh settings\n"
  printf "  gsh version                          Show version\n\n"
  printf "  Config: ${d}~/.ssh/.gsh.env${r}\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    add)        shift; cmd_add       "${1:-}" ;;
    update)     shift; cmd_update    "${1:-}" ;;
    rm|remove)  shift; cmd_rm        "${1:-}" ;;
    rename)     shift; cmd_rename    "${1:-}" "${2:-}" ;;
    duplicate)  shift; cmd_duplicate "${1:-}" "${2:-}" ;;
    ls|list)    cmd_ls ;;
    sort)       sort_config ;;
    init)       cmd_init ;;
    info)       shift; cmd_info      "${1:-}" ;;
    ping)       shift; cmd_ping      "${1:-}" ;;
    health)     shift; cmd_health    "${1:-}" ;;
    test-all)   cmd_test_all ;;
    exec)       shift; cmd_exec      "$@" ;;
    tunnel)     shift; cmd_tunnel    "${1:-}" "${2:-}" ;;
    copy)       shift; cmd_copy      "$@" ;;
    copy-id)    shift; cmd_copy_id   "${1:-}" ;;
    key)        shift; cmd_key       "${1:-show}" "${2:-}" ;;
    keygen)     cmd_keygen ;;
    export)     shift; cmd_export    "${1:-}" ;;
    import)     shift; cmd_import    "${1:-}" ;;
    tag)        shift; cmd_tag       "${1:-}" "${2:-}" ;;
    untag)      shift; cmd_untag     "${1:-}" "${2:-}" ;;
    ls-tags)    shift; cmd_ls_tags   "${1:-}" ;;
    logs)       shift; cmd_logs      "${1:-}" "${2:-50}" ;;
    backup)     cmd_backup ;;
    restore)    shift; cmd_restore   "${1:-}" ;;
    version)    echo "gsh v$VERSION" ;;
    ""|-h|--help) usage ;;
    *)          connect_with_resolve_if_needed "$1" ;;
  esac
}

main "$@"
