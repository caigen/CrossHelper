# CrossHelper

CrossHelper provides scripts for setting up an IKEv2/IPsec VPN and an XRDP
desktop server on Ubuntu.

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

To download the public CA certificate over SSH from a Linux, macOS, WSL, or
Git Bash client, run:

```bash
chmod +x download_cert.sh
./download_cert.sh ubuntu@vpn.example.com
```

The certificate is saved as `crosshelper-ca-cert.pem` in the current directory.
Use `--output FILE` to choose another path, `--port PORT` for a non-default SSH
port, or `--force` to replace an existing file. The downloader never accesses
the CA private key or server private key.

On a server installed with an earlier version of the setup script, make the
public certificate downloadable once without rerunning the installer:

```bash
sudo chmod 644 /etc/ipsec.d/cacerts/ca-cert.pem
```

Run `./vpnsetup.sh --help` to see all options and optional environment settings.

## RDP Server

Install XRDP with the XFCE desktop on Ubuntu 22.04 or 24.04:

```bash
chmod +x rdp_setup.sh
sudo ./rdp_setup.sh \
	--username rdpuser \
	--allow-from 203.0.113.10/32
```

When the account does not exist, the script creates it. When `--password` is
omitted, it generates and prints a password. To supply one without putting it
in shell history:

```bash
sudo RDP_USERNAME=rdpuser \
	RDP_PASSWORD='ReplaceWithStrongPassword1' \
	RDP_ALLOW_FROM='203.0.113.10/32' \
	./rdp_setup.sh
```

Connect using Microsoft Remote Desktop to `SERVER_ADDRESS:3389`, sign in with
the configured account, and select the Xorg session. If UFW is already active,
the script allows the selected source CIDR. You must separately allow TCP port
3389 in the hosting provider's firewall or security group.

Avoid exposing RDP to `0.0.0.0/0`. Restrict it to your public IP or connect to
the server through the IKEv2 VPN. Manage the service with:

```bash
sudo systemctl start xrdp
sudo systemctl stop xrdp
sudo systemctl restart xrdp
sudo systemctl status xrdp
```

Run `./rdp_setup.sh --help` for all RDP options.
