#!/bin/bash
#
# Xray VLESS + Reality 一键安装配置脚本（改进版）
# 支持：自定义端口（15秒超时随机）、自定义伪装域名（默认 www.tesla.com）、
#       可选启用 WARP WireGuard 出站分流（本地生成密钥后向 Cloudflare 官方
#       API 注册，私钥不出本机）、自定义分流域名（域名/服务名/geosite/geoip，
#       另可单独分流回国流量或将全部流量送入 WARP）
#
# 相比旧版修复：
#   - WARP 不再走第三方 warp-reg，私钥由本机 wg 生成，仅向 Cloudflare 官方接口注册
#   - config.json 覆盖前自动备份，生成后 chmod 600，校验/启动失败自动回滚
#   - 所有交互 read 加兜底，非交互（管道/面板）运行时不再无声退出
#   - 随机端口改用 /dev/urandom，覆盖完整 10000-65535
#   - 端口做占用检查，占用时自动换随机端口
#   - 伪装域名做合法性校验
#   - WARP 地址 v6 缺失时只写 v4；endpoint 取官方注册接口返回值
#   - 分享链接对 IPv6 地址加括号；拿不到公网 IP 时明确提示
#   - 结果输出包含 NAT 转发 / 安全组 / 防火墙放行提醒
#   - Xray 尽量以降权用户运行（官方安装脚本支持时）
#

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
CONFIG_BACKUP=""

# Xray 运行用户（安装脚本支持降权时使用）
XRAY_RUN_USER=""

[[ $EUID -ne 0 ]] && {
    echo -e "${RED}请使用 root 用户运行此脚本${PLAIN}"
    exit 1
}

# ---------- 安装 Xray-core ----------
install_xray() {
    if command -v xray &>/dev/null; then
        echo -e "${GREEN}检测到 Xray 已安装，跳过安装步骤${PLAIN}"
        return
    fi

    echo -e "${GREEN}正在安装 Xray-core...${PLAIN}"
    local installer=/tmp/xray-install-release.sh
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"

    # 官方安装脚本支持 --user 时降权运行（随机/指定端口都在 1024 以上，无需 root）
    if grep -q -- '--user' "$installer" 2>/dev/null; then
        if ! id -u xray &>/dev/null; then
            useradd --system --no-create-home --shell /usr/sbin/nologin xray 2>/dev/null || true
        fi
        if id -u xray &>/dev/null; then
            XRAY_RUN_USER="xray"
            bash "$installer" install -u xray
            rm -f "$installer"
            return
        fi
    fi

    echo -e "${YELLOW}安装脚本不支持降权运行，将以默认方式安装（服务以 root 运行）${PLAIN}"
    bash "$installer" install
    rm -f "$installer"
}

# ---------- 生成随机端口（覆盖完整 10000-65535） ----------
gen_random_port() {
    local n
    n=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    echo $(( n % 55536 + 10000 ))
}

# ---------- 端口是否被占用 ----------
port_in_use() {
    if command -v ss &>/dev/null; then
        ss -H -tln "sport = :$1" 2>/dev/null | grep -q . && return 0
        ss -H -uln "sport = :$1" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    # 无 ss 时退化为尝试监听判断（粗略）
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------- 校验/修正端口占用 ----------
ensure_port_free() {
    local try=0
    while port_in_use "$PORT"; do
        try=$((try + 1))
        if [[ $try -gt 10 ]]; then
            echo -e "${RED}多次尝试仍找不到空闲端口，请手动检查系统监听状态${PLAIN}"
            exit 1
        fi
        local new_port
        new_port=$(gen_random_port)
        echo -e "${YELLOW}端口 ${PORT} 已被占用，自动更换为: ${new_port}${PLAIN}"
        PORT="$new_port"
    done
}

# ---------- 询问端口（15秒超时） ----------
ask_port() {
    echo -e "${YELLOW}请输入监听端口 (1-65535)，15 秒内未输入将自动生成随机端口${PLAIN}"

    if read -t 15 -p "端口: " INPUT_PORT; then
        if [[ -n "$INPUT_PORT" &&
              "$INPUT_PORT" =~ ^[0-9]+$ &&
              "$INPUT_PORT" -ge 1 &&
              "$INPUT_PORT" -le 65535 ]]; then
            PORT="$INPUT_PORT"
        else
            PORT=$(gen_random_port)
            echo -e "${YELLOW}输入无效，已生成随机端口: ${PORT}${PLAIN}"
        fi
    else
        PORT=$(gen_random_port)
        echo -e "\n${YELLOW}超时未输入，已生成随机端口: ${PORT}${PLAIN}"
    fi

    ensure_port_free
    echo -e "${GREEN}将使用端口: ${PORT}${PLAIN}"
}

# ---------- 询问伪装域名 ----------
ask_domain() {
    read -p "请输入用于 Reality 伪装的目标域名 (直接回车默认 www.tesla.com): " INPUT_DOMAIN || true
    DOMAIN="${INPUT_DOMAIN:-www.tesla.com}"

    # 域名合法性校验，防止拼进 JSON 时结构被破坏
    if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        echo -e "${YELLOW}域名格式不合法，已改用默认 www.tesla.com${PLAIN}"
        DOMAIN="www.tesla.com"
    fi

    echo -e "${GREEN}将使用伪装域名: ${DOMAIN}${PLAIN}"
}

# ---------- 生成密钥、UUID、ShortID ----------
gen_keys() {
    echo -e "${GREEN}正在生成密钥对...${PLAIN}"

    local kp
    kp=$(xray x25519)

    PRIVATE_KEY=$(echo "$kp" | grep -i "Private" | awk '{print $NF}' | head -n1)
    PUBLIC_KEY=$(echo "$kp" | grep -i "Public" | awk '{print $NF}' | head -n1)

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}xray x25519 输出无法解析，原始输出如下:${PLAIN}"
        echo "$kp"
        exit 1
    fi

    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 8)
}

# ---------- 询问是否启用 WARP ----------
ask_warp() {
    read -p "是否启用 WARP WireGuard 出站分流? (y/n，默认 n): " ENABLE_WARP || true
    ENABLE_WARP=${ENABLE_WARP:-n}
}

# ---------- 准备 WARP 依赖（wg 工具 + python3） ----------
ensure_warp_deps() {
    local missing=()

    command -v wg &>/dev/null || missing+=("wireguard-tools")
    command -v python3 &>/dev/null || missing+=("python3")
    command -v curl &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${GREEN}正在安装 WARP 依赖: ${missing[*]}${PLAIN}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
        else
            echo -e "${RED}缺少依赖 ${missing[*]}，且系统无 apt-get，请手动安装后重试${PLAIN}"
            exit 1
        fi
    fi

    command -v wg &>/dev/null || {
        echo -e "${RED}wg 命令不可用，WARP 无法继续${PLAIN}"
        exit 1
    }
    command -v python3 &>/dev/null || {
        echo -e "${RED}python3 不可用，WARP 无法继续${PLAIN}"
        exit 1
    }
}

# ---------- 本地生成密钥，向 Cloudflare 官方 API 注册 WARP ----------
# 私钥由本机 wg genkey 生成，全程不出本机；公钥提交到
# https://api.cloudflareclient.com 官方注册接口，服务端公钥、客户端
# 地址、endpoint、reserved 均取接口返回的结构化字段。
setup_warp() {
    ensure_warp_deps

    echo -e "${GREEN}正在本地生成 WARP 密钥对...${PLAIN}"
    WARP_PRIVATE_KEY=$(wg genkey)
    local client_pubkey
    client_pubkey=$(printf '%s' "$WARP_PRIVATE_KEY" | wg pubkey)

    echo -e "${GREEN}正在向 Cloudflare 官方接口注册 WARP 账户...${PLAIN}"
    local tos resp http_code body
    tos=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    resp=$(curl -sS --max-time 30 -w $'\n%{http_code}' -X POST \
        "https://api.cloudflareclient.com/v0a2158/reg" \
        -H 'User-Agent: okhttp/3.12.1' \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"${client_pubkey}\",\"install_id\":\"\",\"tos\":\"${tos}\",\"type\":\"Android\",\"locale\":\"en_US\",\"warp_enabled\":true}") || {
        echo -e "${RED}无法连接 Cloudflare 注册接口，请检查服务器网络${PLAIN}"
        exit 1
    }
    http_code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    if [[ "$http_code" != "200" ]] || ! grep -q '"config"' <<<"$body"; then
        echo -e "${RED}WARP 注册失败 (HTTP ${http_code})，响应已保存到 /tmp/warp_reg_response.json${PLAIN}"
        printf '%s' "$body" > /tmp/warp_reg_response.json
        exit 1
    fi

    # 结构化解析注册结果（字段含义见函数注释）
    # 先把响应写到文件再交给 python3 读取，避免 heredoc 与管道抢 stdin
    printf '%s' "$body" > /tmp/warp_reg_body.json
    local parsed
    parsed=$(python3 - /tmp/warp_reg_body.json <<'PYEOF'
import sys, json, base64

with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
cfg = d.get("config") or {}
peers = cfg.get("peers") or [{}]
peer = peers[0] if peers else {}
ep = peer.get("endpoint") or {}
addr = (cfg.get("interface") or {}).get("addresses") or {}

reserved = "0,0,0"
cid = cfg.get("client_id") or ""
try:
    raw = base64.b64decode(cid)
    if len(raw) >= 3:
        reserved = ",".join(str(b) for b in raw[:3])
except Exception:
    pass

print("WARP_SERVER_PUBKEY=" + (peer.get("public_key") or ""))
print("WARP_ADDR_V4=" + (addr.get("v4") or ""))
print("WARP_ADDR_V6=" + (addr.get("v6") or ""))
print("WARP_ENDPOINT_V4=" + (ep.get("v4") or ""))
print("WARP_ENDPOINT_HOST=" + (ep.get("host") or ""))
print("WARP_RESERVED=" + reserved)
PYEOF
)

    WARP_SERVER_PUBKEY=""
    WARP_ADDR_V4=""
    WARP_ADDR_V6=""
    WARP_ENDPOINT_V4=""
    WARP_ENDPOINT_HOST=""
    WARP_RESERVED="0,0,0"
    while IFS='=' read -r k v; do
        case "$k" in
            WARP_SERVER_PUBKEY) WARP_SERVER_PUBKEY="$v" ;;
            WARP_ADDR_V4) WARP_ADDR_V4="$v" ;;
            WARP_ADDR_V6) WARP_ADDR_V6="$v" ;;
            WARP_ENDPOINT_V4) WARP_ENDPOINT_V4="$v" ;;
            WARP_ENDPOINT_HOST) WARP_ENDPOINT_HOST="$v" ;;
            WARP_RESERVED) WARP_RESERVED="$v" ;;
        esac
    done <<<"$parsed"

    if [[ -z "$WARP_SERVER_PUBKEY" || -z "$WARP_ADDR_V4" ]]; then
        echo -e "${RED}WARP 注册结果解析不完整，响应已保存到 /tmp/warp_reg_response.json${PLAIN}"
        printf '%s' "$body" > /tmp/warp_reg_response.json
        exit 1
    fi

    # endpoint：注意官方接口返回的 v4 端口是 0（占位），真实端口固定 2408
    # 因此只取 IP 部分，强制拼 :2408；取不到 IP 时退回官方域名端点
    if [[ -n "$WARP_ENDPOINT_V4" ]]; then
        WARP_ENDPOINT="${WARP_ENDPOINT_V4%%:*}:2408"
    elif [[ -n "$WARP_ENDPOINT_HOST" ]]; then
        if [[ "$WARP_ENDPOINT_HOST" =~ :[0-9]+$ ]]; then
            WARP_ENDPOINT="$WARP_ENDPOINT_HOST"
        else
            WARP_ENDPOINT="${WARP_ENDPOINT_HOST}:2408"
        fi
    else
        WARP_ENDPOINT="162.159.192.4:2408"
    fi

    # 地址列表：v6 缺失时只写 v4，避免生成无效的 "/128"
    WARP_ADDRESSES="\"${WARP_ADDR_V4}/32\""
    if [[ -n "$WARP_ADDR_V6" ]]; then
        WARP_ADDRESSES="${WARP_ADDRESSES}, \"${WARP_ADDR_V6}/128\""
    fi

    echo -e "${GREEN}WARP 注册成功 (endpoint: ${WARP_ENDPOINT})${PLAIN}"
}

# ---------- 询问分流域名 ----------
ask_split_domains() {
    echo -e "${YELLOW}请输入需要走 WARP 分流的规则，多个用英文逗号分隔${PLAIN}"

    echo -e "${YELLOW}支持三种写法:${PLAIN}"
    echo -e "${YELLOW}  服务名：openai,netflix → 自动转换为 geosite:openai,geosite:netflix${PLAIN}"
    echo -e "${YELLOW}  完整域名：example.com → 自动转换为 domain:example.com${PLAIN}"
    echo -e "${YELLOW}  显式规则：geosite:xxx / geoip:xxx${PLAIN}"

    read -p "直接回车表示暂不添加自定义分流规则: " INPUT_RULES || true

    SPLIT_DOMAINS=""
    SPLIT_IPS=""

    # 归一化：
    # 全角逗号 → 半角逗号
    # 全角空格 → 半角空格
    # 不间断空格 → 普通空格
    INPUT_RULES=$(echo "$INPUT_RULES" |
        sed 's/，/,/g; s/　/ /g; s/\xc2\xa0/ /g')

    if [[ -n "$INPUT_RULES" ]]; then

        IFS=',' read -ra ARR <<< "$INPUT_RULES"

        for item in "${ARR[@]}"; do

            # 去除首尾空白
            item=$(echo "$item" |
                sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            [[ -z "$item" ]] && continue

            # ---------- geoip ----------
            if [[ "$item" == geoip:* ]]; then

                rule_body="${item#geoip:}"

                if [[ "$rule_body" =~ ^[A-Za-z0-9.:/_-]+$ ]]; then

                    SPLIT_IPS+="\"$item\","

                else

                    echo -e "${RED}忽略无法识别的规则: ${item}${PLAIN}"

                fi

            # ---------- geosite ----------
            elif [[ "$item" == geosite:* ]]; then

                rule_body="${item#geosite:}"

                if [[ "$rule_body" =~ ^[A-Za-z0-9_!-]+$ ]]; then

                    SPLIT_DOMAINS+="\"$item\","

                else

                    echo -e "${RED}忽略无法识别的规则: ${item}${PLAIN}"

                fi

            # ---------- 普通域名（自动添加 domain: 前缀） ----------
            elif [[ "$item" == *.* ]]; then

                if [[ "$item" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then

                    SPLIT_DOMAINS+="\"domain:${item}\","

                else

                    echo -e "${RED}忽略无法识别的域名: ${item}${PLAIN}"

                fi

            # ---------- 服务名（自动转换为 geosite） ----------
            elif [[ "$item" =~ ^[A-Za-z0-9_-]+$ ]]; then

                SPLIT_DOMAINS+="\"geosite:${item}\","

            else

                echo -e "${RED}忽略无法识别的规则: ${item}${PLAIN}"

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

    read -p "是否将回国流量 (geosite:cn / geoip:cn) 也分流至 WARP? (y/n，默认 n): " CN_TO_WARP || true

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
        echo -e "${YELLOW}注意：走 WARP 后出口在境外，访问国内资源可能变慢或被按境外 IP 限制${PLAIN}"
    fi
}

# ---------- 询问是否将全部流量送入 WARP ----------
ask_warp_global() {

    read -p "是否将全部流量都送入 WARP? (y/n，默认 n，仅指定规则走 WARP，其余直连): " WARP_GLOBAL || true

    WARP_GLOBAL=${WARP_GLOBAL:-n}

    if [[ "$WARP_GLOBAL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}已设置：全部流量走 WARP（BitTorrent 仍被阻断）${PLAIN}"
    fi
}

# ---------- 备份现有配置 ----------
backup_config() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        CONFIG_BACKUP="${XRAY_CONFIG}.bak-$(date +%Y%m%d%H%M%S)"
        cp -a "$XRAY_CONFIG" "$CONFIG_BACKUP"
        echo -e "${GREEN}已备份原配置到: ${CONFIG_BACKUP}${PLAIN}"
    fi
}

# ---------- 回滚配置 ----------
rollback_config() {
    if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
        echo -e "${YELLOW}正在回滚到原配置...${PLAIN}"
        cp -a "$CONFIG_BACKUP" "$XRAY_CONFIG"
        systemctl restart xray || true
        if systemctl is-active --quiet xray; then
            echo -e "${GREEN}已回滚，Xray 服务恢复运行（使用原配置）${PLAIN}"
        else
            echo -e "${RED}回滚后服务仍未正常运行，请手动检查${PLAIN}"
        fi
    fi
}

# ---------- 生成最终配置文件 ----------
generate_config() {

    mkdir -p "$XRAY_CONFIG_DIR"

    WARP_OUTBOUND=""

    # 默认 AsIs；存在 geoip 分流时用 IPIfNonMatch：
    # 域名先匹配，域名未命中时再解析 IP，使 geoip 规则能参与分流
    ROUTING_DOMAIN_STRATEGY="AsIs"

    if [[ -n "$SPLIT_IPS" ]]; then
        ROUTING_DOMAIN_STRATEGY="IPIfNonMatch"
    fi

    # ---------- 格式化列表 ----------
    format_list_multiline() {
        local list="$1"
        local indent="$2"

        echo "$list" |
            sed "s/,/,\n${indent}/g"
    }

    # BitTorrent 阻断规则放最前面：即使 BT 流量命中后续 WARP 规则，
    # 也会优先被 block
    BLOCK_RULE=$(cat <<EOF
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
EOF
)

    ROUTE_RULES="$BLOCK_RULE"

    # ---------- WARP ----------
    if [[ "$ENABLE_WARP" =~ ^[Yy]$ ]]; then

        WARP_OUTBOUND=$(cat <<EOF
,
    {
      "tag": "warp",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WARP_PRIVATE_KEY}",
        "address": [
          ${WARP_ADDRESSES}
        ],
        "peers": [
          {
            "endpoint": "${WARP_ENDPOINT}",
            "publicKey": "${WARP_SERVER_PUBKEY}",
            "keepAlive": 5,
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ]
          }
        ],
        "reserved": [${WARP_RESERVED}],
        "mtu": 1280,
        "domainStrategy": "ForceIP"
      }
    }
EOF
)

        WARP_ROUTE_RULES=""

        # ---------- WARP 域名规则 ----------
        if [[ -n "$SPLIT_DOMAINS" ]]; then

            DOMAIN_ITEMS=$(format_list_multiline "$SPLIT_DOMAINS" "          ")

            WARP_DOMAIN_RULE=$(cat <<EOF
      {
        "type": "field",
        "domain": [
          ${DOMAIN_ITEMS}
        ],
        "outboundTag": "warp"
      }
EOF
)

            WARP_ROUTE_RULES="${WARP_DOMAIN_RULE}"

        fi

        # ---------- WARP IP规则 ----------
        if [[ -n "$SPLIT_IPS" ]]; then

            IP_ITEMS=$(format_list_multiline "$SPLIT_IPS" "          ")

            WARP_IP_RULE=$(cat <<EOF
      {
        "type": "field",
        "ip": [
          ${IP_ITEMS}
        ],
        "outboundTag": "warp"
      }
EOF
)

            if [[ -n "$WARP_ROUTE_RULES" ]]; then
                WARP_ROUTE_RULES="${WARP_ROUTE_RULES},"$'\n'
            fi

            WARP_ROUTE_RULES="${WARP_ROUTE_RULES}${WARP_IP_RULE}"

        fi

        #
        # 最终顺序：
        # 1. bittorrent → block
        # 2. WARP domain → warp
        # 3. WARP IP → warp
        # 4. （可选）全流量 → warp
        #
        if [[ -n "$WARP_ROUTE_RULES" ]]; then

            ROUTE_RULES="${ROUTE_RULES},"$'\n'"${WARP_ROUTE_RULES}"

        fi

        # ---------- 全局 WARP（兜底规则，放最后） ----------
        if [[ "${WARP_GLOBAL:-n}" =~ ^[Yy]$ ]]; then

            GLOBAL_RULE='      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "warp"
      }'

            ROUTE_RULES="${ROUTE_RULES},"$'\n'"${GLOBAL_RULE}"

        elif [[ -z "$SPLIT_DOMAINS" && -z "$SPLIT_IPS" ]]; then

            echo -e "${YELLOW}警告：已启用 WARP 但未设置任何分流规则，将没有任何流量走 WARP${PLAIN}"

        fi

    fi

    # ---------- 生成 config.json ----------
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
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
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
    "domainStrategy": "${ROUTING_DOMAIN_STRATEGY}",

    "rules": [
${ROUTE_RULES}
    ]
  }
}
EOF

    # 私钥在配置文件中，限制为仅属主可读
    if [[ -n "$XRAY_RUN_USER" ]]; then
        chown "${XRAY_RUN_USER}:${XRAY_RUN_USER}" "$XRAY_CONFIG" 2>/dev/null || true
    fi
    chmod 600 "$XRAY_CONFIG"

    # ---------- 校验 JSON / Xray 配置 ----------
    if command -v xray &>/dev/null; then

        if ! xray run -test -c "$XRAY_CONFIG" &>/tmp/xray_test.log; then

            echo -e "${RED}生成的配置文件校验失败，请查看 /tmp/xray_test.log${PLAIN}"

            cat /tmp/xray_test.log

            rollback_config

            exit 1
        fi

    fi
}

# ---------- 启动服务 ----------
start_service() {

    systemctl enable xray >/dev/null 2>&1 || true

    if ! systemctl restart xray; then
        echo -e "${RED}Xray 服务启动失败${PLAIN}"
        rollback_config
        echo -e "${YELLOW}排查命令: journalctl -u xray -n 50 --no-pager${PLAIN}"
        exit 1
    fi

    sleep 1

    if systemctl is-active --quiet xray; then

        echo -e "${GREEN}Xray 服务已启动${PLAIN}"

    else

        echo -e "${RED}Xray 服务启动失败，请执行：${PLAIN}"
        echo -e "${YELLOW}journalctl -u xray -n 50 --no-pager${PLAIN}"

        rollback_config

        exit 1
    fi
}

# ---------- 输出结果 ----------
print_result() {

    local ip

    ip=$(curl -s4 --max-time 10 https://api.ipify.org ||
         curl -s6 --max-time 10 https://api64.ipify.org ||
         true)

    # IPv6 地址在链接中需要加方括号
    local ip_for_link="$ip"
    if [[ "$ip" == *:* ]]; then
        ip_for_link="[${ip}]"
    fi

    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}未能自动获取公网 IP（可能无外网直连），下方链接中的地址请手动替换为你的公网 IP${PLAIN}"
        ip="(请手动填写公网IP)"
        ip_for_link="$ip"
    fi

    local link="vless://${UUID}@${ip_for_link}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${PORT}"

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

        echo -e "WARP 分流       : 已启用"
        echo -e "WARP 域名规则   : ${SPLIT_DOMAINS:-无}"
        echo -e "WARP IP 规则    : ${SPLIT_IPS:-无}"

        if [[ "${WARP_GLOBAL:-n}" =~ ^[Yy]$ ]]; then
            echo -e "WARP 全局       : 已启用（全部流量走 WARP）"
        else
            echo -e "WARP 全局       : 未启用"
        fi

        echo -e "Routing Strategy: ${ROUTING_DOMAIN_STRATEGY}"

    else

        echo -e "WARP 分流       : 未启用"

    fi

    echo -e "${GREEN}=========================================${PLAIN}"

    echo -e "${YELLOW}分享链接:${PLAIN}"
    echo "$link"
    echo ""
    echo -e "配置文件路径: ${XRAY_CONFIG}"

    if [[ -n "$CONFIG_BACKUP" ]]; then
        echo -e "原配置备份: ${CONFIG_BACKUP}"
    fi

    echo ""
    echo -e "${YELLOW}请确保以下放行，否则客户端连不上：${PLAIN}"
    echo -e "  1. 云厂商安全组 / 服务器防火墙放行 TCP ${PORT}"
    echo -e "  2. NAT 环境（如路由器、内网 VPS）需将公网 ${PORT} 端口转发到本机"
    echo -e "  3. 本机防火墙（如 ufw/nftables）放行 TCP ${PORT}"
}

# ---------- 主程序 ----------
main() {

    install_xray

    ask_port

    ask_domain

    gen_keys

    ask_warp

    if [[ "$ENABLE_WARP" =~ ^[Yy]$ ]]; then

        setup_warp

        ask_warp_global

        if [[ "${WARP_GLOBAL:-n}" =~ ^[Yy]$ ]]; then
            # 全局模式下不需要再逐项收集分流规则
            SPLIT_DOMAINS=""
            SPLIT_IPS=""
        else
            ask_split_domains

            ask_cn_to_warp
        fi

    fi

    backup_config

    generate_config

    start_service

    print_result
}

main
