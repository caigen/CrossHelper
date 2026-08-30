#!/usr/bin/env bash

set -Eeuo pipefail

readonly REMOTE_CERT="/etc/ipsec.d/cacerts/ca-cert.pem"

SSH_PORT=22
OUTPUT_FILE="crosshelper-ca-cert.pem"
OVERWRITE=false
SSH_TARGET=""
TEMP_FILE=""

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./download_cert.sh [options] USER@SERVER

Download the CrossHelper public CA certificate from the VPN server over SSH.

Options:
  -o, --output FILE  Output file (default: crosshelper-ca-cert.pem)
  -p, --port PORT    SSH port (default: 22)
  -f, --force        Overwrite an existing output file
  -h, --help         Show this help

Example:
  ./download_cert.sh -o vpn-ca.pem ubuntu@vpn.example.com
EOF
}

cleanup() {
  if [[ -n "$TEMP_FILE" ]]; then
    rm -f "$TEMP_FILE"
  fi
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    -o|--output)
      (($# >= 2)) || fail "$1 requires a value."
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -p|--port)
      (($# >= 2)) || fail "$1 requires a value."
      SSH_PORT="$2"
      shift 2
      ;;
    -f|--force)
      OVERWRITE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "Unknown option: $1"
      ;;
    *)
      [[ -z "$SSH_TARGET" ]] || fail "Specify only one SSH target."
      SSH_TARGET="$1"
      shift
      ;;
  esac
done

[[ -n "$SSH_TARGET" ]] || fail "Specify the VPN server as USER@SERVER."
[[ "$SSH_TARGET" != *[[:space:]]* ]] || fail "The SSH target cannot contain whitespace."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || \
  fail "The SSH port must be between 1 and 65535."
command -v scp >/dev/null 2>&1 || fail "scp is required. Install an OpenSSH client first."

if [[ -e "$OUTPUT_FILE" && "$OVERWRITE" != true ]]; then
  fail "$OUTPUT_FILE already exists. Use --force to replace it."
fi

OUTPUT_DIRECTORY="$(dirname "$OUTPUT_FILE")"
[[ -d "$OUTPUT_DIRECTORY" ]] || fail "Output directory does not exist: $OUTPUT_DIRECTORY"
TEMP_FILE="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")"

printf 'Downloading the public CA certificate from %s...\n' "$SSH_TARGET"
scp -P "$SSH_PORT" "${SSH_TARGET}:${REMOTE_CERT}" "$TEMP_FILE"

grep -q '^-----BEGIN CERTIFICATE-----$' "$TEMP_FILE" && \
  grep -q '^-----END CERTIFICATE-----$' "$TEMP_FILE" || \
  fail "The downloaded file is not a PEM certificate."

if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "$TEMP_FILE" -noout >/dev/null || \
    fail "OpenSSL could not parse the downloaded certificate."
fi

mv -f "$TEMP_FILE" "$OUTPUT_FILE"
TEMP_FILE=""
chmod 644 "$OUTPUT_FILE"

printf 'Saved CA certificate to %s\n' "$OUTPUT_FILE"
if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "$OUTPUT_FILE" -noout -subject -fingerprint -sha256
fi