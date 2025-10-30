#!/usr/bin/env bash
# ==============================================================================
# rClone GPG Cloud Backup  – by popek1990.eth
# TAR -> GPG encrypt -> rclone upload (OneDrive / GDrive / S3 / any rclone remote)
# Config file lives next to this script: ./rclone.conf
# Version: 1.0
# ==============================================================================

set -euo pipefail

VERSION="1.0"
PROJECT_NAME="rClone GPG Cloud Backup"
AUTHOR="popek1990.eth"

# ---------- UTF-8 detection (emoji only on UTF-8 terminals) ----------
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

# ---------- Paths to script & config (first!) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/rclone.conf"
CONFIG_FILE="${CONFIG_FILE_DEFAULT}"

# ---------- Defaults (overridden by config) ----------
BACKUP_ITEMS=( )
BACKUP_ROOT="${SCRIPT_DIR}/local-work-dir"   # domyślnie w repo/local-work-dir
LABEL="project"
HOST_TAG="$(hostname -s)"
COMPRESSION="zstd"
GPG_RECIPIENT_FPR=""
GPG_IMPORT_KEY_FILE=""
REMOTE_NAME="onedrive"
REMOTE_DIR="Backups"
LOCAL_RETENTION_DAYS="7"
REMOTE_RETENTION_DAYS="14"

# Behavior toggles
KEEP_PLAINTEXT_ARCHIVE="${KEEP_PLAINTEXT_ARCHIVE:-no}"               # delete .tar.* after encrypt
DELETE_ENCRYPTED_AFTER_UPLOAD="${DELETE_ENCRYPTED_AFTER_UPLOAD:-yes}" # delete .gpg after upload
DO_VERBOSE="no"  # enable with --verbose

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
  --verbose        Show rclone/tar extra info (good for manual runs).
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
    warn "Config exists: $CONFIG_FILE (not overwriting)"; return 0
  fi
  cat > "$CONFIG_FILE" <<'CFG'
########################################
# rclone-gpg-cloud-backup – SIMPLE CONFIG
# Edit these lines before first run.
########################################

# Absolute paths (array)
BACKUP_ITEMS=( "/root/testfile.txt" )

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

if [[ "$INIT_CONFIG" == "yes" ]]; then create_starter_config; exit 0; fi
[[ -f "$CONFIG_FILE" ]] || { err "Config not found: $CONFIG_FILE. Run --init-config"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ---------- Paths & logging ----------
STAMP="$(date +%F_%H-%M-%S)"
DAY_DIR="$(date +%F)"
WORK_DIR="${BACKUP_ROOT}/${DAY_DIR}"
mkdir -p "$WORK_DIR"

LOG_FILE="${WORK_DIR}/${LABEL}_cloud_backup_${STAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- Fancy banner ----------
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
  (( missing == 0 )) || { warn "Install: sudo apt update && sudo apt install -y tar gnupg rclone zstd pigz"; exit 1; }
  ok "Dependencies OK."
}

has_remote(){ rclone listremotes | grep -q "^${REMOTE_NAME}:"; }

# Compressed/archival extensions
is_precompressed() {
  local f="${1##*/}"; f="${f,,}"
  [[ -f "$1" ]] && [[ "$f" =~ \.(tar\.zst|tar\.gz|tgz|tar\.xz|tar\.bz2|zst|gz|xz|bz2|zip|rar|7z|tar)$ ]]
}

# Avoid gpg-agent/pinentry hangs
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
Tip: gpg --export -a 'you@example.com' > public.asc && gpg --import public.asc"; exit 1; } >&2
  fi
  printf '%s\n' "$GPG_RECIPIENT_FPR"
}

compress_make(){
  banner "Creating archive"
  local out="$1"; shift
  local items=( "$@" )
  info "Items to include: ${#items[@]}"
  case "$COMPRESSION" in
    zstd) tar -P -I 'zstd -19' -cf "$out" "${items[@]}" ;;
    gz)   if command -v pigz >/dev/null 2>&1; then tar -P -I 'pigz -9' -cf "$out" "${items[@]}"; else tar -P -czf "$out" "${items[@]}"; fi ;;
  esac
  ok "Archive ready: $out"
}

encrypt_gpg(){
  local in="$1"; local rcpt="$2"; local out="$3"
  { banner "Encrypting archive"; info "Recipient: ${rcpt}"; } >&2
  gpg --yes --batch --trust-model always --encrypt -r "$rcpt" -o "$out" "$in" >&2
  { ok "Encrypted: $out"; } >&2
  printf '%s\n' "$out"
}

upload_remote(){
  banner "Uploading to cloud"
  local file="$1"
  # Cloud path: REMOTE_DIR / HOST_TAG / LABEL / YYYY-MM-DD
  local dest="${REMOTE_NAME}:${REMOTE_DIR}/${HOST_TAG}/${LABEL}/${DAY_DIR}/"
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
  [[ "$DO_RETAIN" == "yes" ]] || return 0
  (( LOCAL_RETENTION_DAYS > 0 )) || return 0
  banner "Local retention"
  info "Deleting *.gpg older than ${LOCAL_RETENTION_DAYS}d under ${BACKUP_ROOT}"
  find "${BACKUP_ROOT}" -type f -name "*.gpg" -mtime +${LOCAL_RETENTION_DAYS} -print -delete || true
  ok "Local retention complete."
}

retention_remote(){
  [[ "$DO_RETAIN" == "yes" ]] || return 0
  (( REMOTE_RETENTION_DAYS > 0 )) || return 0
  banner "Remote retention"
  local base="${REMOTE_NAME}:${REMOTE_DIR}/${HOST_TAG}/${LABEL}"
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
  ok "Check finished."; exit 0
fi

(( ${#BACKUP_ITEMS[@]} > 0 )) || { err "BACKUP_ITEMS is empty. Edit your config: $CONFIG_FILE"; exit 1; }
RECIPIENT="$(resolve_gpg_recipient)"

# Resolve existing paths
RESOLVED=()
for p in "${BACKUP_ITEMS[@]}"; do [[ -e "$p" ]] && RESOLVED+=( "$p" ) || warn "Skipping: $p"; done
(( ${#RESOLVED[@]} > 0 )) || { err "No valid BACKUP_ITEMS after filtering. Fix paths in config."; exit 1; }

# Classify & prepare
TO_ENCRYPT=()          # final list of source files to encrypt (no directories)
GEN_ARCHIVES=()        # plaintext archives we created (safe to delete later)
i=0

for item in "${RESOLVED[@]}"; do
  if [[ -d "$item" ]]; then
    # Pack this directory only, then encrypt
    case "$COMPRESSION" in
      zstd) EXT="tar.zst"; LIST_CMD=(tar -I zstd -tf) ;;
      gz)   EXT="tar.gz";  LIST_CMD=(tar -tzf) ;;
    esac
    base="$(basename "$item")"
    ARCHIVE="${WORK_DIR}/${LABEL}_${base}_${STAMP}.${EXT}"
    compress_make "$ARCHIVE" "$item"
    [[ "$DO_VERBOSE" == "yes" ]] && { banner "Archive quick test"; du -h "$ARCHIVE" || true; "${LIST_CMD[@]}" "$ARCHIVE" 2>/dev/null | head -n 10 || true; }
    TO_ENCRYPT+=( "$ARCHIVE" )
    GEN_ARCHIVES+=( "$ARCHIVE" )
  elif [[ -f "$item" ]]; then
    if is_precompressed "$item"; then
      info "Pre-compressed file detected; will encrypt as-is: $item"
      TO_ENCRYPT+=( "$item" )
    else
      info "Plain file detected; will encrypt as-is (no tar): $item"
      TO_ENCRYPT+=( "$item" )
    fi
  else
    warn "Skipping unknown type: $item"
  fi
  i=$((i+1))
done

# Encrypt & upload each
REMOTE_PATH=""
for src in "${TO_ENCRYPT[@]}"; do
  ENC_OUT="${WORK_DIR}/$(basename "$src").gpg"
  ONE_ENC="$(encrypt_gpg "$src" "$RECIPIENT" "$ENC_OUT")"

  if [[ "$DO_DRYRUN" == "yes" ]]; then
    banner "Dry-run: upload skipped"
  else
    has_remote || { err "Remote '${REMOTE_NAME}' not found. Run: rclone config"; exit 1; }
    REMOTE_PATH="$(upload_remote "$ONE_ENC")"
    if [[ "$DELETE_ENCRYPTED_AFTER_UPLOAD" == "yes" ]]; then
      info "Removing local encrypted file after upload: $ONE_ENC"
      rm -f -- "$ONE_ENC" || true
    fi
  fi
done

# Delete only archives we created ourselves (never user originals)
if [[ "$KEEP_PLAINTEXT_ARCHIVE" != "yes" && ${#GEN_ARCHIVES[@]} -gt 0 ]]; then
  for a in "${GEN_ARCHIVES[@]}"; do
    info "Removing plaintext archive: $a"
    rm -f -- "$a" || true
  done
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
[[ -n "${REMOTE_PATH:-}" ]] && echo "  Last upload: ${REMOTE_PATH}"
echo "  Log     : ${LOG_FILE}"
