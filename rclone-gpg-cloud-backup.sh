#!/usr/bin/env bash
# ==============================================================================
# rClone GPG Cloud Backup  – by popek1990.eth
# TAR -> GPG encrypt -> rclone upload (OneDrive / GDrive / S3 / any rclone remote)
# Simple, beginner-friendly. Config file lives next to this script: ./rclone.conf
# Version: 1.0
# ==============================================================================

set -euo pipefail

VERSION="1.0"
PROJECT_NAME="rClone GPG Cloud Backup"
AUTHOR="popek1990.eth"

# ---------- UTF-8 detection (emoji on UTF-8 only) ----------
is_utf8() { (locale charmap 2>/dev/null || echo "") | grep -qi 'UTF-8'; }

if is_utf8 && command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_RED=$(tput setaf 1); C_CYAN=$(tput setaf 6); C_RESET=$(tput sgr0)
  S_OK="✅"; S_INFO="ℹ️"; S_WARN="⚠️"; S_ERR="❌"; S_DIV="—"
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_RESET=""
  S_OK="[OK]"; S_INFO="[INFO]"; S_WARN="[WARN]"; S_ERR="[ERROR]"; S_DIV="-"
fi

ok()   { echo -e "${C_GREEN}${S_OK}  $*${C_RESET}"; }
info() { echo -e "${C_CYAN}${S_INFO}  $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}${S_WARN} $*${C_RESET}"; }
err()  { echo -e "${C_RED}${S_ERR} $*${C_RESET}"; }
banner(){ echo -e "\n${C_CYAN}${S_DIV}${S_DIV}${S_DIV} $* ${S_DIV}${S_DIV}${S_DIV}${C_RESET}\n"; }

# ---------- Fancy banner ----------
print_banner() {
  local text="$PROJECT_NAME"
  echo
  if command -v toilet >/dev/null 2>&1; then
    (toilet -f future "$text" 2>/dev/null || toilet "$text" 2>/dev/null || true)
  elif command -v figlet >/dev/null 2>&1; then
    (figlet -w 120 "$text" 2>/dev/null || true)
  else
    echo "### $text ###"
  fi
  echo "Author : $AUTHOR"
  echo "Version: $VERSION"
  echo
}

# ---------- Defaults (can be overridden by config) ----------
BACKUP_ITEMS=( )
BACKUP_ROOT="${HOME}/cloud-backup"
LABEL="project"
HOST_TAG="$(hostname -s)"
COMPRESSION="zstd"
GPG_RECIPIENT_FPR=""
GPG_IMPORT_KEY_FILE=""
REMOTE_NAME="onedrive"
REMOTE_DIR="Backups"
LOCAL_RETENTION_DAYS="7"
REMOTE_RETENTION_DAYS="14"

# Behavior
KEEP_PLAINTEXT_ARCHIVE="${KEEP_PLAINTEXT_ARCHIVE:-no}"   # delete .tar.* after encryption
DELETE_ENCRYPTED_AFTER_UPLOAD="${DELETE_ENCRYPTED_AFTER_UPLOAD:-yes}"  # delete .gpg after successful upload
DO_VERBOSE="no"  # enable with --verbose for rclone progress

# ---------- Paths to script & config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/rclone.conf"
CONFIG_FILE="${CONFIG_FILE_DEFAULT}"

# ---------- CLI ----------
DO_DRYRUN="no"; DO_RETAIN="yes"; INIT_CONFIG="no"; DO_CHECK="no"

usage() {
cat <<'HLP'
Usage:
  rclone-gpg-cloud-backup.sh [--dry-run] [--no-retain] [--config FILE] [--init-config] [--check] [--verbose] [--version]

Options:
  --dry-run        Do everything except cloud upload and deletion.
  --no-retain      Skip retention (no deletion of old backups).
  --config FILE    Use specific config file (default: ./rclone.conf).
  --init-config    Create a starter config file and exit (won't overwrite).
  --check          Only check deps/config/GPG/rclone and exit.
  --verbose        Show rclone progress (good for manual runs).
  --version        Print version and exit.
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--dryrun) DO_DRYRUN="yes"; shift ;;
    --no-retain|--no-retention) DO_RETAIN="no"; shift ;;
    --config) CONFIG_FILE="${2}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#*=}"; shift ;;
    --init-config) INIT_CONFIG="yes"; shift ;;
    --check) DO_CHECK="yes"; shift ;;
    --verbose) DO_VERBOSE="yes"; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------- Config handling ----------
create_starter_config() {
  if [[ -e "$CONFIG_FILE" ]]; then
    warn "Config exists: $CONFIG_FILE (not overwriting)"
    return 0
  fi
  cat > "$CONFIG_FILE" <<'CFG'
########################################
# rclone-gpg-cloud-backup – SIMPLE CONFIG
# Edit these lines before first run.
########################################

# Absolute paths (array)
BACKUP_ITEMS=( "/root/testfile.txt" )

BACKUP_ROOT="$HOME/cloud-backup"
LABEL="short-label"
HOST_TAG="$(hostname -s)"
COMPRESSION="zstd"

# --- GPG ---
GPG_RECIPIENT_FPR=""
GPG_IMPORT_KEY_FILE=""

# --- rclone ---
REMOTE_NAME="onedrive"
REMOTE_DIR="Backups"

# --- Retention (0 disables) ---
LOCAL_RETENTION_DAYS="7"
REMOTE_RETENTION_DAYS="14"
CFG
  ok "Starter config created at: $CONFIG_FILE"
}

if [[ "$INIT_CONFIG" == "yes" ]]; then
  create_starter_config; exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Config file not found: $CONFIG_FILE
Hint: run  ./rclone-gpg-cloud-backup.sh --init-config  and then edit $CONFIG_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ---------- Paths & logging ----------
STAMP="$(date +%F_%H-%M-%S)"
DAY_DIR="$(date +%F)"
WORK_DIR="${BACKUP_ROOT}/${DAY_DIR}"
mkdir -p "$WORK_DIR"

LOG_FILE="${WORK_DIR}/${LABEL}_cloud_backup_${STAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_banner
echo -e "${C_CYAN}=== ${PROJECT_NAME} ===${C_RESET}"
echo -e "Host     : ${HOST_TAG}"
echo -e "Work dir : ${WORK_DIR}"
echo -e "Log file : ${LOG_FILE}"
echo -e "Config   : ${CONFIG_FILE}"

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; return 1; }; }

check_deps() {
  banner "Checking dependencies"
  local missing=0
  for bin in tar gpg rclone; do need "$bin" || missing=1; done
  case "$COMPRESSION" in
    zstd) need zstd || missing=1 ;;
    gz)   command -v pigz >/dev/null 2>&1 || need gzip || missing=1 ;;
    *)    err "Unsupported COMPRESSION=${COMPRESSION} (use zstd|gz)"; missing=1 ;;
  esac
  if ! command -v toilet >/dev/null 2>&1 && ! command -v figlet >/dev/null 2>&1; then
    warn "ASCII banner tools (toilet/figlet) not found — using text fallback."
  fi
  (( missing == 0 )) || { warn "Install on Debian/Ubuntu:\n  sudo apt update && sudo apt install -y tar gnupg rclone zstd pigz figlet toilet toilet-fonts"; exit 1; }
  ok "Dependencies OK."
}

has_remote(){ rclone listremotes | grep -q "^${REMOTE_NAME}:"; }

# Avoid gpg-agent/pinentry hangs: always --batch, short timeout for listing
safe_gpg_list_keys() {
  if command -v timeout >/dev/null 2>&1; then timeout 8s gpg --batch --list-keys --with-colons 2>/dev/null || true
  else gpg --batch --list-keys --with-colons 2>/dev/null || true; fi
}

resolve_gpg_recipient() {
  { banner "GPG setup"; } >&2
  { [[ -n "${GPG_IMPORT_KEY_FILE}" && -f "${GPG_IMPORT_KEY_FILE}" ]] && info "Importing public key: ${GPG_IMPORT_KEY_FILE}" && gpg --batch --import "${GPG_IMPORT_KEY_FILE}" || true; } >&2
  { [[ -n "${GPG_RECIPIENT_FPR}" ]] || { err "GPG_RECIPIENT_FPR is empty. Set it in the config file."; exit 1; }; } >&2
  if safe_gpg_list_keys | awk -F: '/^fpr:/ {print $10}' | grep -Fxq "$GPG_RECIPIENT_FPR"; then
    { info "Using GPG fingerprint: ${GPG_RECIPIENT_FPR}"; } >&2
  else
    { err "Fingerprint not found in keyring: ${GPG_RECIPIENT_FPR}
Tip:
  gpg --export -a 'you@example.com' > public.asc
  gpg --import /path/to/public.asc"; exit 1; } >&2
  fi
  printf '%s\n' "$GPG_RECIPIENT_FPR"
}

compress_make(){
  banner "Creating archive"
  local out="$1"; shift
  local items=( "$@" )
  info "Items to include: ${#items[@]}"
  for p in "${items[@]}"; do [[ -e "$p" ]] || warn "Missing: $p"; done
  case "$COMPRESSION" in
    zstd) tar -I 'zstd -19' -cvf "$out" "${items[@]}" ;;
    gz)   if command -v pigz >/dev/null 2>&1; then tar -I 'pigz -9' -cvf "$out" "${items[@]}"; else tar -czvf "$out" "${items[@]}"; fi ;;
  esac
  ok "Archive ready: $out"
}

encrypt_gpg(){
  local in="$1"; local rcpt="$2"; local out="${in}.gpg"
  { banner "Encrypting archive"; info "Recipient: ${rcpt}"; } >&2
  gpg --yes --batch --trust-model always --encrypt -r "$rcpt" -o "$out" "$in" >&2
  { ok "Encrypted: $out"; } >&2
  printf '%s\n' "$out"
}

upload_remote(){
  banner "Uploading to cloud"
  local file="$1"
  local dest="${REMOTE_NAME}:${REMOTE_DIR}/${LABEL}/${HOST_TAG}/${DAY_DIR}/"
  info "Remote path: $dest"
  if [[ "$DO_VERBOSE" == "yes" ]]; then
    rclone copy "$file" "$dest" --progress --stats-one-line-date --human-readable
  else
    rclone copy "$file" "$dest" -q --stats 0
  fi
  ok "Upload done."
  echo "$dest"
}

retention_local(){
  [[ "$DO_RETAIN" == "yes" ]] || { info "Local retention skipped (--no-retain)."; return 0; }
  (( LOCAL_RETENTION_DAYS > 0 )) || { info "Local retention disabled (0d)."; return 0; }
  banner "Local retention"
  info "Deleting *.gpg older than ${LOCAL_RETENTION_DAYS}d under ${BACKUP_ROOT}"
  find "${BACKUP_ROOT}" -type f -name "*.gpg" -mtime +${LOCAL_RETENTION_DAYS} -print -delete || true
  ok "Local retention complete."
}

retention_remote(){
  [[ "$DO_RETAIN" == "yes" ]] || { info "Remote retention skipped (--no-retain)."; return 0; }
  (( REMOTE_RETENTION_DAYS > 0 )) || { info "Remote retention disabled (0d)."; return 0; }
  banner "Remote retention"
  local base="${REMOTE_NAME}:${REMOTE_DIR}/${LABEL}/${HOST_TAG}"
  info "Pruning files older than ${REMOTE_RETENTION_DAYS}d in ${base}"
  rclone delete "${base}" --min-age "${REMOTE_RETENTION_DAYS}d" || true
  rclone rmdirs "${base}" || true
  ok "Remote retention complete."
}

# ---------- MAIN ----------
check_deps

# Quick check mode
if [[ "$DO_CHECK" == "yes" ]]; then
  banner "Config sanity check"
  [[ ${#BACKUP_ITEMS[@]} -gt 0 ]] || err "BACKUP_ITEMS is empty."
  [[ -n "$GPG_RECIPIENT_FPR" ]] || err "GPG_RECIPIENT_FPR is empty."
  has_remote && ok "rclone remote '${REMOTE_NAME}' found." || warn "rclone remote '${REMOTE_NAME}' NOT found."
  resolve_gpg_recipient >/dev/null
  ok "Check finished."
  exit 0
fi

# Fail fast for beginners
if (( ${#BACKUP_ITEMS[@]} == 0 )); then
  err "BACKUP_ITEMS is empty. Edit your config: $CONFIG_FILE"
  exit 1
fi

RECIPIENT="$(resolve_gpg_recipient)"

# Filter missing paths
RESOLVED=()
for p in "${BACKUP_ITEMS[@]}"; do [[ -e "$p" ]] && RESOLVED+=( "$p" ) || warn "Skipping: $p"; done
(( ${#RESOLVED[@]} > 0 )) || { err "No valid BACKUP_ITEMS after filtering. Fix paths in config."; exit 1; }

# Compression helpers
case "$COMPRESSION" in
  zstd) EXT="tar.zst"; LIST_CMD=(tar -I zstd -tf) ;;
  gz)   EXT="tar.gz";  LIST_CMD=(tar -tzf) ;;
esac

ARCHIVE="${WORK_DIR}/${LABEL}_backup_${STAMP}.${EXT}"
ENC_PATH=""; REMOTE_PATH=""

compress_make "$ARCHIVE" "${RESOLVED[@]}"
banner "Archive quick test"
du -h "$ARCHIVE" || true
"${LIST_CMD[@]}" "$ARCHIVE" 2>/dev/null | head -n 10 || true

# Encrypt -> optionally delete plaintext tar
ENC_PATH="$(encrypt_gpg "$ARCHIVE" "$RECIPIENT")"
if [[ "$KEEP_PLAINTEXT_ARCHIVE" != "yes" ]]; then
  info "Removing plaintext archive: $ARCHIVE"
  rm -f -- "$ARCHIVE" || true
fi

if [[ "$DO_DRYRUN" == "yes" ]]; then
  banner "Dry-run: upload skipped"
else
  has_remote || { err "Remote '${REMOTE_NAME}' not found. Run: rclone config"; exit 1; }
  REMOTE_PATH="$(upload_remote "$ENC_PATH")"
  if [[ "$DELETE_ENCRYPTED_AFTER_UPLOAD" == "yes" ]]; then
    info "Removing local encrypted file after upload: $ENC_PATH"
    rm -f -- "$ENC_PATH" || true
  fi
fi

retention_local
[[ "$DO_DRYRUN" != "yes" ]] && retention_remote

banner "Backup finished"
echo "Summary:"
echo "  Project : ${PROJECT_NAME}"
echo "  Author  : ${AUTHOR}"
echo "  Version : ${VERSION}"
echo "  Host    : ${HOST_TAG}"
echo "  Items   : ${#RESOLVED[@]}"
echo "  Archive : ${ARCHIVE}"
echo "  Encrypted: ${ENC_PATH:-<skipped>}"
[[ -n "${REMOTE_PATH:-}" ]] && echo "  Remote  : ${REMOTE_PATH}"
echo "  Log     : ${LOG_FILE}"
