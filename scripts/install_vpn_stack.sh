#!/usr/bin/env bash
set -euo pipefail

umask 077

CONFIG_FILE="${1:-/root/vpn-stack.env}"
STACK_DIR="/etc/vpn-stack"
SECRETS_FILE="${STACK_DIR}/secrets.env"
XRAY_DIR="/etc/xray"
XRAY_TLS_DIR="${XRAY_DIR}/tls"
CLIENT_DIR="/root/vpn-clients"

log() {
  printf '[vpn-stack] %s\n' "$*"
}

fail() {
  printf '[vpn-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "run this script as root"
  fi
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  SERVER_IP="${SERVER_IP:-77.246.105.100}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  ACME_STAGING="${ACME_STAGING:-false}"
  ENABLE_WIREGUARD="${ENABLE_WIREGUARD:-true}"
  VLESS_PORT="${VLESS_PORT:-8443}"
  TROJAN_PORT="${TROJAN_PORT:-443}"
  SS_PORT="${SS_PORT:-8388}"
  WG_PORT="${WG_PORT:-51820}"
  WG_NETWORK_CIDR="${WG_NETWORK_CIDR:-10.66.66.0/24}"
  WG_SERVER_ADDRESS="${WG_SERVER_ADDRESS:-10.66.66.1/24}"
  WG_CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-10.66.66.2/32}"
  WG_DNS="${WG_DNS:-1.1.1.1, 8.8.8.8}"
  CLIENT_NAME="${CLIENT_NAME:-shadowrocket-iphone}"
  XRAY_SNI="${XRAY_SNI:-${SERVER_IP}}"
  LE_PROFILE="${LE_PROFILE:-shortlived}"
  CERTBOT_VENV="${CERTBOT_VENV:-/opt/certbot}"
  CERT_DIR="/etc/letsencrypt/live/${SERVER_IP}"
  DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"

  [[ -n "${DEFAULT_IFACE}" ]] || fail "could not detect default network interface"
}

install_packages() {
  log "installing Ubuntu packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  local packages=(
    ca-certificates
    curl
    iptables
    jq
    libqrencode4
    openssl
    python3
    python3-venv
    qrencode
    ripgrep
    unzip
    uuid-runtime
  )

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    packages+=(wireguard wireguard-tools)
  fi

  apt-get install -y "${packages[@]}"
}

ensure_certbot() {
  if command -v certbot >/dev/null 2>&1 && certbot --help all 2>/dev/null | rg -q -- '--ip-address'; then
    return
  fi

  log "installing latest certbot with IP certificate support"
  python3 -m venv "${CERTBOT_VENV}"
  "${CERTBOT_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${CERTBOT_VENV}/bin/pip" install --upgrade certbot
  ln -sf "${CERTBOT_VENV}/bin/certbot" /usr/local/bin/certbot

  certbot --help all 2>/dev/null | rg -q -- '--ip-address' || fail "certbot does not support --ip-address"
}

random_secret() {
  openssl rand -base64 48 | tr -d '=+/' | cut -c1-32
}

ensure_stack_dirs() {
  install -d -m 0700 "${STACK_DIR}" "${CLIENT_DIR}"
  install -d -m 0750 "${XRAY_DIR}" "${XRAY_TLS_DIR}"
}

write_secrets() {
  local existing=0
  if [[ -f "${SECRETS_FILE}" ]]; then
    existing=1
    # shellcheck disable=SC1090
    source "${SECRETS_FILE}"
  fi

  VLESS_UUID="${VLESS_UUID:-$(uuidgen)}"
  TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(random_secret)}"
  SHADOWSOCKS_PASSWORD="${SHADOWSOCKS_PASSWORD:-$(random_secret)}"
  SHADOWSOCKS_METHOD="${SHADOWSOCKS_METHOD:-chacha20-ietf-poly1305}"

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    WG_SERVER_PRIVATE_KEY="${WG_SERVER_PRIVATE_KEY:-$(wg genkey)}"
    WG_SERVER_PUBLIC_KEY="${WG_SERVER_PUBLIC_KEY:-$(printf '%s' "${WG_SERVER_PRIVATE_KEY}" | wg pubkey)}"
    WG_CLIENT_PRIVATE_KEY="${WG_CLIENT_PRIVATE_KEY:-$(wg genkey)}"
    WG_CLIENT_PUBLIC_KEY="${WG_CLIENT_PUBLIC_KEY:-$(printf '%s' "${WG_CLIENT_PRIVATE_KEY}" | wg pubkey)}"
    WG_PRESHARED_KEY="${WG_PRESHARED_KEY:-$(wg genpsk)}"
  fi

  cat > "${SECRETS_FILE}" <<EOF
SERVER_IP='${SERVER_IP}'
XRAY_SNI='${XRAY_SNI}'
VLESS_UUID='${VLESS_UUID}'
TROJAN_PASSWORD='${TROJAN_PASSWORD}'
SHADOWSOCKS_PASSWORD='${SHADOWSOCKS_PASSWORD}'
SHADOWSOCKS_METHOD='${SHADOWSOCKS_METHOD}'
VLESS_PORT='${VLESS_PORT}'
TROJAN_PORT='${TROJAN_PORT}'
SS_PORT='${SS_PORT}'
WG_PORT='${WG_PORT}'
WG_NETWORK_CIDR='${WG_NETWORK_CIDR}'
WG_SERVER_ADDRESS='${WG_SERVER_ADDRESS}'
WG_CLIENT_ADDRESS='${WG_CLIENT_ADDRESS}'
CLIENT_NAME='${CLIENT_NAME}'
ENABLE_WIREGUARD='${ENABLE_WIREGUARD}'
EOF

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    cat >> "${SECRETS_FILE}" <<EOF
WG_SERVER_PRIVATE_KEY='${WG_SERVER_PRIVATE_KEY}'
WG_SERVER_PUBLIC_KEY='${WG_SERVER_PUBLIC_KEY}'
WG_CLIENT_PRIVATE_KEY='${WG_CLIENT_PRIVATE_KEY}'
WG_CLIENT_PUBLIC_KEY='${WG_CLIENT_PUBLIC_KEY}'
WG_PRESHARED_KEY='${WG_PRESHARED_KEY}'
EOF
  fi

  chmod 0600 "${SECRETS_FILE}"
  log "stored generated secrets in ${SECRETS_FILE}"

  if [[ "${existing}" -eq 0 ]]; then
    install -m 0600 "${SECRETS_FILE}" "${CLIENT_DIR}/server-secrets.backup.env"
  fi
}

detect_xray_asset() {
  case "$(uname -m)" in
    x86_64)
      printf '64'
      ;;
    aarch64|arm64)
      printf 'arm64-v8a'
      ;;
    armv7l)
      printf 'arm32-v7a'
      ;;
    *)
      fail "unsupported architecture: $(uname -m)"
      ;;
  esac
}

install_xray() {
  local latest asset tmpdir release_url
  latest="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')"
  [[ -n "${latest}" && "${latest}" != "null" ]] || fail "could not determine latest Xray release"

  asset="$(detect_xray_asset)"
  release_url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${asset}.zip"
  tmpdir="$(mktemp -d)"

  log "installing Xray ${latest}"
  curl -fsSL -o "${tmpdir}/xray.zip" "${release_url}"
  unzip -oq "${tmpdir}/xray.zip" -d "${tmpdir}/xray"

  getent group xray >/dev/null 2>&1 || groupadd --system xray
  id -u xray >/dev/null 2>&1 || useradd --system --gid xray --home-dir /var/lib/xray --shell /usr/sbin/nologin xray

  install -d -m 0755 /usr/local/share/xray /var/log/xray
  install -m 0755 "${tmpdir}/xray/xray" /usr/local/bin/xray

  if [[ -f "${tmpdir}/xray/geoip.dat" ]]; then
    install -m 0644 "${tmpdir}/xray/geoip.dat" /usr/local/share/xray/geoip.dat
  fi
  if [[ -f "${tmpdir}/xray/geosite.dat" ]]; then
    install -m 0644 "${tmpdir}/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  fi

  chown -R xray:xray /var/log/xray "${XRAY_DIR}"

  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

configure_forwarding() {
  cat > /etc/sysctl.d/99-vpn-forwarding.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null
}

configure_optional_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi

  if ! ufw status | rg -q '^Status: active'; then
    return
  fi

  ufw allow 80/tcp >/dev/null
  ufw allow "${TROJAN_PORT}/tcp" >/dev/null
  ufw allow "${VLESS_PORT}/tcp" >/dev/null
  ufw allow "${SS_PORT}/tcp" >/dev/null
  ufw allow "${SS_PORT}/udp" >/dev/null

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    ufw allow "${WG_PORT}/udp" >/dev/null
  fi
}

write_cert_deploy_hook() {
  cat > /usr/local/bin/vpn-cert-deploy-hook.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

install -d -m 0750 -o xray -g xray /etc/xray/tls
install -m 0600 -o xray -g xray "${RENEWED_LINEAGE}/fullchain.pem" /etc/xray/tls/fullchain.pem
install -m 0600 -o xray -g xray "${RENEWED_LINEAGE}/privkey.pem" /etc/xray/tls/privkey.pem
cat "${RENEWED_LINEAGE}/privkey.pem" "${RENEWED_LINEAGE}/fullchain.pem" > /etc/xray/tls/server-combined.pem
chown xray:xray /etc/xray/tls/server-combined.pem
chmod 0600 /etc/xray/tls/server-combined.pem

install -d -m 0700 /root/vpn-clients/public
install -m 0644 "${RENEWED_LINEAGE}/fullchain.pem" /root/vpn-clients/public/fullchain.pem

if systemctl is-enabled xray.service >/dev/null 2>&1; then
  systemctl restart xray.service
fi
EOF
  chmod 0755 /usr/local/bin/vpn-cert-deploy-hook.sh
}

issue_ip_certificate() {
  local needs_issue=1
  local email_args=()
  local extra_args=()

  write_cert_deploy_hook

  if [[ -f "${CERT_DIR}/fullchain.pem" ]] && openssl x509 -checkend 86400 -noout -in "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1; then
    needs_issue=0
  fi

  if [[ -n "${ACME_EMAIL}" ]]; then
    email_args=(--email "${ACME_EMAIL}")
  else
    email_args=(--register-unsafely-without-email)
  fi

  if [[ "${ACME_STAGING}" == "true" ]]; then
    extra_args+=(--staging)
  fi

  if [[ "${needs_issue}" -eq 1 ]]; then
    log "requesting a Let's Encrypt certificate for IP ${SERVER_IP}"
    certbot certonly \
      --non-interactive \
      --agree-tos \
      --standalone \
      --preferred-challenges http \
      --http-01-port 80 \
      --key-type ecdsa \
      --elliptic-curve secp256r1 \
      --preferred-profile "${LE_PROFILE}" \
      --cert-name "${SERVER_IP}" \
      --ip-address "${SERVER_IP}" \
      --deploy-hook /usr/local/bin/vpn-cert-deploy-hook.sh \
      "${email_args[@]}" \
      "${extra_args[@]}"
  else
    log "existing IP certificate is still valid for more than 24h"
    RENEWED_LINEAGE="${CERT_DIR}" /usr/local/bin/vpn-cert-deploy-hook.sh
  fi

  cat > /etc/systemd/system/vpn-cert-renew.service <<'EOF'
[Unit]
Description=Renew short-lived IP certificate for VPN stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/certbot renew --quiet --deploy-hook /usr/local/bin/vpn-cert-deploy-hook.sh
EOF

  cat > /etc/systemd/system/vpn-cert-renew.timer <<'EOF'
[Unit]
Description=Twice-daily renewal for short-lived IP certificate

[Timer]
OnBootSec=10m
OnUnitActiveSec=12h
Unit=vpn-cert-renew.service

[Install]
WantedBy=timers.target
EOF
}

write_xray_config() {
  cat > "${XRAY_DIR}/config.json" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tls",
      "port": ${VLESS_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "email": "${CLIENT_NAME}-vless"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/xray/tls/fullchain.pem",
              "keyFile": "/etc/xray/tls/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "tag": "trojan-tls",
      "port": ${TROJAN_PORT},
      "listen": "0.0.0.0",
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${TROJAN_PASSWORD}",
            "email": "${CLIENT_NAME}-trojan"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/xray/tls/fullchain.pem",
              "keyFile": "/etc/xray/tls/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "tag": "shadowsocks",
      "port": ${SS_PORT},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "${SHADOWSOCKS_METHOD}",
        "password": "${SHADOWSOCKS_PASSWORD}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

  chown root:xray "${XRAY_DIR}/config.json"
  chmod 0640 "${XRAY_DIR}/config.json"
}

write_wireguard_config() {
  local wg_network_prefix
  wg_network_prefix="$(printf '%s' "${WG_NETWORK_CIDR}" | cut -d/ -f1-2)"

  install -d -m 0700 /etc/wireguard
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${WG_SERVER_PRIVATE_KEY}
SaveConfig = false
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${wg_network_prefix} -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${wg_network_prefix} -o ${DEFAULT_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${WG_CLIENT_PUBLIC_KEY}
PresharedKey = ${WG_PRESHARED_KEY}
AllowedIPs = ${WG_CLIENT_ADDRESS}
EOF
  chmod 0600 /etc/wireguard/wg0.conf
}

urlencode() {
  python3 - <<'PY' "$1"
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

render_shadowrocket_rules() {
  cat > "${CLIENT_DIR}/shadowrocket-ru-direct.conf" <<'EOF'
[General]
bypass-system = true
skip-proxy = 127.0.0.0/8, localhost, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, *.local
dns-server = 1.1.1.1, 8.8.8.8
fallback-dns-server = system
ipv6 = false

[Rule]
IP-CIDR,127.0.0.0/8,DIRECT
IP-CIDR,10.0.0.0/8,DIRECT
IP-CIDR,172.16.0.0/12,DIRECT
IP-CIDR,192.168.0.0/16,DIRECT
DOMAIN-SUFFIX,ru,DIRECT
DOMAIN-SUFFIX,su,DIRECT
DOMAIN-SUFFIX,xn--p1ai,DIRECT
DOMAIN-KEYWORD,yandex,DIRECT
DOMAIN-KEYWORD,sberbank,DIRECT
DOMAIN-KEYWORD,gosuslugi,DIRECT
GEOIP,RU,DIRECT
FINAL,PROXY
EOF
}

render_client_artifacts() {
  local label_vless label_trojan label_ss ss_userinfo vless_uri trojan_uri ss_uri

  label_vless="$(urlencode "VPN Xray VLESS ${SERVER_IP}")"
  label_trojan="$(urlencode "VPN Trojan ${SERVER_IP}")"
  label_ss="$(urlencode "VPN Shadowsocks ${SERVER_IP}")"

  vless_uri="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=tls&sni=${XRAY_SNI}&type=tcp#${label_vless}"
  trojan_uri="trojan://${TROJAN_PASSWORD}@${SERVER_IP}:${TROJAN_PORT}?security=tls&sni=${XRAY_SNI}&type=tcp#${label_trojan}"
  ss_userinfo="$(printf '%s' "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}" | base64 -w 0)"
  ss_uri="ss://${ss_userinfo}@${SERVER_IP}:${SS_PORT}#${label_ss}"

  printf '%s\n' "${vless_uri}" > "${CLIENT_DIR}/vless.uri"
  printf '%s\n' "${trojan_uri}" > "${CLIENT_DIR}/trojan.uri"
  printf '%s\n' "${ss_uri}" > "${CLIENT_DIR}/shadowsocks.uri"
  printf '%s\n%s\n%s\n' "${vless_uri}" "${trojan_uri}" "${ss_uri}" > "${CLIENT_DIR}/shadowrocket-links.txt"
  printf '%s\n%s\n%s\n' "${vless_uri}" "${trojan_uri}" "${ss_uri}" | base64 -w 0 > "${CLIENT_DIR}/shadowrocket-subscription.base64.txt"

  qrencode -o "${CLIENT_DIR}/vless.png" "${vless_uri}"
  qrencode -o "${CLIENT_DIR}/trojan.png" "${trojan_uri}"
  qrencode -o "${CLIENT_DIR}/shadowsocks.png" "${ss_uri}"

  render_shadowrocket_rules

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    cat > "${CLIENT_DIR}/wireguard-client.conf" <<EOF
[Interface]
PrivateKey = ${WG_CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_ADDRESS}
DNS = ${WG_DNS}

[Peer]
PublicKey = ${WG_SERVER_PUBLIC_KEY}
PresharedKey = ${WG_PRESHARED_KEY}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    chmod 0600 "${CLIENT_DIR}/wireguard-client.conf"
  fi

  cat > "${CLIENT_DIR}/README.txt" <<EOF
Client files created by install_vpn_stack.sh

Files for Shadowrocket:
- shadowrocket-links.txt               one URI per line
- shadowrocket-subscription.base64.txt base64 payload if you want to host your own subscription URL
- vless.png / trojan.png / shadowsocks.png
- shadowrocket-ru-direct.conf          route RU traffic directly while VPN/proxy is enabled

Files for WireGuard:
- wireguard-client.conf

Server-only TLS bundle:
- /etc/xray/tls/server-combined.pem

Recommended import path in Shadowrocket:
1. Scan trojan.png or vless.png and add the node.
2. Import shadowrocket-ru-direct.conf via "Import from File".
3. Enable the imported config so RU destinations go DIRECT and the rest use PROXY.
EOF
}

enable_services() {
  systemctl daemon-reload
  systemctl enable --now vpn-cert-renew.timer
  systemctl enable --now xray.service

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    systemctl enable --now wg-quick@wg0.service
  fi
}

print_summary() {
  log "installation complete"
  printf '\n'
  printf 'Server IP: %s\n' "${SERVER_IP}"
  printf 'VLESS:      %s\n' "${CLIENT_DIR}/vless.uri"
  printf 'Trojan:     %s\n' "${CLIENT_DIR}/trojan.uri"
  printf 'Shadowsocks:%s\n' "${CLIENT_DIR}/shadowsocks.uri"
  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    printf 'WireGuard:  %s\n' "${CLIENT_DIR}/wireguard-client.conf"
  fi
  printf 'Rules:      %s\n' "${CLIENT_DIR}/shadowrocket-ru-direct.conf"
  printf 'Secrets:    %s\n' "${SECRETS_FILE}"
  printf 'TLS bundle: %s\n' "/etc/xray/tls/server-combined.pem"
}

main() {
  require_root
  load_config
  install_packages
  ensure_stack_dirs
  write_secrets
  install_xray
  configure_forwarding
  configure_optional_firewall
  ensure_certbot
  issue_ip_certificate
  write_xray_config

  if [[ "${ENABLE_WIREGUARD}" == "true" ]]; then
    write_wireguard_config
  fi

  render_client_artifacts
  enable_services
  print_summary
}

main "$@"
