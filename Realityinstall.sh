#!/bin/bash
#
# Xray VLESS + Reality 一键安装配置脚本
# 支持：自定义端口（15秒超时随机）、自定义伪装域名（默认 www.tesla.com）、
#       可选启用 WARP WireGuard 出站分流、
#       自定义分流域名（默认 geosite:cn + geoip:cn）
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
WARP_DIR="${XRAY_CONFIG_DIR}/warp"

[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 用户运行此脚本${PLAIN}"; exit 1; }

# ---------- 安装 Xray-core ----------
install_xray() {
    if command -v xray &>/dev/null; then
        echo -e "${GREEN}检测到 Xray 已安装，跳过安装步骤${PLAIN}"
    else
        echo -e "${GREEN}正在安装 Xray-core...${PLAIN}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
}

# ---------- 生成随机端口 ----------
gen_random_port() {
    echo $(( (RANDOM % 55536) + 10000 ))
}

# ---------- 询问端口（15秒超时） ----------
ask_port() {
    echo -e "${YELLOW}请输入监听端口 (1-65535)，15 秒内未输入将自动生成随机端口${PLAIN}"
    if read -t 15 -p "端口: " INPUT_PORT; then
        if [[ -n "$INPUT_PORT" && "$INPUT_PORT" =~ ^[0-9]+$ && "$INPUT_PORT" -ge 1 && "$INPUT_PORT" -le 65535 ]]; then
            PORT="$INPUT_PORT"
        else
            PORT=$(gen_random_port)
            echo -e "${YELLOW}输入无效，已生成随机端口: ${PORT}${PLAIN}"
        fi
    else
        PORT=$(gen_random_port)
        echo -e "\n${YELLOW}超时未输入，已生成随机端口: ${PORT}${PLAIN}"
    fi
    echo -e "${GREEN}将使用端口: ${PORT}${PLAIN}"
}

# ---------- 询问伪装域名 ----------
ask_domain() {
    read -p "请输入用于 Reality 伪装的目标域名 (直接回车默认 www.tesla.com): " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-www.tesla.com}"
    echo -e "${GREEN}将使用伪装域名: ${DOMAIN}${PLAIN}"
}

# ---------- 生成密钥、UUID、ShortID ----------
gen_keys() {
    echo -e "${GREEN}正在生成密钥对...${PLAIN}"
    local kp
    kp=$(xray x25519)
    PRIVATE_KEY=$(echo "$kp" | grep -i "Private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$kp" | grep -i "Public" | awk '{print $NF}')
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 8)
}

# ---------- 询问是否启用 WARP ----------
ask_warp() {
    read -p "是否启用 WARP WireGuard 出站分流? (y/n，默认 n): " ENABLE_WARP
    ENABLE_WARP=${ENABLE_WARP:-n}
}

# ---------- 安装 wgcf ----------
install_wgcf() {
    if command -v wgcf &>/dev/null; then
        return
    fi
    echo -e "${GREEN}正在安装 wgcf...${PLAIN}"
    local arch wgcf_arch wgcf_ver
    arch=$(uname -m)
    case "$arch" in
        x86_64) wgcf_arch="amd64" ;;
        aarch64) wgcf_arch="arm64" ;;
        *) echo -e "${RED}不支持的架构: ${arch}${PLAIN}"; exit 1 ;;
    esac
    wgcf_ver=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -L -o /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/${wgcf_ver}/wgcf_${wgcf_ver#v}_linux_${wgcf_arch}"
    chmod +x /usr/local/bin/wgcf
}

# ---------- 按照 xtls 官方文档「方法 1」注册 WARP 并生成 Xray WireGuard 出站参数 ----------
# 参考: https://xtls.github.io/document/level-2/warp.html
setup_warp() {
    install_wgcf
    mkdir -p "$WARP_DIR"
    pushd "$WARP_DIR" >/dev/null

    if [[ ! -f wgcf-account.toml ]]; then
        echo -e "${GREEN}正在注册 WARP 账户...${PLAIN}"
        wgcf register --accept-tos
    fi

    echo -e "${GREEN}正在生成 WARP WireGuard 配置...${PLAIN}"
    wgcf generate

    WARP_PRIVATE_KEY=$(grep -i "^PrivateKey" wgcf-profile.conf | awk -F'= ' '{print $2}')
    WARP_ADDR_V4=$(grep -i "^Address" wgcf-profile.conf | head -n1 | awk -F'= ' '{print $2}')
    WARP_ADDR_V6=$(grep -i "^Address" wgcf-profile.conf | tail -n1 | awk -F'= ' '{print $2}')
    WARP_PUBLIC_KEY=$(grep -i "^PublicKey" wgcf-profile.conf | awk -F'= ' '{print $2}')
    WARP_ENDPOINT=$(grep -i "^Endpoint" wgcf-profile.conf | awk -F'= ' '{print $2}')

    popd >/dev/null

    if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_PUBLIC_KEY" ]]; then
        echo -e "${RED}WARP 配置生成失败，请检查 wgcf 输出${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}WARP 配置生成成功${PLAIN}"
}

# ---------- 询问分流域名 ----------
ask_split_domains() {
    echo -e "${YELLOW}请输入需要走 WARP 分流的规则，多个用英文逗号分隔${PLAIN}"
    echo -e "${YELLOW}支持三种写法: 直接写服务名(如 openai,netflix 会自动转换为 geosite:openai,geosite:netflix)、完整域名(如 example.com)、或显式规则(geosite:xxx / geoip:xxx)${PLAIN}"
    read -p "直接回车表示暂不添加自定义分流规则: " INPUT_RULES

    SPLIT_DOMAINS=""
    SPLIT_IPS=""

    if [[ -n "$INPUT_RULES" ]]; then
        IFS=',' read -ra ARR <<< "$INPUT_RULES"
        for item in "${ARR[@]}"; do
            item=$(echo "$item" | xargs)
            [[ -z "$item" ]] && continue
            if [[ "$item" == geoip:* ]]; then
                SPLIT_IPS+="\"$item\","
            elif [[ "$item" == geosite:* ]]; then
                SPLIT_DOMAINS+="\"$item\","
            elif [[ "$item" == *.* ]]; then
                # 含点号的视为完整域名，原样加入
                SPLIT_DOMAINS+="\"$item\","
            else
                # 纯服务名，自动转换为 geosite:服务名
                SPLIT_DOMAINS+="\"geosite:${item}\","
            fi
        done
        SPLIT_DOMAINS="${SPLIT_DOMAINS%,}"
        SPLIT_IPS="${SPLIT_IPS%,}"
    fi
    echo -e "${GREEN}自定义分流域名规则: ${SPLIT_DOMAINS:-无}${PLAIN}"
    echo -e "${GREEN}自定义分流 IP 规则: ${SPLIT_IPS:-无}${PLAIN}"
}

# ---------- 询问是否将回国流量(CN)也分流至 WARP ----------
ask_cn_to_warp() {
    read -p "是否将回国流量 (geosite:cn / geoip:cn) 也分流至 WARP? (y/n，默认 n): " CN_TO_WARP
    CN_TO_WARP=${CN_TO_WARP:-n}
    if [[ "$CN_TO_WARP" =~ ^[Yy]$ ]]; then
        if [[ -n "$SPLIT_DOMAINS" ]]; then
            SPLIT_DOMAINS+=",\"geosite:cn\""
        else
            SPLIT_DOMAINS='"geosite:cn"'
        fi
        if [[ -n "$SPLIT_IPS" ]]; then
            SPLIT_IPS+=",\"geoip:cn\""
        else
            SPLIT_IPS='"geoip:cn"'
        fi
        echo -e "${GREEN}已将回国流量加入 WARP 分流${PLAIN}"
    fi
}

# ---------- 生成最终配置文件 ----------
generate_config() {
    mkdir -p "$XRAY_CONFIG_DIR"

    WARP_OUTBOUND=""
    ROUTE_RULES="{\"protocol\": [\"bittorrent\"], \"outboundTag\": \"block\"}"

    if [[ "$ENABLE_WARP" =~ ^[Yy]$ ]]; then
        WARP_OUTBOUND=$(cat <<EOF
,
    {
      "tag": "warp",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WARP_PRIVATE_KEY}",
        "address": ["${WARP_ADDR_V4}", "${WARP_ADDR_V6}"],
        "peers": [
          {
            "publicKey": "${WARP_PUBLIC_KEY}",
            "endpoint": "${WARP_ENDPOINT}",
            "allowedIPs": ["0.0.0.0/0", "::/0"]
          }
        ],
        "reserved": [0, 0, 0],
        "mtu": 1280
      }
    }
EOF
)
        WARP_ROUTE_RULE=""
        if [[ -n "$SPLIT_DOMAINS" ]]; then
            WARP_ROUTE_RULE="{\"domain\": [${SPLIT_DOMAINS}], \"outboundTag\": \"warp\"}"
        fi
        if [[ -n "$SPLIT_IPS" ]]; then
            [[ -n "$WARP_ROUTE_RULE" ]] && WARP_ROUTE_RULE+=","
            WARP_ROUTE_RULE+="{\"ip\": [${SPLIT_IPS}], \"outboundTag\": \"warp\"}"
        fi
        [[ -n "$WARP_ROUTE_RULE" ]] && ROUTE_RULES="${WARP_ROUTE_RULE},${ROUTE_RULES}"
    fi

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
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
    }${WARP_OUTBOUND}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      ${ROUTE_RULES}
    ]
  }
}
EOF

    # 校验 JSON 格式
    if command -v xray &>/dev/null; then
        if ! xray run -test -c "$XRAY_CONFIG" &>/tmp/xray_test.log; then
            echo -e "${RED}生成的配置文件校验失败，请查看 /tmp/xray_test.log${PLAIN}"
            exit 1
        fi
    fi
}

# ---------- 启动服务 ----------
start_service() {
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Xray 服务已启动${PLAIN}"
    else
        echo -e "${RED}Xray 服务启动失败，请执行 journalctl -u xray -n 50 查看日志${PLAIN}"
        exit 1
    fi
}

# ---------- 输出结果 ----------
print_result() {
    local ip
    ip=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)
    local link="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${PORT}"

    echo ""
    echo -e "${GREEN}=========== Reality 配置信息 ===========${PLAIN}"
    echo -e "地址(Address)   : ${ip}"
    echo -e "端口(Port)      : ${PORT}"
    echo -e "UUID            : ${UUID}"
    echo -e "流控(Flow)      : xtls-rprx-vision"
    echo -e "传输(Network)   : tcp"
    echo -e "伪装域名(SNI)   : ${DOMAIN}"
    echo -e "Public Key      : ${PUBLIC_KEY}"
    echo -e "Short ID        : ${SHORT_ID}"
    echo -e "指纹(Fingerprint): chrome"
    if [[ "$ENABLE_WARP" =~ ^[Yy]$ ]]; then
        echo -e "WARP 分流       : 已启用 (域名: ${SPLIT_DOMAINS:-无} / IP: ${SPLIT_IPS:-无})"
    else
        echo -e "WARP 分流       : 未启用"
    fi
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${YELLOW}分享链接:${PLAIN}"
    echo "$link"
    echo ""
    echo -e "配置文件路径: ${XRAY_CONFIG}"
}

main() {
    install_xray
    ask_port
    ask_domain
    gen_keys
    ask_warp
    if [[ "$ENABLE_WARP" =~ ^[Yy]$ ]]; then
        setup_warp
        ask_split_domains
        ask_cn_to_warp
    fi
    generate_config
    start_service
    print_result
}

main
