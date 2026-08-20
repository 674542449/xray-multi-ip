# Xray Multi-IP & Dual-Stack 一键批量代理部署脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Xray-core](https://img.shields.io/badge/Core-Xray--core-red.svg)](https://github.com/XTLS/Xray-core)
[![IPv6 Subnet](https://img.shields.io/badge/IPv6%20Subnet-%2F64%20Auto--Binding-orange.svg)](#)

专为**多 IP / 站群 VPS 服务器**打造的 Xray 批量代理自动化部署与管理脚本。
支持 **IPv4 + IPv6 双栈全局入口接入**、**IPv6 子网（/64、/56 等）批量生成与开机持久化绑定**，并通过**端口映射精确区分各落地出口 IP**，实现单机多 IP 独享出口与跨网段灵活调度。

广泛适用于跨境电商多店铺防关联、爬虫 IP 池矩阵、海外社媒自动化及多出口代理网络。

---

## 🌐 架构与工作模式

```
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20000 端口   │
                    │        (全局监听)       │ ──► [落地出口 IP 1 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20000 端口   │
                    └─────────────────────────┘
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20001 端口   │
                    │        (全局监听)       │ ──► [落地出口 IP 2 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20001 端口   │
                    └─────────────────────────┘
```

- **双栈入口通用**：无论本地客户端处于纯 IPv4、纯 IPv6 还是双栈网络环境，均可任意连接服务器的 IPv4 或 IPv6 地址。
- **端口即落地**：访问不同端口（`20000`, `20001`, `20002`...），流量自动通过底层 `sendThrough` 路由至绑定的独立落地 IP 发出。
- **IPv6 子网自动扩展**：自动从 VPS 的 `/64` 或 `/56` 前缀中生成海量随机 IPv6（如 50、100、500 个）并绑定到网卡，同时配置开机自动重新绑定。

---

## ✨ 核心优化与特性

1. **🌐 IPv6 子网（/64 等）自动批量生成与开机绑定**
   - 自动探测服务器默认网卡与 IPv6 CIDR 网段（如 `2400:8902:xxxx:xxxx::/64`）。
   - 一键输入需要的 IP 数量（例如 50、100、200），支持**随机 Hex 后缀（防封）**或**顺序后缀**。
   - 自动绑定至网卡，并注入 Systemd `ExecStartPre` 实现**服务器重启自动重新绑定**，无需担心 IP 丢失。

2. **🌐 IPv4 / IPv6 双栈全特性支持**
   - 自动检测服务器上的所有 IPv4 与公网 IPv6 地址。
   - 支持自由选择：`仅使用 IPv4 落地`、`仅使用 IPv6 落地` 或 `IPv4 + IPv6 混合落地`。
   - IPv6 导出自动适配标准方括号 `[IPv6]:端口:账号:密码`。

3. **🛡️ 双栈防火墙端口自动放行**
   - 自动识别并配置 `UFW`、`Firewalld`、`iptables` 与 `ip6tables`。
   - 自动按端口范围（如 `20000:20050`）同步放行 IPv4 和 IPv6 的 TCP/UDP 流量。

4. **📋 多维度节点批量导出**
   脚本运行后自动在 `/root/` 生成以下标准格式导出文件：
   - `xray_proxies.txt`：默认推荐通用列表（`IP:端口:账号:密码`）。
   - `xray_proxies_ipv4_entry.txt`：**以主 IPv4 为统一入口**的各落地节点列表。
   - `xray_proxies_ipv6_entry.txt`：**以主 IPv6 为统一入口**的各落地节点列表。
   - `xray_proxies_direct.txt`：以各落地 IP 本身为入口的直连节点列表。
   - `xray_vmess.txt`：VMess 模式下的 `vmess://` 分享链接列表。

5. **⚡ 高并发与文件描述符调优**
   - Systemd 服务注入 `LimitNOFILE=65535`、`LimitNPROC=65535` 及 `LimitCORE=infinity`，解决高并发爬虫与代理下的 `too many open files` 断流问题。

6. **🔇 日志级别优化与防爆盘**
   - 默认启用 `[log] loglevel = "warning"`，屏蔽正常请求日志，防止磁盘被刷满。

7. **🧹 0 残留临时文件管理**
   - 基于 `mktemp -d` 与 Bash `trap` 捕获机制，无论安装成功或中途异常终止均自动清理安装垃圾。

8. **📦 全平台包管理与架构自适应**
   - 兼容 Debian / Ubuntu / CentOS / RHEL / Alma / Rocky / Alpine / Arch。
   - 支持 `x86_64` (amd64) 与 `aarch64` (ARM64 / 甲骨文 ARM / AWS Graviton)。

---

## 🚀 一键安装与使用

### 1. 交互式菜单模式（推荐新手）
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```
或使用 `wget`：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```

### 2. 独立运行：批量生成并绑定 IPv6 子网地址
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ipv6
```

### 3. SOCKS5 模式快速一键部署
```bash
# 默认配置（IPv4+IPv6 全部混合落地，支持中途批量生成 /64 IPv6）
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks

# 或指定仅使用 IPv4 落地
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks v4

# 或指定仅使用 IPv6 落地
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks v6
```

### 4. VMess+WS 模式快速一键部署
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) vmess
```

---

## 🛠️ 便捷管理命令

| 操作 | 命令 |
| :--- | :--- |
| **打开交互式主菜单** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)` |
| **批量生成/绑定 IPv6** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ipv6` |
| **查看服务运行状态** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) status` |
| **查看所有已导出的节点列表** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) export` |
| **重启代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) restart` |
| **停止代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) stop` |
| **彻底卸载与数据清理** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) uninstall` |

---

## 📂 文件与路径说明

- **执行核心**：`/usr/local/bin/xrayL`
- **IPv6 开机自动绑定脚本**：`/usr/local/bin/xrayL-bind-ipv6`
- **已绑定的 IPv6 列表**：`/etc/xrayL/ipv6_custom.list`
- **TOML 配置文件**：`/etc/xrayL/config.toml`
- **Systemd 守护服务**：`/etc/systemd/system/xrayL.service`
- **通用节点导出**：`/root/xray_proxies.txt`
- **IPv4 入口列表**：`/root/xray_proxies_ipv4_entry.txt`
- **IPv6 入口列表**：`/root/xray_proxies_ipv6_entry.txt`
- **落地直连列表**：`/root/xray_proxies_direct.txt`
- **VMess 导出列表**：`/root/xray_vmess.txt`

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。
