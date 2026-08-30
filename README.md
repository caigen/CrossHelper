# CrossHelper

CrossHelper provides one script that installs and configures an IKEv2/IPsec
VPN server on Ubuntu 24.04 using strongSwan.

## Requirements

- A fresh Ubuntu 24.04 server with a public IPv4 address
- Root or `sudo` access
- Inbound UDP ports 500 and 4500 allowed by the provider firewall/security group
- A public DNS name pointing to the server (recommended), or the server's public IP

## Setup

Run the installer as root. When `--password` is omitted, the script generates
and prints a secure password.

```bash
chmod +x vpnsetup.sh
sudo ./vpnsetup.sh \
	--server-name vpn.example.com \
	--username vpnuser
```

You can use environment variables instead of command-line options, which keeps
the password out of shell history:

```bash
sudo VPN_SERVER_NAME=vpn.example.com \
	VPN_USERNAME=vpnuser \
	VPN_PASSWORD='replace-with-a-strong-password' \
	./vpnsetup.sh
```

The installer:

- Installs strongSwan from the Ubuntu repositories
- Creates a private certificate authority and server certificate
- Configures IKEv2 with EAP-MSCHAPv2 username/password authentication
- Enables IPv4 forwarding and persistent NAT/firewall rules
- Starts and enables `strongswan-starter`

The generated client CA certificate is saved to
`/root/crosshelper-ca-cert.pem`. Transfer it to each client over a trusted
channel, install it as a trusted VPN certificate, and create an IKEv2 connection
using the server name, username and password printed by the installer.

Run `./vpnsetup.sh --help` to see all options and optional environment settings.
