#!/usr/bin/env bash
#
# install-ca-certs-macos.sh
#
# Downloads CA certificates from ca.sigmohar.com and, ONLY after explicit
# confirmation at each step, trusts them:
#   1. System-wide, via the macOS System keychain (covers Safari, Chrome,
#      curl, and most system tools — they all read the System keychain).
#   2. For Firefox, which keeps its own trust store separate from macOS:
#      instead of injecting the cert into every Firefox profile's NSS
#      database (which needs certutil — not installed on macOS by default),
#      this offers to enable Mozilla's official "ImportEnterpriseRoots"
#      policy, so Firefox trusts whatever macOS already trusts. This also
#      covers any future certs automatically, unlike per-cert injection.
#
# Same design principles as the Linux version:
#   - No auto-discovery of cert IDs — list them in CERT_IDS below.
#   - No tool is installed without asking first, and being told why.
#   - Every system-changing action requires an explicit y/N confirmation.
#   - Downloaded files live only in a temp dir, removed on exit.
#
# USAGE:
#   ./install-ca-certs-macos.sh                  # uses CERT_IDS below
#   ./install-ca-certs-macos.sh abcd1234 ef56..   # overrides CERT_IDS
#   sudo ./install-ca-certs-macos.sh              # needed for system-wide steps
#   ./install-ca-certs-macos.sh -y ...            # skip confirmations

set -euo pipefail

### ---------------------------- CONFIG ---------------------------- ###

BASE_URL="${BASE_URL:-https://ca.sigmohar.com/r}"

# Put every cert ID (the "XXXX" in https://ca.sigmohar.com/r/XXXX.crt) you
# want installed, one per line.
CERT_IDS=(
  # "xxxx1"
  # "xxxx2"
)

### -------------------------- END CONFIG --------------------------- ###

WORKDIR=$(mktemp -d -t ca-certs)
ASSUME_YES=0
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "(auto-confirmed via -y) $prompt"
    return 0
  fi
  local reply=""
  read -r -p "$prompt [y/N]: " reply || reply=""
  case "$reply" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

IS_ROOT=0
[[ $EUID -eq 0 ]] && IS_ROOT=1

# --------------------------------------------------------------------
# 0. Args
# --------------------------------------------------------------------

ARGS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
[[ ${#ARGS[@]} -gt 0 ]] && CERT_IDS=("${ARGS[@]}")

if [[ ${#CERT_IDS[@]} -eq 0 ]]; then
  err "No cert IDs configured. Edit CERT_IDS in this script, or pass IDs as arguments."
  exit 1
fi

# --------------------------------------------------------------------
# 1. Dependencies — curl and openssl ship with macOS, but check anyway
#    and never install silently.
# --------------------------------------------------------------------

check_tool() {
  local cmd="$1" reason="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  echo
  echo "Missing tool: $cmd"
  echo "Needed for: $reason"
  if command -v brew >/dev/null 2>&1; then
    if confirm "Homebrew detected. Install '$cmd' via 'brew install $cmd' now?"; then
      brew install "$cmd" && command -v "$cmd" >/dev/null 2>&1 && return 0
    fi
  else
    if confirm "Homebrew not found. Run 'xcode-select --install' now? (opens Apple's own installer for command-line tools, including curl/openssl)"; then
      xcode-select --install || true
      warn "Installer launched if not already present — re-run this script once it finishes."
    fi
  fi
  return 1
}

check_tool curl "downloading certificate files from ${BASE_URL} over HTTPS" || { err "curl is required. Exiting."; exit 1; }
check_tool openssl "validating and normalizing downloaded certificates before anything is trusted" || { err "openssl is required. Exiting."; exit 1; }

if ! command -v security >/dev/null 2>&1; then
  err "'security' (the macOS keychain tool) was not found. This should always be present on macOS — something is unusual about this system. Exiting."
  exit 1
fi

# --------------------------------------------------------------------
# 2. Download + validate into the temp dir (no system changes yet)
# --------------------------------------------------------------------

echo
log "About to download the following, into a temp dir that will be deleted afterward:"
for id in "${CERT_IDS[@]}"; do
  echo "  ${BASE_URL}/${id}.crt"
done
if ! confirm "Proceed with downloading these ${#CERT_IDS[@]} file(s)?"; then
  log "Aborted by user before any download."
  exit 0
fi

normalize_to_pem() {
  local raw="$1" pem="$2"
  if openssl x509 -in "$raw" -inform PEM -noout 2>/dev/null; then
    cp "$raw" "$pem"
  elif openssl x509 -in "$raw" -inform DER -noout 2>/dev/null; then
    openssl x509 -in "$raw" -inform DER -out "$pem"
  else
    return 1
  fi
}

declare -A PEM_FILES
declare -A NICKNAMES

for id in "${CERT_IDS[@]}"; do
  url="${BASE_URL}/${id}.crt"
  raw="$WORKDIR/${id}.raw"
  pem="$WORKDIR/${id}.pem"

  log "Downloading $url"
  if ! curl -fsSL "$url" -o "$raw"; then
    warn "Failed to download '$id' — skipping."
    continue
  fi
  if ! normalize_to_pem "$raw" "$pem"; then
    err "'$id' is not a valid PEM or DER certificate — skipping."
    continue
  fi

  cn=$(openssl x509 -in "$pem" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p')
  nick="${cn:-$id}"
  PEM_FILES["$id"]="$pem"
  NICKNAMES["$id"]="$nick"
  log "  -> OK: '$nick' ($id)"
done

if [[ ${#PEM_FILES[@]} -eq 0 ]]; then
  err "No certificates were successfully downloaded/validated. Nothing to install."
  exit 1
fi

echo
log "Successfully fetched and validated ${#PEM_FILES[@]} of ${#CERT_IDS[@]} requested cert(s):"
for id in "${!PEM_FILES[@]}"; do
  echo "  - ${NICKNAMES[$id]} ($id)"
done

# --------------------------------------------------------------------
# 3. System keychain — confirm before touching anything
# --------------------------------------------------------------------

if [[ $IS_ROOT -eq 1 ]]; then
  echo
  echo "The following cert(s) can be added to the SYSTEM keychain as trusted roots."
  echo "This affects every user and application on this machine that relies on the System"
  echo "keychain for TLS trust, including Safari, Chrome, curl, and most system tools."
  for id in "${!PEM_FILES[@]}"; do
    echo "  - ${NICKNAMES[$id]}"
  done
  if confirm "Proceed with System keychain installation?"; then
    for id in "${!PEM_FILES[@]}"; do
      pem="${PEM_FILES[$id]}"
      nick="${NICKNAMES[$id]}"
      if security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$pem" 2>/dev/null; then
        log "Trusted '$nick' in the System keychain."
      else
        warn "Failed to add '$nick' to the System keychain (it may already be present, or macOS declined authorization)."
      fi
    done
  else
    log "Skipped System keychain installation."
  fi
else
  warn "Not running as root — skipping the System keychain step entirely. Re-run with sudo to include it."
fi

# --------------------------------------------------------------------
# 4. Firefox — offer the enterprise-roots policy instead of raw NSS injection
# --------------------------------------------------------------------

FIREFOX_POLICY_DIR="/Library/Application Support/Mozilla"
FIREFOX_POLICY_FILE="$FIREFOX_POLICY_DIR/policies.json"

if [[ $IS_ROOT -eq 1 ]]; then
  echo
  echo "Firefox keeps its own trust store and does not read the macOS System keychain by default."
  echo "This can enable Mozilla's official 'ImportEnterpriseRoots' policy, which makes Firefox trust"
  echo "whatever macOS already trusts (including the cert(s) just installed above, and any future ones)."

  if [[ -f "$FIREFOX_POLICY_FILE" ]]; then
    if grep -q '"ImportEnterpriseRoots"[[:space:]]*:[[:space:]]*true' "$FIREFOX_POLICY_FILE" 2>/dev/null; then
      log "Firefox enterprise-roots policy is already enabled at $FIREFOX_POLICY_FILE — nothing to do."
    else
      warn "A policies.json already exists at $FIREFOX_POLICY_FILE with other content:"
      cat "$FIREFOX_POLICY_FILE"
      warn "Not overwriting it automatically. To enable this manually, make sure it includes:"
      cat <<'EOF'
  {
    "policies": {
      "Certificates": {
        "ImportEnterpriseRoots": true
      }
    }
  }
EOF
    fi
  else
    if confirm "Create $FIREFOX_POLICY_FILE to enable this policy?"; then
      mkdir -p "$FIREFOX_POLICY_DIR"
      cat > "$FIREFOX_POLICY_FILE" <<'EOF'
{
  "policies": {
    "Certificates": {
      "ImportEnterpriseRoots": true
    }
  }
}
EOF
      log "Created $FIREFOX_POLICY_FILE. Restart Firefox for it to take effect."
    else
      log "Skipped Firefox policy setup."
    fi
  fi
else
  warn "Not running as root — skipping Firefox policy step. Re-run with sudo to include it."
fi

echo
log "Finished. Temp download directory ($WORKDIR) will now be removed."
