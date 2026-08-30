#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

RDP_USER="${RDP_USERNAME:-${SUDO_USER:-}}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
RDP_PORT="${RDP_PORT:-3389}"
ALLOW_FROM="${RDP_ALLOW_FROM:-0.0.0.0/0}"
PASSWORD_GENERATED=false

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo ./rdp_setup.sh [options]

Install an XRDP server with the XFCE desktop on Ubuntu 22.04 or 24.04.

Options:
  --username USER      Local account used to sign in over RDP
  --password PASSWORD  Set the account password (generated when omitted)
  --port PORT          RDP TCP port (default: 3389)
  --allow-from CIDR    Source allowed by active UFW (default: 0.0.0.0/0)
  -h, --help           Show this help

The same values can be supplied with RDP_USERNAME, RDP_PASSWORD, RDP_PORT and
RDP_ALLOW_FROM. Existing accounts are supported; missing accounts are created.
EOF
}

while (($# > 0)); do
  case "$1" in
    --username)
      (($# >= 2)) || fail "--username requires a value."
      RDP_USER="$2"
      shift 2
      ;;
    --password)
      (($# >= 2)) || fail "--password requires a value."
      RDP_PASSWORD="$2"
      shift 2
      ;;
    --port)
      (($# >= 2)) || fail "--port requires a value."
      RDP_PORT="$2"
      shift 2
      ;;
    --allow-from)
      (($# >= 2)) || fail "--allow-from requires a value."
      ALLOW_FROM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "Run this script as root (for example, sudo ./rdp_setup.sh)."
[[ -r /etc/os-release ]] || fail "Cannot determine the operating system."

# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "This script supports Ubuntu only."
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) fail "This script supports Ubuntu 22.04 and 24.04 only." ;;
esac

[[ -n "$RDP_USER" ]] || fail "Specify --username when sudo was not invoked by a regular user."
[[ "$RDP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
  fail "The username must be a valid lowercase Linux account name."
[[ "$RDP_USER" != "root" && "$RDP_USER" != "xrdp" ]] || \
  fail "Use a regular account, not root or xrdp."
[[ "$RDP_PORT" =~ ^[0-9]+$ ]] && ((RDP_PORT >= 1 && RDP_PORT <= 65535)) || \
  fail "The RDP port must be between 1 and 65535."
[[ "$ALLOW_FROM" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || \
  fail "--allow-from must be an IPv4 or IPv6 address/CIDR."

if [[ -z "$RDP_PASSWORD" ]]; then
  RANDOM_HEX="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  RDP_PASSWORD="Rdp1${RANDOM_HEX}"
  PASSWORD_GENERATED=true
fi
[[ "$RDP_PASSWORD" != *:* && "$RDP_PASSWORD" != *$'\n'* ]] || \
  fail "The password cannot contain a colon or newline."

if [[ ! "$RDP_PASSWORD" =~ [[:lower:]] || ! "$RDP_PASSWORD" =~ [[:upper:]] || \
  ! "$RDP_PASSWORD" =~ [[:digit:]] || ${#RDP_PASSWORD} -lt 12 ]]; then
  fail "The password must be at least 12 characters with uppercase, lowercase and a number."
fi

log "Installing XRDP and the XFCE desktop"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 policykit-1

if ! id "$RDP_USER" >/dev/null 2>&1; then
  log "Creating local account $RDP_USER"
  useradd --create-home --shell /bin/bash "$RDP_USER"
fi

USER_HOME="$(getent passwd "$RDP_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || fail "Cannot determine the home directory for $RDP_USER."

log "Configuring the RDP account and desktop session"
printf '%s:%s\n' "$RDP_USER" "$RDP_PASSWORD" | chpasswd
printf '%s\n' 'xfce4-session' >"$USER_HOME/.xsession"
chown "$RDP_USER:$RDP_USER" "$USER_HOME/.xsession"
chmod 600 "$USER_HOME/.xsession"

usermod -aG ssl-cert xrdp

XRDP_INI="/etc/xrdp/xrdp.ini"
if [[ ! -e "${XRDP_INI}.crosshelper-backup" ]]; then
  cp -a "$XRDP_INI" "${XRDP_INI}.crosshelper-backup"
fi
sed -i -E "0,/^port=/{s/^port=.*/port=$RDP_PORT/}" "$XRDP_INI"

log "Configuring firewall access"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow from "$ALLOW_FROM" to any port "$RDP_PORT" proto tcp
else
  printf 'UFW is not active; no host firewall rule was changed.\n'
fi

log "Starting XRDP"
systemctl enable --now xrdp
systemctl restart xrdp
systemctl is-active --quiet xrdp || \
  fail "XRDP did not start. Check: journalctl -u xrdp -u xrdp-sesman"

cat <<EOF

RDP setup complete.

Username:     $RDP_USER
Password:     $RDP_PASSWORD
TCP port:     $RDP_PORT
Allowed CIDR: $ALLOW_FROM (applied only when UFW was already active)

Connect with Microsoft Remote Desktop to SERVER_ADDRESS:$RDP_PORT and select
the Xorg session. Allow TCP port $RDP_PORT in your hosting provider's firewall.
For better security, restrict --allow-from to your public IP/CIDR or connect
through the VPN instead of exposing RDP to the internet.
EOF

if [[ "$PASSWORD_GENERATED" == true ]]; then
  printf '\nStore the generated password now; it is not written to another file.\n'
fi