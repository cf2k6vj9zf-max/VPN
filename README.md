# VPN stack for Ubuntu + Shadowrocket

This repository contains an automated setup for a fresh Ubuntu server that installs:

- Xray with VLESS over TLS
- Trojan over TLS
- Shadowsocks
- optional WireGuard
- Let's Encrypt IP certificate issuance and renewal
- client artifacts for Shadowrocket
- a Shadowrocket rule config that sends RU destinations directly while VPN/proxy stays enabled for everything else

The current target server from the request is:

- `77.246.105.100`

## What gets generated

After installation on the server, the script creates:

- `/root/vpn-clients/vless.uri`
- `/root/vpn-clients/trojan.uri`
- `/root/vpn-clients/shadowsocks.uri`
- `/root/vpn-clients/shadowrocket-links.txt`
- `/root/vpn-clients/shadowrocket-subscription.base64.txt`
- `/root/vpn-clients/vless.png`
- `/root/vpn-clients/trojan.png`
- `/root/vpn-clients/shadowsocks.png`
- `/root/vpn-clients/shadowrocket-ru-direct.conf`
- `/root/vpn-clients/wireguard-client.conf` when WireGuard is enabled
- `/etc/xray/tls/server-combined.pem` as a single bundled PEM file with private key + certificate chain

That last file addresses the "all certificates in one file" convenience requirement on the server side.

## Important note about TLS on an IP address

The installer uses modern Let's Encrypt support for IP certificates. These certificates are short-lived, so the script also creates a `systemd` timer to renew them regularly.

Requirements:

- port `80/tcp` must be reachable during issuance/renewal
- the public server IP must really be `77.246.105.100`

## Files in this repo

- `scripts/install_vpn_stack.sh` - run on the Ubuntu server as root
- `scripts/deploy_vpn_stack.sh` - copy installer to the server over SSH and run it
- `config/vpn-stack.env.example` - configuration template

## Quick start

### 1. Create your env file

```bash
mkdir -p config
cp config/vpn-stack.env.example config/vpn-stack.env
```

Edit `config/vpn-stack.env` if you want to change ports, email, WireGuard, or client labels.

At minimum, review:

- `SERVER_IP`
- `ACME_EMAIL`
- `ENABLE_WIREGUARD`

### 2. Run the bootstrap from your local machine

If your root SSH access is already enabled:

```bash
bash scripts/deploy_vpn_stack.sh root@77.246.105.100 /root/vpn-stack.env ./config/vpn-stack.env
```

This will:

1. upload the installer
2. upload your env file
3. run the installation remotely
4. download the generated client files into `./artifacts/77.246.105.100/`

### 3. Or run directly on the server

Copy the files manually, then on the server:

```bash
sudo bash /root/install_vpn_stack.sh /root/vpn-stack.env
```

## What the installer does

The installer is idempotent enough for repeated runs and will:

1. install Ubuntu packages
2. install latest `certbot` if the distro version does not support `--ip-address`
3. generate secrets for VLESS, Trojan, Shadowsocks, and WireGuard
4. install latest Xray
5. request an IP certificate for `SERVER_IP`
6. build `/etc/xray/config.json`
7. enable IP forwarding
8. optionally configure WireGuard
9. generate client files and QR codes
10. enable `xray.service`, `wg-quick@wg0.service`, and the certificate renewal timer

## Default ports

- Trojan TLS: `443/tcp`
- VLESS TLS: `8443/tcp`
- Shadowsocks: `8388/tcp` and `8388/udp`
- WireGuard: `51820/udp`
- ACME validation: `80/tcp`

## Shadowrocket usage

Recommended import flow:

1. Import one of the transport nodes:
   - scan `trojan.png`, or
   - scan `vless.png`, or
   - import from `shadowrocket-links.txt`
2. Import `shadowrocket-ru-direct.conf`
3. Enable that imported config

The rules file uses:

- `DOMAIN-SUFFIX,ru,DIRECT`
- `DOMAIN-SUFFIX,su,DIRECT`
- `DOMAIN-SUFFIX,xn--p1ai,DIRECT`
- several keyword shortcuts for common RU services
- `GEOIP,RU,DIRECT`
- `FINAL,PROXY`

This means Russian sites should open directly even when the VPN/proxy profile is enabled in Shadowrocket, while everything else uses the proxy node.

## WireGuard note

WireGuard support is included as an option because Shadowrocket supports it, but the main setup is optimized for Xray/Trojan/Shadowsocks for best Shadowrocket compatibility.

If you enable WireGuard, the installer will generate:

- `/root/vpn-clients/wireguard-client.conf`

You can import it separately in a compatible client flow.

## Server-side outputs

Useful paths on the server:

- Xray config: `/etc/xray/config.json`
- TLS files: `/etc/xray/tls/`
- generated secrets: `/etc/vpn-stack/secrets.env`
- client bundle: `/root/vpn-clients/`

## Security notes

- The generated secrets file contains all credentials. Keep it private.
- The bundled PEM file includes the private key. Do not share it with clients.
- If you rerun the installer, existing secrets are preserved unless you delete `/etc/vpn-stack/secrets.env`.

## Verification commands on the server

```bash
systemctl status xray --no-pager
systemctl status wg-quick@wg0 --no-pager
systemctl status vpn-cert-renew.timer --no-pager
ss -tulpn | rg ':(80|443|8388|8443|51820)\b'
```

## If RU sites still do not open

Check these items:

1. the Shadowrocket rules profile is enabled
2. node selection is still set to the imported proxy
3. DNS in Shadowrocket is not forcing all lookups remotely
4. the destination is really geolocated to RU

For some services, domain-based direct rules may work better than GEOIP alone, so the config already includes `.ru`, `.su`, `xn--p1ai`, and several RU service keywords.
