#!/usr/bin/env bash
# ==============================================================================
# Script Name: xrayL.sh (Multi-IP Xray Proxy Deployment Script)
# Author: Improved based on bulianglin/demo
# Description: Automatically deploy multi-IP multi-inbound/outbound Xray proxies
# Repository: https://github.com/674542449/xray-multi-ip
# ==============================================================================

set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 核心路径与默认变量
CONFIG_DIR="/etc/xrayL"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/xrayL.service"
BIN_PATH="/usr/local/bin/xrayL"

# 导出文件路径
if [ -w "/root" ]; then
    EXPORT_SOCKS_FILE="/root/xray_proxies.txt"
    EXPORT_VMESS_FILE="/root/xray_vmess.txt"
else
    EXPORT_SOCKS_FILE="${HOME}/xray_proxies.txt"
    EXPORT_VMESS_FILE="${HOME}/xray_vmess.txt"
fi

DEFAULT_START_PORT=20000
DEFAULT_SOCKS_USERNAME="userb"
DEFAULT_SOCKS_PASSWORD="passwordb"
DEFAULT_WS_PATH="/ws"

# 生成默认 UUID（兼容未开启 /proc/sys/kernel/random/uuid 的系统）
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

# 2. 完备的依赖检查与安装
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
            apt-get update -y && apt-get install -y wget curl unzip iproute2
        elif command -v yum &>/dev/null; then
            yum install -y wget curl unzip iproute
        elif command -v dnf &>/dev/null; then
            dnf install -y wget curl unzip iproute
        elif command -v apk &>/dev/null; then
            apk add --no-cache wget curl unzip iproute2
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm wget curl unzip iproute2
        else
            warn "未能识别包管理器，请确保已手动安装: ${need_install[*]}"
        fi
    else
        info "所有基础依赖均已就绪。"
    fi
}

# 3. 自动放行防火墙端口
open_firewall() {
    local start_port=$1
    local end_port=$2
    info "正在放行防火墙端口: ${start_port} ~ ${end_port} (TCP/UDP)..."

    # UFW 防火墙
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        ufw allow "${start_port}:${end_port}/tcp" >/dev/null 2>&1
        ufw allow "${start_port}:${end_port}/udp" >/dev/null 2>&1
        info "UFW 端口规则已放行。"
    fi

    # Firewalld 防火墙
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${start_port}-${end_port}/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="${start_port}-${end_port}/udp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "Firewalld 端口规则已放行并重载。"
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
        iptables -C INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p udp --dport "${start_port}:${end_port}" -j ACCEPT >/dev/null 2>&1
    fi
}

# 4. 获取服务器所有有效 IP 地址（智能过滤）
get_ip_addresses() {
    local ips=()

    # 优先使用 ip 命令提取公网 IPv4
    if command -v ip &>/dev/null; then
        while IFS= read -r ip_found; do
            [ -n "$ip_found" ] && ips+=("$ip_found")
        done < <(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.|0\.)' || true)
    fi

    # 若未找到公网 IP（例如 NAT 架构 VPS），则回退获取所有本地有效 IPv4（排除 127.0.0.1）
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

    # 去重
    local unique_ips=()
    for item in "${ips[@]}"; do
        local duplicate=0
        for u in "${unique_ips[@]}"; do
            if [ "$item" == "$u" ]; then
                duplicate=1
                break
            fi
        done
        [ $duplicate -eq 0 ] && unique_ips+=("$item")
    done

    echo "${unique_ips[@]}"
}

# 5. 安装 Xray 内核与 Systemd 服务（增加文件描述符与并发限制）
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

    info "配置 Systemd 守护服务（已优化文件描述符限制与高并发参数）..."
    cat <<EOF >"${SERVICE_FILE}"
[Unit]
Description=XrayL Multi-IP Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
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

# 6. 配置生成与批量导出
config_xray() {
    local config_type="$1"
    mkdir -p "${CONFIG_DIR}"

    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        err "类型错误！仅支持 socks 和 vmess。"
        exit 1
    fi

    local ip_list=($(get_ip_addresses))
    if [ ${#ip_list[@]} -eq 0 ]; then
        err "未能检测到有效 IP 地址，请检查服务器网络！"
        exit 1
    fi

    echo -e "\n${CYAN}======================== 检测到的 IP 列表 ========================${PLAIN}"
    for idx in "${!ip_list[@]}"; do
        echo -e " [${idx}] ${ip_list[idx]}"
    done
    echo -e "${CYAN}共检测到 ${#ip_list[@]} 个 IP 地址。${PLAIN}"
    echo -e "${CYAN}==================================================================${PLAIN}\n"

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

    local end_port=$((START_PORT + ${#ip_list[@]} - 1))

    # 生成配置 TOML 文件 (关闭冗余日志，设置 warning 级别)
    local config_content=""
    config_content+="# XrayL Multi-IP Configuration\n"
    config_content+="[log]\n"
    config_content+="loglevel = \"warning\"\n\n"

    # 清空导出列表
    if [ "$config_type" == "socks" ]; then
        > "${EXPORT_SOCKS_FILE}"
    elif [ "$config_type" == "vmess" ]; then
        > "${EXPORT_VMESS_FILE}"
    fi

    for ((i = 0; i < ${#ip_list[@]}; i++)); do
        local cur_ip="${ip_list[i]}"
        local cur_port=$((START_PORT + i))
        local tag_name="tag_$((i + 1))"

        config_content+="[[inbounds]]\n"
        config_content+="port = ${cur_port}\n"
        config_content+="protocol = \"${config_type}\"\n"
        config_content+="tag = \"${tag_name}\"\n"
        config_content+="[inbounds.settings]\n"

        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="ip = \"${cur_ip}\"\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"${SOCKS_USERNAME}\"\n"
            config_content+="pass = \"${SOCKS_PASSWORD}\"\n"

            # 导出 IP:端口:账号:密码
            echo "${cur_ip}:${cur_port}:${SOCKS_USERNAME}:${SOCKS_PASSWORD}" >> "${EXPORT_SOCKS_FILE}"
        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"${UUID}\"\n"
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"${WS_PATH}\"\n"

            # 生成 VMess 链接导出
            if command -v base64 &>/dev/null; then
                local vmess_json="{\"v\":\"2\",\"ps\":\"MultiIP-${cur_ip}-${cur_port}\",\"add\":\"${cur_ip}\",\"port\":\"${cur_port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${WS_PATH}\",\"tls\":\"\"}"
                local vmess_link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
                echo "$vmess_link" >> "${EXPORT_VMESS_FILE}"
            fi
        fi

        config_content+="\n[[outbounds]]\n"
        config_content+="sendThrough = \"${cur_ip}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"${tag_name}\"\n\n"

        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"${tag_name}\"\n"
        config_content+="outboundTag = \"${tag_name}\"\n\n"
    done

    # 写入配置文件
    echo -e "$config_content" > "${CONFIG_FILE}"

    # 放行防火墙端口
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
    echo -e " 协议类型: ${CYAN}${config_type}${PLAIN}"
    echo -e " 端口范围: ${CYAN}${START_PORT} ~ ${end_port}${PLAIN} (共 ${#ip_list[@]} 个节点)"
    if [ "$config_type" == "socks" ]; then
        echo -e " SOCKS 账号: ${CYAN}${SOCKS_USERNAME}${PLAIN}"
        echo -e " SOCKS 密码: ${CYAN}${SOCKS_PASSWORD}${PLAIN}"
        echo -e " 批量导出文件: ${YELLOW}${EXPORT_SOCKS_FILE}${PLAIN}"
        echo -e " 导出格式: ${CYAN}IP:端口:账号:密码${PLAIN}"
        echo -e "--------------------------------------------------------------"
        echo -e " 节点预览 (前 5 个):"
        head -n 5 "${EXPORT_SOCKS_FILE}"
        if [ "${#ip_list[@]}" -gt 5 ]; then
            echo -e " ... (更多请查看 ${EXPORT_SOCKS_FILE})"
        fi
    elif [ "$config_type" == "vmess" ]; then
        echo -e " UUID: ${CYAN}${UUID}${PLAIN}"
        echo -e " WS 路径: ${CYAN}${WS_PATH}${PLAIN}"
        echo -e " 批量导出文件: ${YELLOW}${EXPORT_VMESS_FILE}${PLAIN}"
        echo -e "--------------------------------------------------------------"
        echo -e " 节点链接预览 (前 3 个):"
        head -n 3 "${EXPORT_VMESS_FILE}"
        if [ "${#ip_list[@]}" -gt 3 ]; then
            echo -e " ... (更多请查看 ${EXPORT_VMESS_FILE})"
        fi
    fi
    echo -e "${GREEN}==============================================================${PLAIN}\n"
}

# 7. 查看状态与控制
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
        rm -rf "${CONFIG_DIR}"
        info "XrayL 已彻底卸载清理完成。"
    else
        info "已取消卸载。"
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}       Xray 多 IP / 多出口代理一键部署管理脚本      ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 配置 SOCKS5 多 IP 代理 (批量生成 IP:端口:账号:密码)"
    echo -e "  ${GREEN}2.${PLAIN} 配置 VMess+WS 多 IP 代理 (批量生成 vmess:// 链接)"
    echo -e "  ${GREEN}3.${PLAIN} 查看服务运行状态"
    echo -e "  ${GREEN}4.${PLAIN} 重启代理服务"
    echo -e "  ${GREEN}5.${PLAIN} 停止代理服务"
    echo -e "  ${GREEN}6.${PLAIN} 查看导出文件列表 (Proxies)"
    echo -e "  ${GREEN}7.${PLAIN} 彻底卸载 XrayL"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "${CYAN}====================================================${PLAIN}"
    read -r -p "请输入选项 [0-7]: " choice
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
            service_status
            ;;
        4)
            service_restart
            ;;
        5)
            service_stop
            ;;
        6)
            if [ -f "$EXPORT_SOCKS_FILE" ]; then
                echo -e "\n${GREEN}SOCKS5 导出列表 (${EXPORT_SOCKS_FILE}):${PLAIN}"
                cat "$EXPORT_SOCKS_FILE"
            fi
            if [ -f "$EXPORT_VMESS_FILE" ]; then
                echo -e "\n${GREEN}VMess 导出列表 (${EXPORT_VMESS_FILE}):${PLAIN}"
                cat "$EXPORT_VMESS_FILE"
            fi
            if [ ! -f "$EXPORT_SOCKS_FILE" ] && [ ! -f "$EXPORT_VMESS_FILE" ]; then
                warn "未找到已导出的代理列表文件。"
            fi
            ;;
        7)
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
                config_xray "socks"
                ;;
            vmess)
                [ -x "$BIN_PATH" ] || install_xray
                config_xray "vmess"
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
                [ -f "$EXPORT_VMESS_FILE" ] && cat "$EXPORT_VMESS_FILE"
                ;;
            uninstall)
                uninstall_xray
                ;;
            help|-h|--help)
                echo "用法: $0 [socks|vmess|status|restart|stop|export|uninstall]"
                ;;
            *)
                err "未知参数: $1"
                echo "用法: $0 [socks|vmess|status|restart|stop|export|uninstall]"
                exit 1
                ;;
        esac
    fi
}

main "$@"
