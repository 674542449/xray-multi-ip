#!/usr/bin/env bash
# ==============================================================================
# Script Name: xrayL.sh (Multi-IP & Dual-Stack Xray Proxy Deployment Script)
# Author: Improved based on bulianglin/demo
# Features:
#   1. Pure SOCKS5 & VMess+WS Support
#   2. Automatic Google BBR & TCP High-Speed Optimization
#   3. IPv4 + IPv6 Dual-Stack Global Ingress (双栈全网卡监听)
#   4. Per-Port Dedicated Egress (sendThrough 端口分流独立落地)
#   5. Automatic IPv6 Subnet (/64, /56, /48) Multi-IP Generation & Persistent Binding
#   6. Multi-format batch proxy export (IP:Port:User:Pass)
#   7. High concurrency tuning & Firewall auto-opening
# Repository: https://github.com/674542449/xray-multi-ip
# ==============================================================================

set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# 核心路径与默认变量
CONFIG_DIR="/etc/xrayL"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/xrayL.service"
BIN_PATH="/usr/local/bin/xrayL"
IPV6_LIST_FILE="${CONFIG_DIR}/ipv6_custom.list"
IPV6_BIND_SCRIPT="/usr/local/bin/xrayL-bind-ipv6"

# 导出基础目录
if [ -w "/root" ]; then
    BASE_EXPORT_DIR="/root"
else
    BASE_EXPORT_DIR="${HOME}"
fi

EXPORT_SOCKS_FILE="${BASE_EXPORT_DIR}/xray_proxies.txt"
EXPORT_SOCKS_IPV4_FILE="${BASE_EXPORT_DIR}/xray_proxies_ipv4_entry.txt"
EXPORT_SOCKS_IPV6_FILE="${BASE_EXPORT_DIR}/xray_proxies_ipv6_entry.txt"
EXPORT_SOCKS_DIRECT_FILE="${BASE_EXPORT_DIR}/xray_proxies_direct.txt"
EXPORT_VMESS_FILE="${BASE_EXPORT_DIR}/xray_vmess.txt"
EXPORT_DOMAIN_FILE="${BASE_EXPORT_DIR}/xray_proxies_domain_entry.txt"

DDNS_CONFIG_FILE="${CONFIG_DIR}/ddns.conf"
DDNS_SCRIPT="/usr/local/bin/xrayL-ddns"

DEFAULT_START_PORT=20000
DEFAULT_SOCKS_USERNAME="userb"
DEFAULT_SOCKS_PASSWORD="passwordb"
DEFAULT_WS_PATH="/ws"

# 生成默认 UUID
if [ -f "/proc/sys/kernel/random/uuid" ]; then
    DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
elif command -v uuidgen &>/dev/null; then
    DEFAULT_UUID=$(uuidgen)
else
    DEFAULT_UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
fi

# 临时目录管理与自动清理 (Trap)
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'xrayL_tmp.XXXXXX')
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# 日志输出函数
info() { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
err() { echo -e "${RED}[ERROR]${PLAIN} $*"; }

# 1. 架构检测
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)
            ARCH="64"
            ;;
        aarch64|arm64)
            ARCH="arm64-v8a"
            ;;
        armv7|armv7l)
            ARCH="arm32-v7a"
            ;;
        s390x)
            ARCH="s390x"
            ;;
        *)
            err "不支持的系统架构: $machine"
            exit 1
            ;;
    esac
}

# 2. 自动检测并开启 Google BBR 与 TCP 拥塞调优
enable_bbr() {
    info "检测并优化 TCP 拥塞控制算法 (Google BBR)..."
    local current_algo
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [ "$current_algo" == "bbr" ]; then
        info "Google BBR 拥塞控制算法已处于启用状态。"
        return 0
    fi

    # 尝试加载内核模块
    modprobe tcp_bbr 2>/dev/null || true

    # 清理并写入 sysctl 优化配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf 2>/dev/null || true

    cat << 'EOF' >> /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF

    sysctl -p >/dev/null 2>&1 || true

    local new_algo
    new_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [ "$new_algo" == "bbr" ]; then
        info "Google BBR 拥塞控制加速已成功开启并生效！"
    else
        warn "当前系统内核可能缺少 BBR 模块，已保留默认网络配置。"
    fi
}

# 3. 完备的依赖检查与安装
install_dependencies() {
    info "检查并安装必要系统依赖..."
    local need_install=()
    local tools=("curl" "wget" "unzip" "ip")

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            need_install+=("$tool")
        fi
    done

    if [ ${#need_install[@]} -gt 0 ]; then
        warn "缺少以下依赖: ${need_install[*]}，正在自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y wget curl unzip iproute2 iptables
        elif command -v yum &>/dev/null; then
            yum install -y wget curl unzip iproute iptables
        elif command -v dnf &>/dev/null; then
            dnf install -y wget curl unzip iproute iptables
        elif command -v apk &>/dev/null; then
            apk add --no-cache wget curl unzip iproute2 iptables ip6tables
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm wget curl unzip iproute2 iptables
        else
            warn "未能识别包管理器，请确保已手动安装: ${need_install[*]}"
        fi
    else
        info "所有基础依赖均已就绪。"
    fi

    # 自动开启 BBR
    enable_bbr
}

# 获取默认网络网卡接口名称
get_default_interface() {
    local iface=""
    iface=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [ -z "$iface" ]; then
        iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    fi
    if [ -z "$iface" ]; then
        iface=$(ip link show | grep -E '^[0-9]+: (eth|ens|enp|eno)' | head -n1 | awk -F': ' '{print $2}' | cut -d'@' -f1)
    fi
    echo "${iface:-eth0}"
}

# 4. 自动放行防火墙端口 (IPv4 + IPv6 双栈)
open_firewall() {
    local start_port=$1
    local end_port=$2
    info "正在放行防火墙端口: ${start_port} ~ ${end_port} (TCP/UDP, IPv4 + IPv6)..."

    # UFW 防火墙 (原生支持 v4 + v6)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        ufw allow "${start_port}:${end_port}/tcp" >/dev/null 2>&1
        ufw allow "${start_port}:${end_port}/udp" >/dev/null 2>&1
        info "UFW 双栈端口规则已放行。"
    fi

    # Firewalld 防火墙 (原生支持 v4 + v6)
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${start_port}-${end_port}/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="${start_port}-${end_port}/udp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "Firewalld 双栈端口规则已放行并重载。"
    fi

    # iptables (IPv4)
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
        iptables -C INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
    fi

    # ip6tables (IPv6)
    if command -v ip6tables &>/dev/null; then
        ip6tables -C INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            ip6tables -I INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
        ip6tables -C INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            ip6tables -I INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
    fi
}

# 5. 获取服务器所有有效 IPv4
get_ipv4_addresses() {
    local ips=()
    if command -v ip &>/dev/null; then
        while IFS= read -r ip_found; do
            [ -n "$ip_found" ] && ips+=("$ip_found")
        done < <(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.|0\.)' || true)
    fi

    if [ ${#ips[@]} -eq 0 ]; then
        if command -v ip &>/dev/null; then
            while IFS= read -r ip_found; do
                [ -n "$ip_found" ] && ips+=("$ip_found")
            done < <(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | grep -vE '^(127\.|169\.254\.|0\.)' || true)
        elif command -v hostname &>/dev/null; then
            for h_ip in $(hostname -I 2>/dev/null); do
                if [[ "$h_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && ! "$h_ip" =~ ^127\. ]]; then
                    ips+=("$h_ip")
                fi
            done
        fi
    fi

    echo "${ips[@]}" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' '
}

# 获取服务器所有有效 IPv6 (过滤 ::1, fe80, fc00, fd00 等)
get_ipv6_addresses() {
    local ips=()
    if command -v ip &>/dev/null; then
        while IFS= read -r ip_found; do
            [ -n "$ip_found" ] && ips+=("$ip_found")
        done < <(ip -6 addr show 2>/dev/null | grep -oE 'inet6 [a-fA-F0-9:]+' | awk '{print $2}' | grep -vE '^(::1|fe80|fc00|fd00)' || true)
    fi
    echo "${ips[@]}" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' '
}

# 探测服务器现有已分配的 IPv6 子网前缀
detect_ipv6_subnet() {
    local iface
    iface=$(get_default_interface)
    local found_cidr=""
    found_cidr=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oE 'inet6 [a-fA-F0-9:]+/[0-9]+' | awk '{print $2}' | grep -vE '^(fe80|fc00|fd00)' | head -n1)
    if [ -n "$found_cidr" ]; then
        echo "$found_cidr"
    else
        echo ""
    fi
}

# 获取主公网 IPv4 入口
get_primary_ipv4() {
    local primary_ip=""
    primary_ip=$(curl -4sSL -m 3 https://api.ipify.org 2>/dev/null || curl -4sSL -m 3 https://ip.sb 2>/dev/null || true)
    if [[ -z "$primary_ip" || ! "$primary_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local local_v4=($(get_ipv4_addresses))
        primary_ip="${local_v4[0]}"
    fi
    echo "$primary_ip"
}

# 获取主公网 IPv6 入口
get_primary_ipv6() {
    local primary_ip=""
    primary_ip=$(curl -6sSL -m 3 https://api64.ipify.org 2>/dev/null || curl -6sSL -m 3 https://ip.sb 2>/dev/null || true)
    if [[ -z "$primary_ip" || ! "$primary_ip" =~ : ]]; then
        local local_v6=($(get_ipv6_addresses))
        primary_ip="${local_v6[0]}"
    fi
    echo "$primary_ip"
}

# 格式化 IP（如果是 IPv6 自动添加方括号）
format_ip_for_uri() {
    local ip="$1"
    if [[ "$ip" =~ : ]]; then
        echo "[${ip}]"
    else
        echo "${ip}"
    fi
}

# 6. IPv6 子网批量生成与绑定模块
batch_generate_and_bind_ipv6() {
    local default_iface
    default_iface=$(get_default_interface)
    local detected_cidr
    detected_cidr=$(detect_ipv6_subnet)

    echo -e "\n${CYAN}================== IPv6 子网批量生成与绑定 ==================${PLAIN}"
    echo -e " 检测到默认网卡: ${GREEN}${default_iface}${PLAIN}"
    if [ -n "$detected_cidr" ]; then
        echo -e " 检测到当前 IPv6 网段: ${GREEN}${detected_cidr}${PLAIN}"
    fi
    echo -e " 提示: 大多数 VPS 服务商（如 Hetzner、OVH、Linode、BuyVM、甲骨文等）"
    echo -e "       会分配 /64 或 /56 子网，但默认网卡上只绑定了 1 个 IP。"
    echo -e "       本功能可根据你的子网前缀，自动批量生成并绑定指定数量的 IPv6 出口。"
    echo -e "${CYAN}============================================================${PLAIN}\n"

    read -r -p "请输入你的 IPv6 子网前缀 (例如 2400:8902:1234:5678::/64 或直接填前缀): " input_prefix
    input_prefix=${input_prefix:-$detected_cidr}

    if [ -z "$input_prefix" ]; then
        err "IPv6 前缀不能为空！"
        return 1
    fi

    # 清洗前缀提取基址
    local clean_prefix="${input_prefix%%/*}" # 去除 /64
    clean_prefix="${clean_prefix%%::*}"      # 去除 :: 之后的部分
    clean_prefix="${clean_prefix%:}"         # 去除末尾冒号

    read -r -p "请输入要生成的 IPv6 数量 (默认 50): " ip_count
    ip_count=${ip_count:-50}

    echo -e "\n请选择 IPv6 后缀生成方式:"
    echo -e "  1. 随机 Hex 后缀 (例如 ${clean_prefix}:a1b2:c3d4:e5f6:7890，${GREEN}防封推荐${PLAIN})"
    echo -e "  2. 递增数字后缀 (例如 ${clean_prefix}::1001, ${clean_prefix}::1002)"
    read -r -p "请输入选项 [1-2, 默认 1]: " gen_mode
    gen_mode=${gen_mode:-1}

    read -r -p "要绑定的网络网卡 (默认 ${default_iface}): " target_iface
    target_iface=${target_iface:-$default_iface}

    mkdir -p "${CONFIG_DIR}"
    local generated_ips=()
    info "正在生成 ${ip_count} 个 IPv6 地址..."

    for ((idx = 1; idx <= ip_count; idx++)); do
        local new_ipv6=""
        if [ "$gen_mode" == "2" ]; then
            local hex_val
            hex_val=$(printf "%x" $((1000 + idx)))
            new_ipv6="${clean_prefix}::${hex_val}"
        else
            local r1 r2 r3 r4
            r1=$(printf "%04x" $((RANDOM % 65536)))
            r2=$(printf "%04x" $((RANDOM % 65536)))
            r3=$(printf "%04x" $((RANDOM % 65536)))
            r4=$(printf "%04x" $((RANDOM % 65536)))
            new_ipv6="${clean_prefix}:${r1}:${r2}:${r3}:${r4}"
        fi
        generated_ips+=("$new_ipv6")
    done

    # 写入保存列表
    printf "%s\n" "${generated_ips[@]}" > "${IPV6_LIST_FILE}"
    info "已生成 ${#generated_ips[@]} 个 IPv6 地址并保存至 ${IPV6_LIST_FILE}"

    # 立即绑定到网卡
    info "正在将 IPv6 地址批量绑定至网卡 ${target_iface}..."
    local success_bind=0
    for g_ip in "${generated_ips[@]}"; do
        if ip -6 addr add "${g_ip}/64" dev "${target_iface}" 2>/dev/null; then
            ((success_bind++))
        fi
    done
    info "成功绑定 ${success_bind} / ${#generated_ips[@]} 个 IPv6 地址！"

    # 生成开机自启自动重新绑定的持久化脚本
    cat <<EOF >"${IPV6_BIND_SCRIPT}"
#!/usr/bin/env bash
IFACE="${target_iface}"
LIST_FILE="${IPV6_LIST_FILE}"
if [ -f "\$LIST_FILE" ]; then
    while IFS= read -r ip_addr; do
        if [[ -n "\$ip_addr" && ! "\$ip_addr" =~ ^# ]]; then
            ip -6 addr add "\${ip_addr}/64" dev "\$IFACE" 2>/dev/null || true
        fi
    done < "\$LIST_FILE"
fi
EOF
    chmod +x "${IPV6_BIND_SCRIPT}"
    info "已创建开机自启绑定脚本: ${IPV6_BIND_SCRIPT}"
}

# ======================== Cloudflare DDNS 模块 ========================

load_ddns_config() {
    CF_API_TOKEN=""
    CF_ZONE_ID=""
    CF_DOMAIN=""
    CF_RECORD_NAME=""
    if [ -f "${DDNS_CONFIG_FILE}" ]; then
        source "${DDNS_CONFIG_FILE}"
    fi
}

save_ddns_config() {
    mkdir -p "${CONFIG_DIR}"
    cat > "${DDNS_CONFIG_FILE}" << EOF
CF_API_TOKEN="${CF_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID}"
CF_DOMAIN="${CF_DOMAIN}"
CF_RECORD_NAME="${CF_RECORD_NAME}"
EOF
    chmod 600 "${DDNS_CONFIG_FILE}"
}

cloudflare_update_record() {
    local record_type="$1"
    local ip="$2"

    local record_info
    record_info=$(curl -sSL -m 10 -X GET \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=${record_type}&name=${CF_RECORD_NAME}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null)

    local record_id current_ip
    record_id=$(echo "$record_info" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    current_ip=$(echo "$record_info" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "$current_ip" == "$ip" ]; then
        info "${record_type} 记录 ${CF_RECORD_NAME} 无需更新 (${ip})"
        return 0
    fi

    local result
    if [ -n "$record_id" ]; then
        result=$(curl -sSL -m 10 -X PUT \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"${record_type}\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}" 2>/dev/null)
    else
        result=$(curl -sSL -m 10 -X POST \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"${record_type}\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}" 2>/dev/null)
    fi

    if echo "$result" | grep -q '"success":true'; then
        info "${record_type} 记录已更新: ${CF_RECORD_NAME} -> ${ip}"
    else
        err "${record_type} 记录更新失败！"
        echo "$result" | grep -o '"message":"[^"]*"' | head -3
        return 1
    fi
}

cloudflare_ddns() {
    load_ddns_config
    if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_RECORD_NAME" ]; then
        err "Cloudflare DDNS 未配置，请先运行 ddns-setup 进行设置。"
        return 1
    fi

    info "执行 Cloudflare DDNS 更新 (${CF_RECORD_NAME})..."

    local current_v4
    current_v4=$(curl -4sSL -m 5 https://api.ipify.org 2>/dev/null || curl -4sSL -m 5 https://ip.sb 2>/dev/null || true)
    if [ -n "$current_v4" ] && [[ "$current_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cloudflare_update_record "A" "$current_v4"
    fi

    local current_v6
    current_v6=$(curl -6sSL -m 5 https://api64.ipify.org 2>/dev/null || curl -6sSL -m 5 https://ip.sb 2>/dev/null || true)
    if [ -n "$current_v6" ] && [[ "$current_v6" =~ : ]]; then
        cloudflare_update_record "AAAA" "$current_v6"
    fi
}

create_ddns_standalone_script() {
    cat > "${DDNS_SCRIPT}" << 'SCRIPT_EOF'
#!/usr/bin/env bash
DDNS_CONF="/etc/xrayL/ddns.conf"
[ -f "$DDNS_CONF" ] || exit 0
source "$DDNS_CONF"
[ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_RECORD_NAME" ] && exit 0

update_record() {
    local rtype="$1" ip="$2"
    local info=$(curl -sSL -m 10 -X GET \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=${rtype}&name=${CF_RECORD_NAME}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" 2>/dev/null)
    local rid=$(echo "$info" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    local cur=$(echo "$info" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ "$cur" == "$ip" ] && return 0
    local data="{\"type\":\"${rtype}\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}"
    if [ -n "$rid" ]; then
        curl -sSL -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${rid}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$data" >/dev/null 2>&1
    else
        curl -sSL -m 10 -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$data" >/dev/null 2>&1
    fi
}

v4=$(curl -4sSL -m 5 https://api.ipify.org 2>/dev/null)
[[ "$v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && update_record "A" "$v4"
v6=$(curl -6sSL -m 5 https://api64.ipify.org 2>/dev/null)
[[ "$v6" =~ : ]] && update_record "AAAA" "$v6"
SCRIPT_EOF
    chmod +x "${DDNS_SCRIPT}"
}

setup_ddns_cron() {
    create_ddns_standalone_script
    local cron_entry="* * * * * ${DDNS_SCRIPT} >/dev/null 2>&1"

    local existing
    existing=$(crontab -l 2>/dev/null | grep -v "xrayL-ddns" || true)
    echo "${existing}
${cron_entry}" | grep -v '^$' | crontab -

    info "已设置每 1 分钟自动 DDNS 更新定时任务。"
}

remove_ddns_cron() {
    local existing
    existing=$(crontab -l 2>/dev/null | grep -v "xrayL-ddns" || true)
    echo "$existing" | crontab -
    info "已移除 DDNS 定时任务。"
}

setup_cloudflare_ddns() {
    echo -e "\n${CYAN}================= Cloudflare DDNS 配置 =================${PLAIN}"
    load_ddns_config

    if [ -n "$CF_RECORD_NAME" ]; then
        echo -e " 当前已配置域名: ${GREEN}${CF_RECORD_NAME}${PLAIN}"
        echo -e " Zone ID: ${CF_ZONE_ID}"
        read -r -p "是否重新配置？[y/N]: " reconf
        if [[ ! "$reconf" =~ ^[yY]$ ]]; then
            echo -e "\n选择操作:"
            echo -e "  1. 立即手动更新 DDNS"
            echo -e "  2. 重新设置定时任务"
            echo -e "  3. 移除 DDNS 配置与定时任务"
            echo -e "  0. 返回"
            read -r -p "请选择 [0-3]: " sub_choice
            case "$sub_choice" in
                1) cloudflare_ddns ;;
                2) setup_ddns_cron ;;
                3)
                    remove_ddns_cron
                    rm -f "${DDNS_CONFIG_FILE}" "${DDNS_SCRIPT}"
                    info "DDNS 配置已清除。"
                    ;;
            esac
            return 0
        fi
    fi

    echo -e "${CYAN}========================================================${PLAIN}"
    echo -e " 需要准备:"
    echo -e "  1. Cloudflare API Token (在 dash.cloudflare.com/profile/api-tokens 创建)"
    echo -e "     权限需要: Zone - DNS - Edit"
    echo -e "  2. 主域名 (例如 example.com，需已托管在 Cloudflare)"
    echo -e "  3. 子域名前缀 (例如 proxy，完整域名 proxy.example.com)"
    echo -e "${CYAN}========================================================${PLAIN}\n"

    read -r -p "Cloudflare API Token: " CF_API_TOKEN
    if [ -z "$CF_API_TOKEN" ]; then
        err "API Token 不能为空！"
        return 1
    fi

    read -r -p "主域名 (例如 example.com): " CF_DOMAIN
    if [ -z "$CF_DOMAIN" ]; then
        err "域名不能为空！"
        return 1
    fi

    info "正在通过 API 获取 Zone ID..."
    local zone_resp
    zone_resp=$(curl -sSL -m 10 -X GET \
        "https://api.cloudflare.com/client/v4/zones?name=${CF_DOMAIN}&status=active" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null)

    CF_ZONE_ID=$(echo "$zone_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$CF_ZONE_ID" ]; then
        err "无法获取 Zone ID！请检查:"
        err "  1. API Token 是否正确且有 Zone:DNS:Edit 权限"
        err "  2. 域名 ${CF_DOMAIN} 是否已托管在 Cloudflare"
        return 1
    fi
    info "Zone ID: ${CF_ZONE_ID}"

    read -r -p "子域名前缀 (例如 proxy，留空则使用主域名): " subdomain
    if [ -n "$subdomain" ]; then
        CF_RECORD_NAME="${subdomain}.${CF_DOMAIN}"
    else
        CF_RECORD_NAME="${CF_DOMAIN}"
    fi

    info "DDNS 域名: ${CF_RECORD_NAME}"
    save_ddns_config

    info "正在执行首次 DDNS 更新..."
    cloudflare_ddns

    read -r -p "是否设置每 1 分钟自动 DDNS 更新？[Y/n]: " auto_cron
    if [[ ! "$auto_cron" =~ ^[nN]$ ]]; then
        setup_ddns_cron
    fi

    echo -e "\n${GREEN}Cloudflare DDNS 配置完成！${PLAIN}"
    echo -e " 域名: ${CYAN}${CF_RECORD_NAME}${PLAIN}"
    echo -e " 之后部署代理时，导出列表将自动使用此域名作为入口。\n"
}

# ======================== Cloudflare DDNS 模块结束 ========================

# 7. 安装 Xray 内核与 Systemd 服务
install_xray() {
    install_dependencies
    detect_arch

    info "正在获取 Xray 最新版本..."
    local latest_tag
    latest_tag=$(curl -sSL -m 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
    if [ -z "$latest_tag" ]; then
        latest_tag="v1.8.24"
        warn "获取 GitHub 最新版本超时，使用内置推荐版本: ${latest_tag}"
    else
        info "最新版本: ${latest_tag}"
    fi

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${ARCH}.zip"
    info "正在下载 Xray 内核 [${ARCH}]: ${download_url}"

    if ! wget -qO "${TMP_DIR}/xray.zip" "$download_url"; then
        if ! curl -fsSLk -o "${TMP_DIR}/xray.zip" "$download_url"; then
            err "下载 Xray 核心失败，请检查网络或 GitHub 连通性！"
            exit 1
        fi
    fi

    info "解压并部署 Xray 内核..."
    unzip -qo "${TMP_DIR}/xray.zip" -d "${TMP_DIR}"
    if [ ! -f "${TMP_DIR}/xray" ]; then
        err "解压失败，未找到 xray 执行文件！"
        exit 1
    fi

    mv "${TMP_DIR}/xray" "${BIN_PATH}"
    chmod +x "${BIN_PATH}"
    mkdir -p "${CONFIG_DIR}"

    # 创建绑定脚本（若不存在）
    if [ ! -f "${IPV6_BIND_SCRIPT}" ]; then
        cat <<EOF >"${IPV6_BIND_SCRIPT}"
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "${IPV6_BIND_SCRIPT}"
    fi

    info "配置 Systemd 守护服务（已配置开机自动绑定 IPv6、文件描述符与高并发限制）..."
    cat <<EOF >"${SERVICE_FILE}"
[Unit]
Description=XrayL Multi-IP Dual-Stack Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=-${IPV6_BIND_SCRIPT}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=3
LimitNOFILE=65535
LimitNPROC=65535
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xrayL.service >/dev/null 2>&1
    info "Xray 内核与服务安装完成！"
}

# 8. 配置生成与双栈/多落地路由 (标准原生 SOCKS5 与 VMess 模式)
config_xray() {
    local config_type="$1" # socks, vmess
    local ip_mode="$2"     # 可选: v4, v6, dual
    mkdir -p "${CONFIG_DIR}"

    # 自动激活 BBR
    enable_bbr

    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        err "类型错误！仅支持 socks 和 vmess。"
        exit 1
    fi

    local all_v4=($(get_ipv4_addresses))
    local all_v6=($(get_ipv6_addresses))

    echo -e "\n${CYAN}======================== 本机 IP 检测结果 ========================${PLAIN}"
    echo -e " 检测到 ${#all_v4[@]} 个 IPv4 地址: ${all_v4[*]:-无}"
    echo -e " 检测到 ${#all_v6[@]} 个 IPv6 地址: ${all_v6[*]:-无}"
    echo -e "${CYAN}==================================================================${PLAIN}\n"

    # 如果 IPv6 较少，询问是否需要批量从 /64 生成并绑定
    if [ -z "$ip_mode" ]; then
        echo -e "是否需要通过 【IPv6 子网 (/64 等)】 批量生成并绑定更多独立 IPv6 出口？"
        read -r -p "是否现在生成并绑定 IPv6？[y/N]: " ask_gen_ipv6
        if [[ "$ask_gen_ipv6" =~ ^[yY]$ ]]; then
            batch_generate_and_bind_ipv6
            all_v6=($(get_ipv6_addresses))
        fi
    fi

    # 选择落地出口 IP 类型
    local target_ips=()
    if [ -n "$ip_mode" ]; then
        case "$ip_mode" in
            v4|ipv4) target_ips=("${all_v4[@]}") ;;
            v6|ipv6) target_ips=("${all_v6[@]}") ;;
            dual|all) target_ips=("${all_v4[@]}" "${all_v6[@]}") ;;
            *) target_ips=("${all_v4[@]}" "${all_v6[@]}") ;;
        esac
    else
        if [ ${#all_v4[@]} -gt 0 ] && [ ${#all_v6[@]} -gt 0 ]; then
            echo -e "\n请选择作为【落地出口】的 IP 范围:"
            echo -e "  1. 仅使用 IPv4 落地 (${#all_v4[@]} 个)"
            echo -e "  2. 仅使用 IPv6 落地 (${#all_v6[@]} 个)"
            echo -e "  3. IPv4 + IPv6 全部混合落地 (共 $(( ${#all_v4[@]} + ${#all_v6[@]} )) 个, 推荐)"
            read -r -p "请输入选项 [1-3, 默认 3]: " ip_choice
            case "$ip_choice" in
                1) target_ips=("${all_v4[@]}") ;;
                2) target_ips=("${all_v6[@]}") ;;
                *) target_ips=("${all_v4[@]}" "${all_v6[@]}") ;;
            esac
        elif [ ${#all_v4[@]} -gt 0 ]; then
            target_ips=("${all_v4[@]}")
        elif [ ${#all_v6[@]} -gt 0 ]; then
            target_ips=("${all_v6[@]}")
        else
            err "未能检测到任何有效 IP 地址，请检查服务器网络！"
            exit 1
        fi
    fi

    if [ ${#target_ips[@]} -eq 0 ]; then
        err "所选落地 IP 列表为空！"
        exit 1
    fi

    echo -e "\n${GREEN}已选定 ${#target_ips[@]} 个落地 IP 节点。${PLAIN}"

    read -r -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}

    if [ "$config_type" == "socks" ]; then
        read -r -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
        SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

        read -r -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
        SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
    elif [ "$config_type" == "vmess" ]; then
        read -r -p "UUID (默认随机: $DEFAULT_UUID): " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        read -r -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi

    local end_port=$((START_PORT + ${#target_ips[@]} - 1))

    # 获取主入口 IP
    local primary_v4
    primary_v4=$(get_primary_ipv4)
    local primary_v6
    primary_v6=$(get_primary_ipv6)

    # 加载域名配置（用于导出列表）
    local entry_domain=""
    load_ddns_config
    if [ -n "$CF_RECORD_NAME" ]; then
        entry_domain="$CF_RECORD_NAME"
        echo -e " DDNS 域名入口: ${GREEN}${entry_domain}${PLAIN} (导出列表将优先使用域名)"
    fi

    # 生成配置 TOML 文件 (关闭冗余日志，设置 warning 级别)
    local config_content=""
    config_content+="# XrayL Multi-IP Dual-Stack Inbound & Dedicated Outbound Configuration\n"
    config_content+="[log]\n"
    config_content+="loglevel = \"warning\"\n\n"

    # 清空导出列表
    > "${EXPORT_SOCKS_FILE}"
    > "${EXPORT_SOCKS_IPV4_FILE}"
    > "${EXPORT_SOCKS_IPV6_FILE}"
    > "${EXPORT_SOCKS_DIRECT_FILE}"
    > "${EXPORT_VMESS_FILE}"
    > "${EXPORT_DOMAIN_FILE}"

    for ((i = 0; i < ${#target_ips[@]}; i++)); do
        local egress_ip="${target_ips[i]}"
        local cur_port=$((START_PORT + i))
        local tag_name="tag_$((i + 1))"

        # 【入站】：全局双栈监听
        config_content+="[[inbounds]]\n"
        config_content+="port = ${cur_port}\n"
        config_content+="protocol = \"${config_type}\"\n"
        config_content+="tag = \"${tag_name}\"\n"
        config_content+="[inbounds.settings]\n"

        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"${SOCKS_USERNAME}\"\n"
            config_content+="pass = \"${SOCKS_PASSWORD}\"\n"

            # 1. 落地直连模式
            local formatted_egress
            formatted_egress=$(format_ip_for_uri "$egress_ip")
            echo "${formatted_egress}:${cur_port}:${SOCKS_USERNAME}:${SOCKS_PASSWORD}" >> "${EXPORT_SOCKS_DIRECT_FILE}"

            # 2. 主 IPv4 入口模式
            if [ -n "$primary_v4" ]; then
                echo "${primary_v4}:${cur_port}:${SOCKS_USERNAME}:${SOCKS_PASSWORD}" >> "${EXPORT_SOCKS_IPV4_FILE}"
            fi

            # 3. 主 IPv6 入口模式
            if [ -n "$primary_v6" ]; then
                echo "[${primary_v6}]:${cur_port}:${SOCKS_USERNAME}:${SOCKS_PASSWORD}" >> "${EXPORT_SOCKS_IPV6_FILE}"
            fi

            # 4. 域名入口模式
            if [ -n "$entry_domain" ]; then
                echo "${entry_domain}:${cur_port}:${SOCKS_USERNAME}:${SOCKS_PASSWORD}" >> "${EXPORT_DOMAIN_FILE}"
            fi

        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"${UUID}\"\n"
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"${WS_PATH}\"\n"

            if command -v base64 &>/dev/null; then
                local entry_ip="${entry_domain:-${primary_v4:-$egress_ip}}"
                local vmess_json="{\"v\":\"2\",\"ps\":\"MultiIP-Port${cur_port}-Out-${egress_ip}\",\"add\":\"${entry_ip}\",\"port\":\"${cur_port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${WS_PATH}\",\"tls\":\"\"}"
                local vmess_link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
                echo "$vmess_link" >> "${EXPORT_VMESS_FILE}"
            fi
        fi

        # 【出站】：指定 sendThrough 独立落地
        config_content+="\n[[outbounds]]\n"
        config_content+="sendThrough = \"${egress_ip}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"${tag_name}\"\n\n"

        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"${tag_name}\"\n"
        config_content+="outboundTag = \"${tag_name}\"\n\n"
    done

    # 写入主默认导出文件（域名优先）
    if [ "$config_type" == "socks" ]; then
        if [ -n "$entry_domain" ] && [ -s "${EXPORT_DOMAIN_FILE}" ]; then
            cp "${EXPORT_DOMAIN_FILE}" "${EXPORT_SOCKS_FILE}"
        elif [ -s "${EXPORT_SOCKS_IPV4_FILE}" ]; then
            cp "${EXPORT_SOCKS_IPV4_FILE}" "${EXPORT_SOCKS_FILE}"
        else
            cp "${EXPORT_SOCKS_DIRECT_FILE}" "${EXPORT_SOCKS_FILE}"
        fi
    fi

    # 写入配置文件
    echo -e "$config_content" > "${CONFIG_FILE}"

    # 放行双栈防火墙端口
    open_firewall "$START_PORT" "$end_port"

    # 重启并检查服务
    systemctl restart xrayL.service
    sleep 1

    if systemctl is-active --quiet xrayL.service; then
        info "XrayL 服务运行中！"
    else
        err "XrayL 服务启动失败，请使用 journalctl -u xrayL -e 排查原因。"
        exit 1
    fi

    # 输出配置与导出信息
    echo -e "\n${GREEN}======================== 配置生成成功 ========================${PLAIN}"
    if [ "$config_type" == "socks" ]; then
        echo -e " 协议类型: ${CYAN}原生标准 SOCKS5${PLAIN}"
    else
        echo -e " 协议类型: ${CYAN}VMess + WebSocket${PLAIN}"
    fi

    echo -e " 端口范围: ${CYAN}${START_PORT} ~ ${end_port}${PLAIN} (共 ${#target_ips[@]} 个独立出口节点)"
    if [ -n "$entry_domain" ]; then
        echo -e " 域名入口: ${GREEN}${entry_domain}${PLAIN} (DDNS 自动解析)"
    fi
    echo -e " 入口支持: ${GREEN}IPv4 (${primary_v4:-无}) / IPv6 (${primary_v6:-无}) 双栈全局监听${PLAIN}"
    echo -e " 出口规则: ${CYAN}每个端口独立对应一个落地 IP (sendThrough)${PLAIN}"

    if [ "$config_type" == "socks" ]; then
        echo -e " SOCKS 账号: ${CYAN}${SOCKS_USERNAME}${PLAIN}"
        echo -e " SOCKS 密码: ${CYAN}${SOCKS_PASSWORD}${PLAIN}"
        echo -e "--------------------------------------------------------------"
        echo -e " 📂 导出文件汇总 (格式: ${CYAN}IP:端口:账号:密码${PLAIN}):"
        echo -e "  1. 默认通用导出: ${YELLOW}${EXPORT_SOCKS_FILE}${PLAIN}"
        [ -n "$primary_v4" ] && echo -e "  2. 主 IPv4 入口列表: ${YELLOW}${EXPORT_SOCKS_IPV4_FILE}${PLAIN}"
        [ -n "$primary_v6" ] && echo -e "  3. 主 IPv6 入口列表: ${YELLOW}${EXPORT_SOCKS_IPV6_FILE}${PLAIN}"
        [ -n "$entry_domain" ] && echo -e "  ★. 域名入口列表: ${YELLOW}${EXPORT_DOMAIN_FILE}${PLAIN} (${CYAN}${entry_domain}${PLAIN})"
        echo -e "  4. 落地 IP 直连列表: ${YELLOW}${EXPORT_SOCKS_DIRECT_FILE}${PLAIN}"
        echo -e "--------------------------------------------------------------"
        echo -e " 节点预览 (前 5 个):"
        head -n 5 "${EXPORT_SOCKS_FILE}"
        if [ "${#target_ips[@]}" -gt 5 ]; then
            echo -e " ... (完整列表请查看 ${EXPORT_SOCKS_FILE})"
        fi
    elif [ "$config_type" == "vmess" ]; then
        echo -e " UUID: ${CYAN}${UUID}${PLAIN}"
        echo -e " WS 路径: ${CYAN}${WS_PATH}${PLAIN}"
        echo -e " 批量导出文件: ${YELLOW}${EXPORT_VMESS_FILE}${PLAIN}"
        echo -e "--------------------------------------------------------------"
        echo -e " 节点链接预览 (前 3 个):"
        head -n 3 "${EXPORT_VMESS_FILE}"
        if [ "${#target_ips[@]}" -gt 3 ]; then
            echo -e " ... (完整列表请查看 ${EXPORT_VMESS_FILE})"
        fi
    fi
    echo -e "${GREEN}==============================================================${PLAIN}\n"
}

# 9. 查看状态与控制
service_status() {
    if systemctl is-active --quiet xrayL.service 2>/dev/null; then
        echo -e "XrayL 状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "XrayL 状态: ${RED}已停止 (Inactive)${PLAIN}"
    fi
    systemctl --no-pager status xrayL.service || true
}

service_restart() {
    systemctl restart xrayL.service
    info "XrayL 服务已重启。"
    service_status
}

service_stop() {
    systemctl stop xrayL.service
    info "XrayL 服务已停止。"
}

uninstall_xray() {
    read -r -p "确定要彻底卸载 XrayL 吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl stop xrayL.service >/dev/null 2>&1
        systemctl disable xrayL.service >/dev/null 2>&1
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        rm -f "${BIN_PATH}"
        rm -f "${IPV6_BIND_SCRIPT}"
        rm -rf "${CONFIG_DIR}"
        info "XrayL 已彻底卸载清理完成。"
    else
        info "已取消卸载。"
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}   Xray 多 IP / 双栈入口与多出口代理一键部署管理    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 配置 SOCKS5 多 IP 代理 (IPv4+IPv6 双栈入口，端口分流落地)"
    echo -e "  ${GREEN}2.${PLAIN} 配置 VMess+WS 多 IP 代理 (双栈入口，批量生成 vmess:// 链接)"
    echo -e "  ${GREEN}3.${PLAIN} 批量生成并绑定 IPv6 子网地址 (如 /64 批量绑定 N 个 IP)"
    echo -e "  ${GREEN}4.${PLAIN} 启用/检测 Google BBR 网络加速"
    echo -e "  ${GREEN}5.${PLAIN} Cloudflare DDNS 配置与管理 (域名自动解析入口 IP)"
    echo -e "  ${GREEN}6.${PLAIN} 查看服务运行状态"
    echo -e "  ${GREEN}7.${PLAIN} 重启代理服务"
    echo -e "  ${GREEN}8.${PLAIN} 停止代理服务"
    echo -e "  ${GREEN}9.${PLAIN} 查看导出文件列表 (Proxies / IP:Port:User:Pass)"
    echo -e "  ${GREEN}10.${PLAIN} 彻底卸载 XrayL"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "${CYAN}====================================================${PLAIN}"
    read -r -p "请输入选项 [0-10]: " choice
    case "$choice" in
        1)
            [ -x "$BIN_PATH" ] || install_xray
            config_xray "socks"
            ;;
        2)
            [ -x "$BIN_PATH" ] || install_xray
            config_xray "vmess"
            ;;
        3)
            batch_generate_and_bind_ipv6
            ;;
        4)
            enable_bbr
            ;;
        5)
            setup_cloudflare_ddns
            ;;
        6)
            service_status
            ;;
        7)
            service_restart
            ;;
        8)
            service_stop
            ;;
        9)
            if [ -f "$EXPORT_SOCKS_FILE" ]; then
                echo -e "\n${GREEN}默认导出列表 (${EXPORT_SOCKS_FILE}):${PLAIN}"
                cat "$EXPORT_SOCKS_FILE"
            fi
            if [ -f "$EXPORT_DOMAIN_FILE" ] && [ -s "$EXPORT_DOMAIN_FILE" ]; then
                echo -e "\n${GREEN}域名入口列表 (${EXPORT_DOMAIN_FILE}):${PLAIN}"
                cat "$EXPORT_DOMAIN_FILE"
            fi
            if [ -f "$EXPORT_SOCKS_IPV4_FILE" ] && [ -s "$EXPORT_SOCKS_IPV4_FILE" ]; then
                echo -e "\n${GREEN}IPv4 入口列表 (${EXPORT_SOCKS_IPV4_FILE}):${PLAIN}"
                cat "$EXPORT_SOCKS_IPV4_FILE"
            fi
            if [ -f "$EXPORT_SOCKS_IPV6_FILE" ] && [ -s "$EXPORT_SOCKS_IPV6_FILE" ]; then
                echo -e "\n${GREEN}IPv6 入口列表 (${EXPORT_SOCKS_IPV6_FILE}):${PLAIN}"
                cat "$EXPORT_SOCKS_IPV6_FILE"
            fi
            if [ -f "$EXPORT_VMESS_FILE" ] && [ -s "$EXPORT_VMESS_FILE" ]; then
                echo -e "\n${GREEN}VMess 导出列表 (${EXPORT_VMESS_FILE}):${PLAIN}"
                cat "$EXPORT_VMESS_FILE"
            fi
            ;;
        10)
            uninstall_xray
            ;;
        0)
            exit 0
            ;;
        *)
            err "无效选项！"
            exit 1
            ;;
    esac
}

main() {
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前非 root 用户，建议使用 root 运行以确保服务配置和防火墙放行权限正常。"
    fi

    if [ $# -eq 0 ]; then
        show_menu
    else
        case "$1" in
            socks)
                [ -x "$BIN_PATH" ] || install_xray
                config_xray "socks" "$2"
                ;;
            vmess)
                [ -x "$BIN_PATH" ] || install_xray
                config_xray "vmess" "$2"
                ;;
            bbr)
                enable_bbr
                ;;
            ipv6|bind-ipv6)
                batch_generate_and_bind_ipv6
                ;;
            ddns)
                cloudflare_ddns
                ;;
            ddns-setup)
                setup_cloudflare_ddns
                ;;
            status)
                service_status
                ;;
            restart)
                service_restart
                ;;
            stop)
                service_stop
                ;;
            export)
                [ -f "$EXPORT_SOCKS_FILE" ] && cat "$EXPORT_SOCKS_FILE"
                [ -f "$EXPORT_DOMAIN_FILE" ] && [ -s "$EXPORT_DOMAIN_FILE" ] && cat "$EXPORT_DOMAIN_FILE"
                [ -f "$EXPORT_VMESS_FILE" ] && cat "$EXPORT_VMESS_FILE"
                ;;
            uninstall)
                uninstall_xray
                ;;
            help|-h|--help)
                echo "用法: $0 [socks|vmess|bbr|ipv6|ddns|ddns-setup|status|restart|stop|export|uninstall] [v4|v6|dual]"
                ;;
            *)
                err "未知参数: $1"
                echo "用法: $0 [socks|vmess|bbr|ipv6|ddns|ddns-setup|status|restart|stop|export|uninstall] [v4|v6|dual]"
                exit 1
                ;;
        esac
    fi
}

main "$@"
