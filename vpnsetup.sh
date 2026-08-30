#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly VPN_SUBNET="${VPN_SUBNET:-10.10.10.0/24}"
readonly VPN_DNS_SERVERS="${VPN_DNS_SERVERS:-1.1.1.1,1.0.0.1}"
readonly CA_NAME="${CA_NAME:-CrossHelper IKEv2 VPN CA}"
readonly IPSEC_DIR="/etc/ipsec.d"
readonly SYSCTL_FILE="/etc/sysctl.d/99-crosshelper-ikev2.conf"
readonly CA_EXPORT="/root/crosshelper-ca-cert.pem"

SERVER_NAME="${VPN_SERVER_NAME:-}"
VPN_USERNAME="${VPN_USERNAME:-vpnuser}"
VPN_PASSWORD="${VPN_PASSWORD:-}"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo ./vpnsetup.sh [options]

Set up an IKEv2/IPsec VPN server on Ubuntu 24.04.

Options:
  --server-name NAME   Public DNS name or IP address of this server
  --username USER      VPN username (default: vpnuser)
  --password PASSWORD  VPN password (generated when omitted)
  -h, --help           Show this help

The same values can be supplied with VPN_SERVER_NAME, VPN_USERNAME and
VPN_PASSWORD. Optional settings: VPN_SUBNET, VPN_DNS_SERVERS and CA_NAME.
EOF
}

while (($# > 0)); do
  case "$1" in
    --server-name)
      (($# >= 2)) || fail "--server-name requires a value."
      SERVER_NAME="$2"
      shift 2
      ;;
    --username)
      (($# >= 2)) || fail "--username requires a value."
      VPN_USERNAME="$2"
      shift 2
      ;;
    --password)
      (($# >= 2)) || fail "--password requires a value."
      VPN_PASSWORD="$2"
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

[[ "${EUID}" -eq 0 ]] || fail "Run this script as root (for example, sudo ./vpnsetup.sh)."
[[ -r /etc/os-release ]] || fail "Cannot determine the operating system."

# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
  fail "This script supports Ubuntu 24.04 only."

[[ "$VPN_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || \
  fail "The username may contain only letters, numbers, dot, underscore, @ and hyphen."

if [[ -z "$VPN_PASSWORD" ]]; then
  VPN_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
fi
[[ "$VPN_PASSWORD" != *\"* && "$VPN_PASSWORD" != *\'* && \
  "$VPN_PASSWORD" != *\\* && "$VPN_PASSWORD" != *$'\n'* ]] || \
  fail "The password cannot contain quotes, backslashes or newlines."

log "Installing strongSwan and firewall packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | debconf-set-selections
printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | debconf-set-selections
apt-get install -y --no-install-recommends \
  strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins \
  iptables-persistent ca-certificates curl

if [[ -z "$SERVER_NAME" ]]; then
  log "Detecting the server's public IPv4 address"
  SERVER_NAME="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || \
  fail "Set --server-name to a valid public DNS name or IPv4 address."

PUBLIC_INTERFACE="$(ip -4 route show default | awk 'NR == 1 { print $5 }')"
[[ -n "$PUBLIC_INTERFACE" ]] || fail "Cannot determine the default network interface."

backup_file() {
  local path="$1"
  if [[ -e "$path" && ! -e "${path}.crosshelper-backup" ]]; then
    cp -a "$path" "${path}.crosshelper-backup"
  fi
}

add_iptables_rule() {
  local table="$1"
  local chain="$2"
  shift 2
  if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    iptables -t "$table" -I "$chain" 1 "$@"
  fi
}

log "Creating the VPN certificate authority and server certificate"
install -d -m 700 "$IPSEC_DIR/private"
install -d -m 755 "$IPSEC_DIR/cacerts" "$IPSEC_DIR/certs"

pki --gen --type rsa --size 4096 --outform pem >"$IPSEC_DIR/private/ca-key.pem"
pki --self --ca --lifetime 3650 \
  --in "$IPSEC_DIR/private/ca-key.pem" --type rsa \
  --dn "CN=$CA_NAME" --outform pem >"$IPSEC_DIR/cacerts/ca-cert.pem"

pki --gen --type rsa --size 3072 --outform pem >"$IPSEC_DIR/private/server-key.pem"
pki --issue --lifetime 1825 \
  --cacert "$IPSEC_DIR/cacerts/ca-cert.pem" \
  --cakey "$IPSEC_DIR/private/ca-key.pem" \
  --in "$IPSEC_DIR/private/server-key.pem" --type rsa \
  --dn "CN=$SERVER_NAME" --san "$SERVER_NAME" \
  --flag serverAuth --flag ikeIntermediate --outform pem \
  >"$IPSEC_DIR/certs/server-cert.pem"

chmod 600 "$IPSEC_DIR/private/ca-key.pem" "$IPSEC_DIR/private/server-key.pem"
chmod 644 "$IPSEC_DIR/cacerts/ca-cert.pem"
cp "$IPSEC_DIR/cacerts/ca-cert.pem" "$CA_EXPORT"
chmod 644 "$CA_EXPORT"

log "Writing strongSwan configuration"
backup_file /etc/ipsec.conf
backup_file /etc/ipsec.secrets

cat >/etc/ipsec.conf <<EOF
config setup
  uniqueids=no

conn ikev2-vpn
  auto=add
  type=tunnel
  keyexchange=ikev2
  fragmentation=yes
  forceencaps=yes
  dpdaction=clear
  dpddelay=300s
  rekey=no
  left=%any
  leftid=$SERVER_NAME
  leftcert=server-cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  rightsourceip=$VPN_SUBNET
  rightdns=$VPN_DNS_SERVERS
  rightsendcert=never
  eap_identity=%identity
  ike=aes256gcm16-prfsha384-ecp384,aes256gcm16-prfsha256-modp2048,aes256-sha256-modp2048!
  esp=aes256gcm16-ecp384,aes256gcm16,aes256-sha256!
EOF

cat >/etc/ipsec.secrets <<EOF
: RSA server-key.pem
$VPN_USERNAME : EAP "$VPN_PASSWORD"
EOF
chmod 600 /etc/ipsec.secrets

log "Enabling IPv4 forwarding"
cat >"$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
sysctl --system >/dev/null

log "Configuring persistent firewall rules"
add_iptables_rule filter INPUT -p udp --dport 500 -j ACCEPT
add_iptables_rule filter INPUT -p udp --dport 4500 -j ACCEPT
add_iptables_rule filter FORWARD -s "$VPN_SUBNET" -o "$PUBLIC_INTERFACE" -j ACCEPT
add_iptables_rule filter FORWARD -d "$VPN_SUBNET" -i "$PUBLIC_INTERFACE" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
add_iptables_rule nat POSTROUTING -s "$VPN_SUBNET" -o "$PUBLIC_INTERFACE" -m policy \
  --dir out --pol none -j MASQUERADE
netfilter-persistent save >/dev/null

log "Starting the VPN service"
systemctl enable --now strongswan-starter
ipsec restart
sleep 2
ipsec status >/dev/null || fail "strongSwan did not start successfully. Check: journalctl -u strongswan-starter"

cat <<EOF

IKEv2 VPN setup complete.

Server:        $SERVER_NAME
Username:      $VPN_USERNAME
Password:      $VPN_PASSWORD
CA certificate: $CA_EXPORT

Install the CA certificate on each client, then create an IKEv2 connection
using the server, username and password above. Also allow inbound UDP ports
500 and 4500 in your hosting provider's firewall or security group.
EOF