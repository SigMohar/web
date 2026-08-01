#!/usr/bin/env bash
#
# install_SigMohar_roots.sh
#
# Downloads CA certificates from ca.sigmohar.com and, ONLY after explicit
# confirmation at each step, trusts them:
#   1. System-wide (OS trust store used by curl, openssl, most system tools)
#   2. In NSS certificate databases (Chrome/Chromium's ~/.pki/nssdb and
#      Firefox profile cert databases), since NSS-based apps keep their
#      own trust store and ignore the OS one on Linux.
#
# DESIGN PRINCIPLES (per explicit request):
#   - No auto-discovery of cert IDs. You list them yourself in CERT_IDS below.
#   - No dependency is installed without asking first, and being told why
#     it's needed.
#   - Every action that changes something on the system (trust store,
#     NSS databases) requires an explicit y/N confirmation, showing exactly
#     what will be affected.
#   - Downloaded files live only in a temp directory, which is removed
#     when the script exits (success, failure, or Ctrl-C).
#
# USAGE:
#   ./install_SigMohar_roots.sh                  # interactive category menu (1/2/3)
#   ./install_SigMohar_roots.sh --category 2      # pick a category non-interactively
#   ./install_SigMohar_roots.sh abcd1234 ef56..   # bypass categories, install exactly these IDs
#   ./install_SigMohar_roots.sh -y --category 3   # skip confirmations too (use with care)

set -euo pipefail

### ---------------------------- CONFIG ---------------------------- ###

BASE_URL="${BASE_URL:-https://ca.sigmohar.com/r}"

# Cert IDs (the "XXXX" part of https://ca.sigmohar.com/r/XXXX.crt) are
# grouped into three categories below. At runtime you'll be asked which
# category to install (or pass --category N / explicit IDs to skip the
# prompt). The script never installs anything beyond what's listed in
# the category you choose — it will not try to guess or discover any
# other certs on its own.

# ---- Category 1: Comm-Set Roots -------------------------------------
# TLS-only roots (server/client TLS certificates).
# Add the relevant cert IDs below, one per line.
COMM_SET_ROOTS=(
  "C1-R"
  "C2-R"
)

# ---- Category 2 adds: Sign-Set Roots ---------------------------------
# eSign / code signing / device ID / S-MIME roots.
# Installed together with Comm-Set when category 2 or 3 is chosen.
# Add the relevant cert IDs below, one per line.
SIGN_SET_ROOTS=(
  "S1-R"
  "S2-R"
  "S3-R"
  "S4-R"
  "S5-R"
)

# ---- Category 3 adds: PKI-Set Roots -----------------------------------
# Your custom/internal PKI roots.
# Installed only when category 3 (Full Set) is chosen.
# Add the relevant cert IDs below, one per line.
PKI_SET_ROOTS=(
  "P1-R"
)

### -------------------------- END CONFIG --------------------------- ###

WORKDIR=$(mktemp -d -t sigmohar-roots-XXXXXX)
ASSUME_YES=0

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# Asks a yes/no question. Returns 0 for yes, 1 for no (safe default = no).
confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "(auto-confirmed via -y) $prompt"
    return 0
  fi
  local reply=""
  read -r -p "$prompt [y/N]: " reply < /dev/tty || reply=""
  case "$reply" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

IS_ROOT=0
[[ $EUID -eq 0 ]] && IS_ROOT=1

# --------------------------------------------------------------------
# 0. Parse arguments, then figure out which cert IDs to install:
#    either an explicit ID list (bypasses categories entirely), or a
#    category chosen via --category / -c, or an interactive menu.
# --------------------------------------------------------------------

CATEGORY=""
CERT_ID_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    -c|--category)
      CATEGORY="${2:-}"
      shift 2
      ;;
    --category=*)
      CATEGORY="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--category 1|2|3] [-y] [explicit-cert-id ...]"
      exit 0
      ;;
    *)
      CERT_ID_ARGS+=("$1")
      shift
      ;;
  esac
done

CERT_IDS=()

if [[ ${#CERT_ID_ARGS[@]} -gt 0 ]]; then
  # Explicit IDs were given on the command line — install exactly these,
  # skip category selection entirely.
  CERT_IDS=("${CERT_ID_ARGS[@]}")
  log "Explicit cert ID(s) given on the command line — skipping category selection."
else
  if [[ -z "$CATEGORY" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      err "-y/--yes was given without --category or explicit cert IDs."
      err "Refusing to guess which certificate set to install — re-run with e.g. '--category 2', or pass explicit cert IDs."
      exit 1
    fi
    echo
    echo "Select which certificate set to install:"
    echo "  1) Comm-Set only              - TLS certificates only"
    echo "  2) Comm-Set + Sign-Set        - TLS + eSign / code signing / device ID / S-MIME"
    echo "  3) Full Set (Comm+Sign+PKI)   - TLS + eSign + your custom internal PKI roots"
    read -r -p "Enter choice [1-3]: " CATEGORY < /dev/tty
  fi

  case "$CATEGORY" in
    1) CERT_IDS=( "${COMM_SET_ROOTS[@]}" ) ;;
    2) CERT_IDS=( "${COMM_SET_ROOTS[@]}" "${SIGN_SET_ROOTS[@]}" ) ;;
    3) CERT_IDS=( "${COMM_SET_ROOTS[@]}" "${SIGN_SET_ROOTS[@]}" "${PKI_SET_ROOTS[@]}" ) ;;
    *)
      err "Invalid category '$CATEGORY' — must be 1, 2, or 3."
      exit 1
      ;;
  esac
  log "Category $CATEGORY selected."
fi

if [[ ${#CERT_IDS[@]} -eq 0 ]]; then
  err "No cert IDs configured for this selection. Edit COMM_SET_ROOTS / SIGN_SET_ROOTS / PKI_SET_ROOTS in this script,"
  err "or pass IDs as arguments: ./install_SigMohar_roots.sh xxxx1 xxxx2"
  exit 1
fi

# --------------------------------------------------------------------
# 1. Distro detection (for picking the right update command / package names)
# --------------------------------------------------------------------

detect_distro_family() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
      *debian*|*ubuntu*) echo "debian"; return ;;
      *rhel*|*fedora*|*centos*|*rocky*|*alma*) echo "rhel"; return ;;
      *arch*) echo "arch"; return ;;
    esac
  fi
  echo "unknown"
}
DISTRO_FAMILY=$(detect_distro_family)
log "Detected distro family: $DISTRO_FAMILY"

# --------------------------------------------------------------------
# 2. Dependency checks — ask before installing anything
# --------------------------------------------------------------------

install_package() {
  local pkg="$1"
  case "$DISTRO_FAMILY" in
    debian) apt-get update -qq && apt-get install -y "$pkg" ;;
    rhel)   (command -v dnf >/dev/null 2>&1 && dnf install -y "$pkg") || yum install -y "$pkg" ;;
    arch)   pacman -Sy --noconfirm "$pkg" ;;
    *) return 1 ;;
  esac
}

# $1=command to check, $2=debian pkg, $3=rhel pkg, $4=arch pkg, $5=human reason
# Returns 0 if the command ends up available, 1 if not.
ensure_dependency() {
  local cmd="$1" pkg_debian="$2" pkg_rhel="$3" pkg_arch="$4" reason="$5"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  echo
  echo "Missing tool: $cmd"
  echo "Needed for: $reason"

  local pkg=""
  case "$DISTRO_FAMILY" in
    debian) pkg="$pkg_debian" ;;
    rhel)   pkg="$pkg_rhel" ;;
    arch)   pkg="$pkg_arch" ;;
    *)
      warn "Unrecognized distro — please install '$cmd' manually, then re-run this script."
      return 1
      ;;
  esac

  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not running as root — cannot install '$pkg' automatically. Install it manually (e.g. with sudo) and re-run."
    return 1
  fi

  if confirm "Install package '$pkg' now (needed for: $reason)?"; then
    if install_package "$pkg"; then
      command -v "$cmd" >/dev/null 2>&1 && return 0
    fi
    err "Installation of '$pkg' did not result in '$cmd' being available."
    return 1
  else
    warn "Skipped installing '$pkg'. Functionality needing '$cmd' will be skipped."
    return 1
  fi
}

HAVE_CURL=0
HAVE_OPENSSL=0
HAVE_CERTUTIL=0

ensure_dependency curl curl curl curl \
  "downloading certificate files from ${BASE_URL} over HTTPS" && HAVE_CURL=1

ensure_dependency openssl openssl openssl openssl \
  "validating and normalizing downloaded certificates (PEM/DER) before anything is trusted" && HAVE_OPENSSL=1

ensure_dependency certutil libnss3-tools nss-tools nss \
  "adding certificates to NSS trust databases used by Chrome/Chromium and Firefox (the OS trust store alone does not cover these browsers on Linux)" && HAVE_CERTUTIL=1

if [[ $HAVE_CURL -ne 1 || $HAVE_OPENSSL -ne 1 ]]; then
  err "curl and openssl are both required for this script to do anything. Exiting."
  exit 1
fi

if [[ $HAVE_CERTUTIL -ne 1 ]]; then
  warn "Proceeding without certutil — NSS database installation (Chrome/Chromium, Firefox) will be skipped."
fi

# --------------------------------------------------------------------
# 3. Download + validate each cert into the temp dir (no system changes yet)
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

# Populated as: PEM_FILES[id]=path, NICKNAMES[id]=name
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
# 4. System-wide trust store — confirm before touching anything
# --------------------------------------------------------------------

install_system_wide_one() {
  local pem="$1" name="$2"
  local safe_name
  safe_name=$(echo "$name" | tr -cs 'A-Za-z0-9._-' '_')
  local dest=""

  case "$DISTRO_FAMILY" in
    debian) dest="/usr/local/share/ca-certificates/${safe_name}.crt" ;;
    rhel)   dest="/etc/pki/ca-trust/source/anchors/${safe_name}.pem" ;;
    arch)   dest="/etc/ca-certificates/trust-source/anchors/${safe_name}.pem" ;;
    *) warn "Unrecognized distro — cannot install '$name' into the system trust store."; return 1 ;;
  esac

  if [[ -e "$dest" ]]; then
    if ! confirm "A file already exists at $dest — overwrite it with the new '$name' cert?"; then
      warn "Skipped system-wide install for '$name' (existing file kept)."
      return 1
    fi
  fi

  cp "$pem" "$dest"
  log "Copied '$name' to $dest"
  return 0
}

if [[ $IS_ROOT -eq 1 ]]; then
  echo
  echo "The following cert(s) can be added to the SYSTEM-WIDE trust store."
  echo "This affects every application and user on this machine that relies on the OS trust store (curl, openssl, apt/yum, etc.)."
  for id in "${!PEM_FILES[@]}"; do
    echo "  - ${NICKNAMES[$id]}"
  done
  if confirm "Proceed with system-wide trust store installation?"; then
    ANY_INSTALLED=0
    for id in "${!PEM_FILES[@]}"; do
      if install_system_wide_one "${PEM_FILES[$id]}" "${NICKNAMES[$id]}"; then
        ANY_INSTALLED=1
      fi
    done
    if [[ $ANY_INSTALLED -eq 1 ]]; then
      case "$DISTRO_FAMILY" in
        debian)
          if confirm "Run 'update-ca-certificates' now to activate the change?"; then
            update-ca-certificates
          else
            warn "Skipped 'update-ca-certificates' — installed file(s) are not yet active."
          fi
          ;;
        rhel)
          if confirm "Run 'update-ca-trust extract' now to activate the change?"; then
            update-ca-trust extract
          else
            warn "Skipped 'update-ca-trust extract' — installed file(s) are not yet active."
          fi
          ;;
        arch)
          if confirm "Run 'trust extract-compat' now to activate the change?"; then
            trust extract-compat
          else
            warn "Skipped 'trust extract-compat' — installed file(s) are not yet active."
          fi
          ;;
      esac
    fi
  else
    log "Skipped system-wide trust store installation."
  fi
else
  warn "Not running as root — skipping system-wide trust store step entirely. Re-run with sudo to include it."
fi

# --------------------------------------------------------------------
# 5. NSS databases (Chrome/Chromium + Firefox) — confirm before touching
# --------------------------------------------------------------------

install_into_nssdb() {
  local db="$1" nick="$2" pem="$3"
  certutil -D -n "$nick" -d "$db" >/dev/null 2>&1 || true
  if certutil -A -n "$nick" -t "C,," -i "$pem" -d "$db" 2>/dev/null; then
    log "  -> trusted in $db as '$nick'"
  else
    warn "  -> failed to add '$nick' to $db"
  fi
}

ensure_nssdb_exists() {
  local dir="$1"
  if [[ ! -f "$dir/cert9.db" && ! -f "$dir/cert8.db" ]]; then
    mkdir -p "$dir"
    certutil -N -d "sql:$dir" --empty-password >/dev/null 2>&1 || true
  fi
}

nssdb_prefix_for() {
  local dir="$1"
  if [[ -f "$dir/cert9.db" ]]; then
    echo "sql:$dir"
  elif [[ -f "$dir/cert8.db" ]]; then
    echo "dbm:$dir"
  else
    echo "sql:$dir"
  fi
}

get_target_homes() {
  if [[ $IS_ROOT -eq 1 ]]; then
    awk -F: '($3>=1000 && $3<60000){print $1":"$6} $1=="root"{print $1":"$6}' /etc/passwd | sort -u
  else
    echo "$(id -un):$HOME"
  fi
}

if [[ $HAVE_CERTUTIL -eq 1 ]]; then
  mapfile -t TARGET_HOMES < <(get_target_homes)

  echo
  echo "The following cert(s) can be added to NSS certificate databases (used by Chrome/Chromium and Firefox):"
  for id in "${!PEM_FILES[@]}"; do
    echo "  - ${NICKNAMES[$id]}"
  done
  echo "For these users (Chrome/Chromium ~/.pki/nssdb, and any Firefox profiles found):"
  for entry in "${TARGET_HOMES[@]}"; do
    echo "  - ${entry%%:*} (${entry#*:})"
  done
  [[ -d /etc/pki/nssdb ]] && [[ $IS_ROOT -eq 1 ]] && echo "  - system NSS db (/etc/pki/nssdb)"

  if confirm "Proceed with installing into these NSS databases?"; then

    if [[ $IS_ROOT -eq 1 && -d /etc/pki/nssdb ]]; then
      log "Installing into system NSS db (/etc/pki/nssdb)"
      for id in "${!PEM_FILES[@]}"; do
        install_into_nssdb "sql:/etc/pki/nssdb" "${NICKNAMES[$id]}" "${PEM_FILES[$id]}"
      done
    fi

    for entry in "${TARGET_HOMES[@]}"; do
      user="${entry%%:*}"
      home="${entry#*:}"
      [[ -d "$home" ]] || continue

      chrome_db="$home/.pki/nssdb"
      ensure_nssdb_exists "$chrome_db"
      log "Installing into Chrome/Chromium NSS db for $user ($chrome_db)"
      for id in "${!PEM_FILES[@]}"; do
        install_into_nssdb "sql:$chrome_db" "${NICKNAMES[$id]}" "${PEM_FILES[$id]}"
      done
      if [[ $IS_ROOT -eq 1 ]]; then
        owner=$(stat -c '%U:%G' "$home" 2>/dev/null || echo "$user:$user")
        chown -R "$owner" "$home/.pki" 2>/dev/null || true
      fi

      if [[ -d "$home/.mozilla/firefox" ]]; then
        while IFS= read -r profile_dir < /dev/tty; do
          [[ -d "$profile_dir" ]] || continue
          prefix=$(nssdb_prefix_for "$profile_dir")
          log "Installing into Firefox profile for $user ($profile_dir)"
          for id in "${!PEM_FILES[@]}"; do
            install_into_nssdb "$prefix" "${NICKNAMES[$id]}" "${PEM_FILES[$id]}"
          done
        done < <(find "$home/.mozilla/firefox" -maxdepth 1 -type d \( -name "*.default*" -o -name "*.dev-edition*" \) 2>/dev/null)
      fi
    done
  else
    log "Skipped NSS database installation."
  fi
else
  log "Skipping NSS database step (certutil unavailable)."
fi

# --------------------------------------------------------------------
# 6. Done — temp dir is removed automatically by the trap on exit
# --------------------------------------------------------------------

echo
log "Finished. Temp download directory ($WORKDIR) will now be removed."