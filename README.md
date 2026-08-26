# Xray Multi-IP & Dual-Stack 一键批量代理部署脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Xray-core](https://img.shields.io/badge/Core-Xray--core-red.svg)](https://github.com/XTLS/Xray-core)
[![BBR Enabled](https://img.shields.io/badge/BBR-Auto--Accelerated-brightgreen.svg)](#)
[![IPv6 Subnet](https://img.shields.io/badge/IPv6%20Subnet-%2F64%20Auto--Binding-orange.svg)](#)
[![Cloudflare DDNS](https://img.shields.io/badge/DDNS-Cloudflare%20Auto--Sync-blue.svg)](#)

专为**多 IP / 站群 VPS 服务器**打造的 Xray 批量代理自动化部署与管理脚本。
支持 **原生标准 SOCKS5 与 VMess+WS**、**全自动 Google BBR 内核加速**、**Cloudflare DDNS 域名自动解析**、**IPv4 + IPv6 双栈全局入口**、**IPv6 子网（/64、/56 等）批量生成与开机持久化绑定**，并通过**端口映射精确区分各落地出口 IP**。

广泛适用于跨境电商多店铺防关联、爬虫 IP 池矩阵、海外社媒自动化及多出口代理网络。

---

## 🌐 架构与工作模式

```
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20000 端口   │
                    │     (全局双栈监听)      │ ──► [落地出口 IP 1 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20000 端口   │
                    └─────────────────────────┘
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20001 端口   │
                    │     (全局双栈监听)      │ ──► [落地出口 IP 2 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20001 端口   │
                    └─────────────────────────┘
```

- **全自动 BBR 内核加速**：安装或配置时自动检测并激活 Google BBR 拥塞控制算法与 TCP 窗口调优，抗国际丢包，极速跑满 VPS 带宽。
- **双栈入口通用**：无论客户端处于纯 IPv4、纯 IPv6 还是双栈环境，均可任意连接服务器。
- **端口即落地**：访问不同端口（`20000`, `20001`, `20002`...），流量自动通过底层 `sendThrough` 路由至绑定的独立落地 IP 发出。
- **IPv6 子网自动扩展**：自动从 VPS 的 `/64` 或 `/56` 前缀中生成海量随机 IPv6 并绑定到网卡，配置开机自动重新绑定。

---

## ✨ 核心优化与特性

1. **⚡ 全自动 Google BBR 拥塞控制调优**
   - 脚本安装或配置代理时，**自动检测并写入 BBR 加速参数**（`fq + bbr` + TCP 快速打开 + 缓冲区调优），无需手动输入复杂命令。
2. **🌐 IPv6 子网（/64 等）自动批量生成与开机绑定**
   - 自动探测网卡与 IPv6 CIDR 网段，一键批量生成随机 Hex 后缀（防封）或递增后缀的 IPv6 出口，开机自启自动重新绑定。
3. **🌐 IPv4 / IPv6 双栈全特性支持**
   - 自动检测所有 IPv4 与公网 IPv6，支持自由选择纯 v4、纯 v6 或双栈混合落地。
4. **🛡️ 双栈防火墙端口自动放行**
   - 自动识别并配置 `UFW`、`Firewalld`、`iptables` 与 `ip6tables`。
5. **📋 多维度节点批量导出**
   - `xray_proxies.txt`：标准列表（`IP:端口:账号:密码`）。
   - `xray_proxies_ipv4_entry.txt`：主 IPv4 统一入口列表。
   - `xray_proxies_ipv6_entry.txt`：主 IPv6 统一入口列表。
   - `xray_proxies_domain_entry.txt`：域名入口列表（配置 DDNS 后自动生成）。
   - `xray_proxies_direct.txt`：落地 IP 直连列表。
   - `xray_vmess.txt`：VMess 分享链接列表。
6. **🔄 Cloudflare DDNS 域名自动解析**
   - 集成 Cloudflare API，入口 IP 变化时**自动更新 DNS A/AAAA 记录**，每 1 分钟检测一次。配置域名后，代理导出列表自动使用域名替代 IP，客户端无需重新配置。
7. **⚡ 高并发优化与防爆盘**
   - `LimitNOFILE=65535` 句柄调优 + `[log] loglevel = "warning"` 屏蔽冗余日志。

---

## 🚀 一键安装与使用

### 1. 交互式菜单模式（推荐）
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```
或使用 `wget`：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```

### 2. 快捷一键模式

- **部署 原生标准 SOCKS5 代理（自动开启 BBR 加速）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks
  ```
- **部署 VMess+WS 模式（自动开启 BBR 加速）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) vmess
  ```
- **单独检测并开启 BBR 网络加速**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) bbr
  ```
- **批量生成并绑定 IPv6 子网（/64 等）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ipv6
  ```
- **配置 Cloudflare DDNS（域名自动解析入口 IP）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ddns-setup
  ```
- **手动触发一次 DDNS 更新**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ddns
  ```

---

## 🛠️ 便捷管理命令

| 操作 | 命令 |
| :--- | :--- |
| **打开交互式主菜单** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)` |
| **检测/开启 BBR 加速** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) bbr` |
| **配置 Cloudflare DDNS** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ddns-setup` |
| **手动触发 DDNS 更新** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ddns` |
| **查看服务运行状态** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) status` |
| **查看已导出的所有节点/链接** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) export` |
| **重启代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) restart` |
| **停止代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) stop` |
| **彻底卸载与数据清理** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) uninstall` |

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。
