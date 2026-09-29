#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# Ramtin Xray Generator - Final
# Server: Debian/Ubuntu amd64/arm64
# Purpose: Generate Xray server + Mihomo/Clash client configs.
#
# Important:
# - Xray is pinned to 26.6.27 by default because current Mihomo
#   documentation warns about REALITY incompatibility with
#   xray-core 26.7.11+.
# - Hysteria/Hysteria2/TUIC/WireGuard are intentionally not
#   enabled by default because they rely on UDP/QUIC, which the
#   target network may heavily restrict.
# - REALITY target is tested from the server. Override
#   REALITY_TARGET/REALITY_SNI if you have a known-good target.
# ============================================================

readonly SCRIPT_VERSION="3.0.0"
readonly XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"
readonly BASE_DIR="/usr/local/ramtin-xray"
readonly CONFIG_FILE="${BASE_DIR}/config.json"
readonly SECRETS_FILE="${BASE_DIR}/secrets.env"
readonly CLASH_FILE="/root/ramtin-clash.yaml"
readonly URI_FILE="/root/ramtin-xray-uris.txt"
readonly INFO_FILE="/root/ramtin-xray-info.txt"
readonly BACKUP_ROOT="/root/ramtin-xray-backups"
readonly SERVICE_FILE="/etc/systemd/system/ramtin-xray.service"
readonly LOG_DIR="/var/log/ramtin-xray"

# Ports. Override with environment variables before running if needed.
readonly REALITY_PORT1="${REALITY_PORT1:-443}"
readonly REALITY_PORT2="${REALITY_PORT2:-8448}"
readonly REALITY_PORT3="${REALITY_PORT3:-8449}"

readonly XHTTP_PORT1="${XHTTP_PORT1:-8450}"
readonly XHTTP_PORT2="${XHTTP_PORT2:-8451}"
readonly XHTTP_PORT3="${XHTTP_PORT3:-8452}"

readonly WS_PORT1="${WS_PORT1:-8080}"
readonly WS_PORT2="${WS_PORT2:-8081}"
readonly VMESS_PORT1="${VMESS_PORT1:-8082}"
readonly VMESS_PORT2="${VMESS_PORT2:-8083}"
readonly SS_PORT1="${SS_PORT1:-2096}"
readonly SS_PORT2="${SS_PORT2:-2095}"
readonly SS_PORT3="${SS_PORT3:-8447}"
readonly GRPC_PORT="${GRPC_PORT:-8446}"

# REALITY target candidates. You may override with:
# REALITY_TARGET=example.com:443 REALITY_SNI=example.com ./script.sh
REALITY_TARGET="${REALITY_TARGET:-}"
REALITY_SNI="${REALITY_SNI:-}"

readonly CANDIDATE_TARGETS=(
  "www.microsoft.com:443"
  "www.apple.com:443"
  "www.yahoo.com:443"
  "www.samsung.com:443"
  "www.mozilla.org:443"
)

# --------------------------- UI ------------------------------

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
BOLD=$'\033[1m'
NC=$'\033[0m'

log()  { printf '%b\n' "${GREEN}[+]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[!]${NC} $*" >&2; }
die()  { printf '%b\n' "${RED}[X]${NC} $*" >&2; exit 1; }
info() { printf '%b\n' "${CYAN}[*]${NC} $*"; }

cleanup_tmp() {
    [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup_tmp EXIT

on_error() {
    local rc=$?
    printf '%b\n' "${RED}[X] Failed at line ${BASH_LINENO[0]} (exit ${rc}).${NC}" >&2
    exit "$rc"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "Supported OS: Ubuntu/Debian. Detected: ${ID:-unknown}" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) XRAY_MACHINE="64" ;;
        aarch64|arm64) XRAY_MACHINE="arm64-v8a" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates curl unzip jq openssl uuid-runtime \
        iproute2 net-tools lsof psmisc \
        ufw procps mawk
}

detect_server_ip() {
    SERVER_IP="${SERVER_IP:-}"
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
            for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}
        }')"
    fi
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "Could not determine an IPv4 server address. Set SERVER_IP=x.x.x.x"
}

port_is_in_use() {
    local p="$1"
    ss -ltnH "sport = :${p}" 2>/dev/null | grep -q .
}

check_ports() {
    local ports=(
      "$REALITY_PORT1" "$REALITY_PORT2" "$REALITY_PORT3"
      "$XHTTP_PORT1" "$XHTTP_PORT2" "$XHTTP_PORT3"
      "$WS_PORT1" "$WS_PORT2"
      "$VMESS_PORT1" "$VMESS_PORT2"
      "$SS_PORT1" "$SS_PORT2" "$SS_PORT3"
      "$GRPC_PORT"
    )
    local seen=" "
    local p
    for p in "${ports[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid port: $p"
        (( p >= 1 && p <= 65535 )) || die "Invalid port: $p"
        [[ "$seen" != *" $p "* ]] || die "Duplicate port: $p"
        seen+=" $p "
        if port_is_in_use "$p"; then
            die "Port $p is already in use. No existing service will be killed automatically."
        fi
    done
}

backup_existing() {
    mkdir -p "$BACKUP_ROOT"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local dir="${BACKUP_ROOT}/${stamp}"
    mkdir -p "$dir"

    for f in "$CONFIG_FILE" "$SECRETS_FILE" "$SERVICE_FILE" "$CLASH_FILE" "$URI_FILE" "$INFO_FILE"; do
        [[ -e "$f" ]] && cp -a -- "$f" "$dir/"
    done

    [[ -d "$BASE_DIR" ]] && tar -C "$(dirname "$BASE_DIR")" -czf "${dir}/ramtin-xray-dir.tar.gz" "$(basename "$BASE_DIR")" 2>/dev/null || true
    log "Backup created: $dir"
}

install_xray() {
    local installer="${TMP_DIR}/install-release.sh"
    mkdir -p "$TMP_DIR"

    curl -fsSL --retry 5 \
      "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
      -o "$installer"

    chmod 700 "$installer"

    # Official Xray installer verifies the downloaded archive against
    # the release digest. We deliberately pin the version for Mihomo
    # REALITY compatibility.
    bash "$installer" install --version "$XRAY_VERSION" --without-geodata --no-update-service

    [[ -x /usr/local/bin/xray ]] || die "Xray installation failed."
    log "Installed Xray: $(/usr/local/bin/xray version | sed -n '1p')"
}

generate_credentials() {
    UUID_REALITY1="$(uuidgen)"
    UUID_REALITY2="$(uuidgen)"
    UUID_REALITY3="$(uuidgen)"

    UUID_XHTTP1="$(uuidgen)"
    UUID_XHTTP2="$(uuidgen)"
    UUID_XHTTP3="$(uuidgen)"

    UUID_WS1="$(uuidgen)"
    UUID_WS2="$(uuidgen)"
    UUID_VMESS1="$(uuidgen)"
    UUID_VMESS2="$(uuidgen)"

    PASS_SS1="$(openssl rand -hex 24)"
    PASS_SS2="$(openssl rand -hex 24)"
    PASS_SS3="$(openssl rand -hex 24)"

    # Xray changed the x25519 CLI output format in 2025.
    # Older releases: Private key / Public key
    # Newer releases: PrivateKey / Password (Password == REALITY public key) / Hash32
    local keyout derived
    keyout="$(/usr/local/bin/xray x25519 2>&1)"

    REALITY_PRIVATE_KEY="$(printf '%s\n' "$keyout" | awk -F': ' '/^(Private key|PrivateKey):/{print $2; exit}')"

    if [[ -n "$REALITY_PRIVATE_KEY" ]]; then
        # Derive the client public key from the server private key. This is
        # compatible with both the old and new x25519 CLI formats.
        derived="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE_KEY" 2>&1)"
        REALITY_PUBLIC_KEY="$(printf '%s\n' "$derived" | awk -F': ' '/^(Public key|Password([[:space:]]*\(PublicKey\))?):/{print $2; exit}')"
    else
        REALITY_PUBLIC_KEY="$(printf '%s\n' "$keyout" | awk -F': ' '/^(Public key|Password([[:space:]]*\(PublicKey\))?):/{print $2; exit}')"
    fi

    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] ||
        die "Could not generate X25519 REALITY keypair."

    REALITY_SHORT1="$(openssl rand -hex 4)"
    REALITY_SHORT2="$(openssl rand -hex 4)"
    REALITY_SHORT3="$(openssl rand -hex 4)"

    # XHTTP/Reality uses distinct paths; each client gets its own UUID.
    XHTTP_PATH1="/assets/${UUID_XHTTP1:0:12}"
    XHTTP_PATH2="/cdn/${UUID_XHTTP2:0:12}"
    XHTTP_PATH3="/api/${UUID_XHTTP3:0:12}"

    WS_PATH1="/${UUID_WS1}/ws1"
    WS_PATH2="/${UUID_WS2}/ws2"

    GRPC_SERVICE="grpc-${UUID_REALITY1:0:8}"
}

select_reality_targets() {
    if [[ -n "$REALITY_TARGET" ]]; then
        REALITY_TARGETS=("$REALITY_TARGET" "$REALITY_TARGET" "$REALITY_TARGET")
        REALITY_SNI1="${REALITY_SNI:-${REALITY_TARGET%%:*}}"
        REALITY_SNI2="$REALITY_SNI1"
        REALITY_SNI3="$REALITY_SNI1"
        REALITY_TARGET1="${REALITY_TARGETS[0]}"
        REALITY_TARGET2="${REALITY_TARGETS[1]}"
        REALITY_TARGET3="${REALITY_TARGETS[2]}"
        log "Using user-specified REALITY target for all primary profiles: ${REALITY_TARGET}"
        return
    fi

    REALITY_TARGETS=()
    local target host
    for target in "${CANDIDATE_TARGETS[@]}"; do
        host="${target%:*}"
        info "Testing REALITY target: $target"
        if timeout 8 /usr/local/bin/xray tls ping "$host" >/dev/null 2>&1; then
            REALITY_TARGETS+=("$target")
            ((${#REALITY_TARGETS[@]} >= 3)) && break
        fi
    done

    # We need three independently testable targets for diversification.
    # If fewer than three pass, reuse the first successful target rather than
    # inventing a target that was not tested.
    if ((${#REALITY_TARGETS[@]} == 0)); then
        warn "Automatic REALITY target testing failed for all candidates."
        REALITY_TARGETS=("${CANDIDATE_TARGETS[0]}")
    fi
    while ((${#REALITY_TARGETS[@]} < 3)); do
        REALITY_TARGETS+=("${REALITY_TARGETS[0]}")
    done

    REALITY_TARGET1="${REALITY_TARGETS[0]}"
    REALITY_TARGET2="${REALITY_TARGETS[1]}"
    REALITY_TARGET3="${REALITY_TARGETS[2]}"

    REALITY_SNI1="${REALITY_TARGET1%%:*}"
    REALITY_SNI2="${REALITY_TARGET2%%:*}"
    REALITY_SNI3="${REALITY_TARGET3%%:*}"

    log "REALITY target #1: ${REALITY_TARGET1}"
    log "REALITY target #2: ${REALITY_TARGET2}"
    log "REALITY target #3: ${REALITY_TARGET3}"
}
write_secrets() {
    mkdir -p "$BASE_DIR"
    umask 077
    cat > "$SECRETS_FILE" <<EOF
SERVER_IP=${SERVER_IP}
XRAY_VERSION=${XRAY_VERSION}
REALITY_TARGET1=${REALITY_TARGET1}
REALITY_TARGET2=${REALITY_TARGET2}
REALITY_TARGET3=${REALITY_TARGET3}
REALITY_SNI1=${REALITY_SNI1}
REALITY_SNI2=${REALITY_SNI2}
REALITY_SNI3=${REALITY_SNI3}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT1=${REALITY_SHORT1}
REALITY_SHORT2=${REALITY_SHORT2}
REALITY_SHORT3=${REALITY_SHORT3}
UUID_REALITY1=${UUID_REALITY1}
UUID_REALITY2=${UUID_REALITY2}
UUID_REALITY3=${UUID_REALITY3}
UUID_XHTTP1=${UUID_XHTTP1}
UUID_XHTTP2=${UUID_XHTTP2}
UUID_XHTTP3=${UUID_XHTTP3}
UUID_WS1=${UUID_WS1}
UUID_WS2=${UUID_WS2}
UUID_VMESS1=${UUID_VMESS1}
UUID_VMESS2=${UUID_VMESS2}
PASS_SS1=${PASS_SS1}
PASS_SS2=${PASS_SS2}
PASS_SS3=${PASS_SS3}
XHTTP_PATH1=${XHTTP_PATH1}
XHTTP_PATH2=${XHTTP_PATH2}
XHTTP_PATH3=${XHTTP_PATH3}
WS_PATH1=${WS_PATH1}
WS_PATH2=${WS_PATH2}
GRPC_SERVICE=${GRPC_SERVICE}
EOF
    chmod 600 "$SECRETS_FILE"
}

write_xray_config() {
    mkdir -p "$BASE_DIR" "$LOG_DIR"
    chmod 750 "$BASE_DIR"
    chmod 750 "$LOG_DIR"

    cat > "${CONFIG_FILE}.new" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5
      }
    }
  },
  "inbounds": [
    {
      "tag": "reality1",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT1},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID_REALITY1}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET1}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI1}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT1}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "reality2",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT2},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID_REALITY2}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET2}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI2}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT2}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "reality3",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT3},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID_REALITY3}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET3}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI3}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT3}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },

    {
      "tag": "xhttp1",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT1},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID_XHTTP1}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH1}",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET1}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI1}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT1}"]
        }
      }
    },
    {
      "tag": "xhttp2",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT2},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID_XHTTP2}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH2}",
          "mode": "stream-up"
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET2}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI2}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT2}"]
        }
      }
    },
    {
      "tag": "xhttp3",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT3},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID_XHTTP3}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH3}",
          "mode": "packet-up"
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET3}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI3}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT3}"]
        }
      }
    },

    {
      "tag": "ws1",
      "listen": "0.0.0.0",
      "port": ${WS_PORT1},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID_WS1}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${WS_PATH1}"}
      }
    },
    {
      "tag": "ws2",
      "listen": "0.0.0.0",
      "port": ${WS_PORT2},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID_WS2}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${WS_PATH2}"}
      }
    },

    {
      "tag": "vmess1",
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT1},
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${UUID_VMESS1}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/${UUID_VMESS1}/vmess1"}
      }
    },
    {
      "tag": "vmess2",
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT2},
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${UUID_VMESS2}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/${UUID_VMESS2}/vmess2"}
      }
    },


    {
      "tag": "ss1",
      "listen": "0.0.0.0",
      "port": ${SS_PORT1},
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "${PASS_SS1}",
        "network": "tcp"
      }
    },
    {
      "tag": "ss2",
      "listen": "0.0.0.0",
      "port": ${SS_PORT2},
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "${PASS_SS2}",
        "network": "tcp"
      }
    },
    {
      "tag": "ss3",
      "listen": "0.0.0.0",
      "port": ${SS_PORT3},
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-256-gcm",
        "password": "${PASS_SS3}",
        "network": "tcp"
      }
    },


    {
      "tag": "grpc",
      "listen": "0.0.0.0",
      "port": ${GRPC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID_REALITY1}", "flow": "xtls-rprx-vision"},
          {"id": "${UUID_REALITY2}", "flow": "xtls-rprx-vision"},
          {"id": "${UUID_REALITY3}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "grpcSettings": {"serviceName": "${GRPC_SERVICE}"},
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET3}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI1}", "${REALITY_SNI2}", "${REALITY_SNI3}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT1}", "${REALITY_SHORT2}", "${REALITY_SHORT3}"]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "127.0.0.0/8",
          "169.254.0.0/16"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    # Atomic replacement only after file has been completely written.
    mv -f "${CONFIG_FILE}.new" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

validate_xray_config() {
    info "Validating Xray configuration..."
    /usr/local/bin/xray run -test -config "$CONFIG_FILE"
    log "Xray configuration is valid."
}

write_systemd() {
    cat > "${SERVICE_FILE}.new" <<EOF
[Unit]
Description=Ramtin Xray Proxy Server
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${LOG_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    mv -f "${SERVICE_FILE}.new" "$SERVICE_FILE"
    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable ramtin-xray.service >/dev/null
    systemctl restart ramtin-xray.service
    sleep 2

    systemctl is-active --quiet ramtin-xray.service ||
        die "Xray service failed. See: journalctl -u ramtin-xray -n 100 --no-pager"

    log "Xray service is active."
}

configure_firewall() {
    local ports=(
      "$REALITY_PORT1" "$REALITY_PORT2" "$REALITY_PORT3"
      "$XHTTP_PORT1" "$XHTTP_PORT2" "$XHTTP_PORT3"
      "$WS_PORT1" "$WS_PORT2"
      "$VMESS_PORT1" "$VMESS_PORT2"
      "$SS_PORT1" "$SS_PORT2" "$SS_PORT3"
      "$GRPC_PORT"
    )

    # UFW is only changed if it is already active or the user explicitly
    # requests it with ENABLE_UFW=1.
    if command -v ufw >/dev/null 2>&1; then
        if [[ "${ENABLE_UFW:-0}" == "1" ]]; then
            ufw allow OpenSSH >/dev/null 2>&1 || true
            local p
            for p in "${ports[@]}"; do
                ufw allow "${p}/tcp" >/dev/null
            done
            ufw --force enable >/dev/null
            log "UFW enabled and all Xray TCP ports allowed."
        elif ufw status 2>/dev/null | grep -q "^Status: active"; then
            local p
            for p in "${ports[@]}"; do
                ufw allow "${p}/tcp" >/dev/null
            done
            log "Existing active UFW detected; Xray TCP ports allowed."
        else
            info "UFW is inactive; firewall policy was not changed."
        fi
    fi
}

urlencode() {
    jq -nr --arg v "$1" '$v|@uri'
}

base64_noline() {
    base64 -w 0
}

make_vmess_uri() {
    local json="$1"
    printf 'vmess://%s' "$(printf '%s' "$json" | base64_noline)"
}

write_uri_file() {
    local vless_reality1 vless_reality2 vless_reality3
    local vless_xhttp1 vless_xhttp2 vless_xhttp3
    local vless_grpc1 vless_grpc2 vless_grpc3
    local vless_ws1 vless_ws2
    local vmess1 vmess2 ss1 ss2 ss3

    vless_reality1="vless://${UUID_REALITY1}@${SERVER_IP}:${REALITY_PORT1}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI1")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT1}&type=tcp#Ramtin-REALITY-1"
    vless_reality2="vless://${UUID_REALITY2}@${SERVER_IP}:${REALITY_PORT2}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI2")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT2}&type=tcp#Ramtin-REALITY-2"
    vless_reality3="vless://${UUID_REALITY3}@${SERVER_IP}:${REALITY_PORT3}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI3")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT3}&type=tcp#Ramtin-REALITY-3"

    vless_xhttp1="vless://${UUID_XHTTP1}@${SERVER_IP}:${XHTTP_PORT1}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI1")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT1}&type=xhttp&path=$(urlencode "$XHTTP_PATH1")#Ramtin-XHTTP-1"
    vless_xhttp2="vless://${UUID_XHTTP2}@${SERVER_IP}:${XHTTP_PORT2}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI2")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT2}&type=xhttp&path=$(urlencode "$XHTTP_PATH2")#Ramtin-XHTTP-2"
    vless_xhttp3="vless://${UUID_XHTTP3}@${SERVER_IP}:${XHTTP_PORT3}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI3")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT3}&type=xhttp&path=$(urlencode "$XHTTP_PATH3")#Ramtin-XHTTP-3"

    vless_grpc1="vless://${UUID_REALITY1}@${SERVER_IP}:${GRPC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI1")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT1}&type=grpc&serviceName=$(urlencode "$GRPC_SERVICE")#Ramtin-gRPC-Reality"
    vless_grpc2="vless://${UUID_REALITY2}@${SERVER_IP}:${GRPC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI2")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT2}&type=grpc&serviceName=$(urlencode "$GRPC_SERVICE")#Ramtin-gRPC-Reality-2"
    vless_grpc3="vless://${UUID_REALITY3}@${SERVER_IP}:${GRPC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlencode "$REALITY_SNI3")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT3}&type=grpc&serviceName=$(urlencode "$GRPC_SERVICE")#Ramtin-gRPC-Reality-3"

    vless_ws1="vless://${UUID_WS1}@${SERVER_IP}:${WS_PORT1}?encryption=none&security=none&type=ws&host=$(urlencode "$SERVER_IP")&path=$(urlencode "$WS_PATH1")#Ramtin-VLESS-WS-1"
    vless_ws2="vless://${UUID_WS2}@${SERVER_IP}:${WS_PORT2}?encryption=none&security=none&type=ws&host=$(urlencode "$SERVER_IP")&path=$(urlencode "$WS_PATH2")#Ramtin-VLESS-WS-2"

    vmess1="$(make_vmess_uri "{\"v\":\"2\",\"ps\":\"Ramtin-VMESS-WS-1\",\"add\":\"${SERVER_IP}\",\"port\":\"${VMESS_PORT1}\",\"id\":\"${UUID_VMESS1}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SERVER_IP}\",\"path\":\"/${UUID_VMESS1}/vmess1\",\"tls\":\"\"}")"
    vmess2="$(make_vmess_uri "{\"v\":\"2\",\"ps\":\"Ramtin-VMESS-WS-2\",\"add\":\"${SERVER_IP}\",\"port\":\"${VMESS_PORT2}\",\"id\":\"${UUID_VMESS2}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${SERVER_IP}\",\"path\":\"/${UUID_VMESS2}/vmess2\",\"tls\":\"\"}")"

    ss1="ss://$(printf 'chacha20-ietf-poly1305:%s' "$PASS_SS1" | base64_noline)@${SERVER_IP}:${SS_PORT1}#Ramtin-SS-1"
    ss2="ss://$(printf 'chacha20-ietf-poly1305:%s' "$PASS_SS2" | base64_noline)@${SERVER_IP}:${SS_PORT2}#Ramtin-SS-2"
    ss3="ss://$(printf 'aes-256-gcm:%s' "$PASS_SS3" | base64_noline)@${SERVER_IP}:${SS_PORT3}#Ramtin-SS-3"

    cat > "$URI_FILE" <<EOF
# Ramtin Xray Generator ${SCRIPT_VERSION}
# Xray ${XRAY_VERSION}
# Server: ${SERVER_IP}
#
# PRIMARY - VLESS + REALITY + Vision
${vless_reality1}
${vless_reality2}
${vless_reality3}
#
# XHTTP + REALITY
${vless_xhttp1}
${vless_xhttp2}
${vless_xhttp3}
#
# gRPC + REALITY (same port, alternative SNI/credentials)
${vless_grpc1}
${vless_grpc2}
${vless_grpc3}
#
# LEGACY / FALLBACK
${vless_ws1}
${vless_ws2}
${vmess1}
${vmess2}
${ss1}
${ss2}
${ss3}
EOF
    chmod 600 "$URI_FILE"
}
write_clash_config() {
    cat > "${CLASH_FILE}.new" <<EOF
# Ramtin Xray Generator ${SCRIPT_VERSION}
# Mihomo / Clash Meta configuration
# Generated: $(date -Is)
#
# Server Xray: ${XRAY_VERSION}
# REALITY targets:
#   1) ${REALITY_TARGET1}
#   2) ${REALITY_TARGET2}
#   3) ${REALITY_TARGET3}
#
# Primary paths use TCP. UDP proxying is disabled intentionally.

mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: redir-host
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

proxies:

  # ========================= REALITY / TCP =========================

  - name: "Ramtin-REALITY-1"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT1}
    uuid: ${UUID_REALITY1}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: tcp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT1}
    servername: ${REALITY_SNI1}
    client-fingerprint: chrome
    skip-cert-verify: true

  - name: "Ramtin-REALITY-2"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT2}
    uuid: ${UUID_REALITY2}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: tcp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT2}
    servername: ${REALITY_SNI2}
    client-fingerprint: chrome
    skip-cert-verify: true

  - name: "Ramtin-REALITY-3"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT3}
    uuid: ${UUID_REALITY3}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: tcp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT3}
    servername: ${REALITY_SNI3}
    client-fingerprint: chrome
    skip-cert-verify: true

  # ========================= XHTTP / REALITY =========================

  - name: "Ramtin-XHTTP-1"
    type: vless
    server: ${SERVER_IP}
    port: ${XHTTP_PORT1}
    uuid: ${UUID_XHTTP1}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: xhttp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT1}
    servername: ${REALITY_SNI1}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      path: "${XHTTP_PATH1}"
      mode: auto

  - name: "Ramtin-XHTTP-2"
    type: vless
    server: ${SERVER_IP}
    port: ${XHTTP_PORT2}
    uuid: ${UUID_XHTTP2}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: xhttp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT2}
    servername: ${REALITY_SNI2}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      path: "${XHTTP_PATH2}"
      mode: stream-up

  - name: "Ramtin-XHTTP-3"
    type: vless
    server: ${SERVER_IP}
    port: ${XHTTP_PORT3}
    uuid: ${UUID_XHTTP3}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: xhttp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT3}
    servername: ${REALITY_SNI3}
    client-fingerprint: chrome
    skip-cert-verify: true
    xhttp-opts:
      path: "${XHTTP_PATH3}"
      mode: packet-up

  # ========================= gRPC / REALITY =========================

  - name: "Ramtin-gRPC-Reality-1"
    type: vless
    server: ${SERVER_IP}
    port: ${GRPC_PORT}
    uuid: ${UUID_REALITY1}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: grpc
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT1}
    servername: ${REALITY_SNI1}
    client-fingerprint: chrome
    skip-cert-verify: true
    grpc-opts:
      grpc-service-name: ${GRPC_SERVICE}

  - name: "Ramtin-gRPC-Reality-2"
    type: vless
    server: ${SERVER_IP}
    port: ${GRPC_PORT}
    uuid: ${UUID_REALITY2}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: grpc
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT2}
    servername: ${REALITY_SNI2}
    client-fingerprint: chrome
    skip-cert-verify: true
    grpc-opts:
      grpc-service-name: ${GRPC_SERVICE}

  - name: "Ramtin-gRPC-Reality-3"
    type: vless
    server: ${SERVER_IP}
    port: ${GRPC_PORT}
    uuid: ${UUID_REALITY3}
    flow: xtls-rprx-vision
    udp: false
    tls: true
    network: grpc
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT3}
    servername: ${REALITY_SNI3}
    client-fingerprint: chrome
    skip-cert-verify: true
    grpc-opts:
      grpc-service-name: ${GRPC_SERVICE}

  # ========================= LEGACY =========================

  - name: "Ramtin-VLESS-WS-1"
    type: vless
    server: ${SERVER_IP}
    port: ${WS_PORT1}
    uuid: ${UUID_WS1}
    udp: false
    tls: false
    network: ws
    ws-opts:
      path: "${WS_PATH1}"
      headers:
        Host: ${SERVER_IP}

  - name: "Ramtin-VLESS-WS-2"
    type: vless
    server: ${SERVER_IP}
    port: ${WS_PORT2}
    uuid: ${UUID_WS2}
    udp: false
    tls: false
    network: ws
    ws-opts:
      path: "${WS_PATH2}"
      headers:
        Host: ${SERVER_IP}

  - name: "Ramtin-VMESS-WS-1"
    type: vmess
    server: ${SERVER_IP}
    port: ${VMESS_PORT1}
    uuid: ${UUID_VMESS1}
    alterId: 0
    cipher: auto
    udp: false
    tls: false
    network: ws
    ws-opts:
      path: "/${UUID_VMESS1}/vmess1"
      headers:
        Host: ${SERVER_IP}

  - name: "Ramtin-VMESS-WS-2"
    type: vmess
    server: ${SERVER_IP}
    port: ${VMESS_PORT2}
    uuid: ${UUID_VMESS2}
    alterId: 0
    cipher: auto
    udp: false
    tls: false
    network: ws
    ws-opts:
      path: "/${UUID_VMESS2}/vmess2"
      headers:
        Host: ${SERVER_IP}

  - name: "Ramtin-SS-1"
    type: ss
    server: ${SERVER_IP}
    port: ${SS_PORT1}
    cipher: chacha20-ietf-poly1305
    password: "${PASS_SS1}"
    udp: false

  - name: "Ramtin-SS-2"
    type: ss
    server: ${SERVER_IP}
    port: ${SS_PORT2}
    cipher: chacha20-ietf-poly1305
    password: "${PASS_SS2}"
    udp: false

  - name: "Ramtin-SS-3"
    type: ss
    server: ${SERVER_IP}
    port: ${SS_PORT3}
    cipher: aes-256-gcm
    password: "${PASS_SS3}"
    udp: false

proxy-groups:

  - name: "Fastest"
    type: url-test
    url: "https://www.gstatic.com/generate_204"
    interval: 60
    tolerance: 80
    proxies:
      - "Ramtin-REALITY-1"
      - "Ramtin-REALITY-2"
      - "Ramtin-REALITY-3"
      - "Ramtin-XHTTP-1"
      - "Ramtin-XHTTP-2"
      - "Ramtin-XHTTP-3"
      - "Ramtin-gRPC-Reality-1"
      - "Ramtin-gRPC-Reality-2"
      - "Ramtin-gRPC-Reality-3"

  - name: "Auto"
    type: fallback
    url: "https://www.gstatic.com/generate_204"
    interval: 30
    proxies:
      - "Ramtin-REALITY-1"
      - "Ramtin-REALITY-2"
      - "Ramtin-REALITY-3"
      - "Ramtin-XHTTP-1"
      - "Ramtin-XHTTP-2"
      - "Ramtin-XHTTP-3"
      - "Ramtin-gRPC-Reality-1"
      - "Ramtin-gRPC-Reality-2"
      - "Ramtin-gRPC-Reality-3"

  - name: "Legacy"
    type: fallback
    url: "https://www.gstatic.com/generate_204"
    interval: 60
    proxies:
      - "Ramtin-VLESS-WS-1"
      - "Ramtin-VLESS-WS-2"
      - "Ramtin-VMESS-WS-1"
      - "Ramtin-VMESS-WS-2"
      - "Ramtin-SS-1"
      - "Ramtin-SS-2"
      - "Ramtin-SS-3"

  - name: "Select"
    type: select
    proxies:
      - "Fastest"
      - "Auto"
      - "Ramtin-REALITY-1"
      - "Ramtin-REALITY-2"
      - "Ramtin-REALITY-3"
      - "Ramtin-XHTTP-1"
      - "Ramtin-XHTTP-2"
      - "Ramtin-XHTTP-3"
      - "Ramtin-gRPC-Reality-1"
      - "Ramtin-gRPC-Reality-2"
      - "Ramtin-gRPC-Reality-3"
      - "Legacy"
      - DIRECT

rules:
  - GEOIP,IR,DIRECT
  - MATCH,Select
EOF

    mv -f "${CLASH_FILE}.new" "$CLASH_FILE"
    chmod 600 "$CLASH_FILE"
}
write_info() {
    local ports
    ports="$REALITY_PORT1 $REALITY_PORT2 $REALITY_PORT3 $XHTTP_PORT1 $XHTTP_PORT2 $XHTTP_PORT3 $WS_PORT1 $WS_PORT2 $VMESS_PORT1 $VMESS_PORT2 $SS_PORT1 $SS_PORT2 $SS_PORT3 $GRPC_PORT"

    cat > "$INFO_FILE" <<EOF
Ramtin Xray Generator
Version: ${SCRIPT_VERSION}
Generated: $(date -Is)

Server IP: ${SERVER_IP}
Xray version: ${XRAY_VERSION}

REALITY target #1: ${REALITY_TARGET1}
REALITY target #2: ${REALITY_TARGET2}
REALITY target #3: ${REALITY_TARGET3}
REALITY SNI #1: ${REALITY_SNI1}
REALITY SNI #2: ${REALITY_SNI2}
REALITY SNI #3: ${REALITY_SNI3}
REALITY public key: ${REALITY_PUBLIC_KEY}

TCP ports:
${ports}

Files:
Xray config : ${CONFIG_FILE}
Secrets     : ${SECRETS_FILE}
Clash/Mihomo: ${CLASH_FILE}
URI list    : ${URI_FILE}
Service     : ${SERVICE_FILE}
Logs        : ${LOG_DIR}

Commands:
systemctl status ramtin-xray
systemctl restart ramtin-xray
journalctl -u ramtin-xray -n 100 --no-pager
/usr/local/bin/xray run -test -config ${CONFIG_FILE}

Security notes:
- Do not publish ${SECRETS_FILE}.
- REALITY private key must remain server-side.
- Client config contains credentials and must be treated as secret.
- UDP is intentionally not opened/used by the generated primary profiles.
EOF
    chmod 600 "$INFO_FILE"
}

show_summary() {
    clear || true
    printf '%b\n' "${GREEN}${BOLD}============================================================${NC}"
    printf '%b\n' "${GREEN}${BOLD} Ramtin Xray Generator ${SCRIPT_VERSION} - READY${NC}"
    printf '%b\n' "${GREEN}${BOLD}============================================================${NC}"
    printf '%b\n' "${CYAN}Server:${NC} ${SERVER_IP}"
    printf '%b\n' "${CYAN}Xray:${NC}   ${XRAY_VERSION}"
    printf '%b\n' "${CYAN}REALITY:${NC} ${REALITY_TARGET1} | ${REALITY_TARGET2} | ${REALITY_TARGET3}"
    printf '%b\n' "${CYAN}Service:${NC} systemctl status ramtin-xray"
    printf '\n%b\n' "${YELLOW}Primary client config:${NC}"
    printf '%b\n' "  ${CLASH_FILE}"
    printf '%b\n' "${YELLOW}URI list:${NC}"
    printf '%b\n' "  ${URI_FILE}"
    printf '%b\n' "${YELLOW}Xray server config:${NC}"
    printf '%b\n' "  ${CONFIG_FILE}"
    printf '%b\n' "${YELLOW}Management:${NC}"
    printf '%b\n' "  systemctl restart ramtin-xray"
    printf '%b\n' "  journalctl -u ramtin-xray -f"
    printf '\n%b\n' "${GREEN}Do not share ${SECRETS_FILE} or the Clash/URI files publicly.${NC}"
}

main() {
    require_root
    check_os

    mkdir -p "$BASE_DIR" "$BACKUP_ROOT"
    TMP_DIR="$(mktemp -d)"

    log "Installing required packages..."
    install_packages

    log "Detecting server..."
    detect_server_ip
    log "Server IP: ${SERVER_IP}"

    log "Checking ports..."
    check_ports

    if [[ -f "$CONFIG_FILE" || -f "$SERVICE_FILE" ]]; then
        backup_existing
        systemctl stop ramtin-xray.service 2>/dev/null || true
    fi

    log "Installing pinned Xray version ${XRAY_VERSION}..."
    install_xray

    log "Generating credentials..."
    generate_credentials

    log "Selecting/testing REALITY target..."
    select_reality_targets

    log "Saving secrets..."
    write_secrets

    log "Writing Xray configuration..."
    write_xray_config

    validate_xray_config

    log "Installing systemd service..."
    write_systemd

    log "Configuring firewall..."
    configure_firewall

    log "Generating URI output..."
    write_uri_file

    log "Generating Mihomo/Clash output..."
    write_clash_config

    log "Writing server information..."
    write_info

    show_summary
}

main "$@"
