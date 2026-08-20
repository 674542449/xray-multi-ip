# Xray Multi-IP & Dual-Stack 一键批量代理部署脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Xray-core](https://img.shields.io/badge/Core-Xray--core-red.svg)](https://github.com/XTLS/Xray-core)
[![SOCKS5 over TLS](https://img.shields.io/badge/TLS-SOCKS5%20over%20TLS-blue.svg)](#)
[![IPv6 Subnet](https://img.shields.io/badge/IPv6%20Subnet-%2F64%20Auto--Binding-orange.svg)](#)

专为**多 IP / 站群 VPS 服务器**打造的 Xray 批量代理自动化部署与管理脚本。
支持 **SOCKS5 over TLS（标准 TLS 加密防封）与纯明文 SOCKS5 二选一**、**IPv4 + IPv6 双栈全局入口**、**IPv6 子网（/64、/56 等）批量生成与开机持久化绑定**，并通过**端口映射精确区分各落地出口 IP**。

广泛适用于跨境电商多店铺防关联、手机端安全直连、爬虫 IP 池矩阵、海外社媒自动化及多出口代理网络。

---

## 🌐 架构与工作模式

```
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20000 端口   │
 [支持 TLS 加密]     │     (全局双栈监听)      │ ──► [落地出口 IP 1 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20000 端口   │
                    └─────────────────────────┘
                    ┌─────────────────────────┐
[客户端 IPv4 访问] ───►  主 IPv4 : 20001 端口   │
 [支持 TLS 加密]     │     (全局双栈监听)      │ ──► [落地出口 IP 2 (IPv4 / IPv6)]
[客户端 IPv6 访问] ───► [主 IPv6]: 20001 端口   │
                    └─────────────────────────┘
```

- **SOCKS5 over TLS 加密防封**：使用标准 TLS 加密伪装流量，彻底解决大陆网络环境下原生 SOCKS5 容易被 DPI 识别阻断和主动探测的问题，手机端（Shadowrocket / Sing-box / Loon 等）可直接导入安全使用。
- **纯明文 SOCKS5 兼容**：保留原生明文 SOCKS5 选项，满足内网穿透、专线链路及特定爬虫池框架的无加密直连需求。
- **双栈入口通用**：无论客户端处于纯 IPv4、纯 IPv6 还是双栈环境，均可任意连接服务器。
- **端口即落地**：访问不同端口（`20000`, `20001`, `20002`...），流量自动通过底层 `sendThrough` 路由至绑定的独立落地 IP 发出。
- **IPv6 子网自动扩展**：自动从 VPS 的 `/64` 或 `/56` 前缀中生成海量随机 IPv6 并绑定到网卡，配置开机自动重新绑定。

---

## ✨ 核心优化与特性

1. **🔒 SOCKS5 over TLS (TLS 加密二选一)**
   - 自动生成高强度自签名证书（有效期 10 年），开箱即用。
   - 手机端（如 Shadowrocket 小火箭）可直接导入 `socks://` 一键链接，打开 TLS 并跳过证书校验即可安全直连。
2. **🌐 IPv6 子网（/64 等）自动批量生成与开机绑定**
   - 自动探测网卡与 IPv6 CIDR 网段，一键批量生成随机 Hex 后缀（防封）或递增后缀的 IPv6 出口，开机自启自动重新绑定。
3. **🌐 IPv4 / IPv6 双栈全特性支持**
   - 自动检测所有 IPv4 与公网 IPv6，支持自由选择纯 v4、纯 v6 或双栈混合落地。
4. **🛡️ 双栈防火墙端口自动放行**
   - 自动识别并配置 `UFW`、`Firewalld`、`iptables` 与 `ip6tables`。
5. **📋 多维度节点批量导出**
   - `xray_proxies.txt`：标准列表（`IP:端口:账号:密码`）。
   - `xray_socks_tls_links.txt`：SOCKS over TLS 客户端直连一键导入链接。
   - `xray_proxies_ipv4_entry.txt`：主 IPv4 统一入口列表。
   - `xray_proxies_ipv6_entry.txt`：主 IPv6 统一入口列表。
   - `xray_proxies_direct.txt`：落地 IP 直连列表。
   - `xray_vmess.txt`：VMess 分享链接列表。
6. **⚡ 高并发优化与防爆盘**
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

- **部署 SOCKS5 over TLS（TLS 加密模式，手机/大陆直连推荐）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks-tls
  ```
- **部署 纯明文 SOCKS5（原生标准协议）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks-plain
  ```
- **批量生成并绑定 IPv6 子网（/64 等）**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) ipv6
  ```
- **部署 VMess+WS 模式**：
  ```bash
  bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) vmess
  ```

---

## 📱 手机端使用 SOCKS5 over TLS 说明

若使用 **SOCKS5 over TLS** 模式：
1. 运行结束后，脚本会生成 `xray_socks_tls_links.txt` 文件；
2. **iOS（Shadowrocket 小火箭）**：
   - 直接复制文件内的 `socks://...` 链接，打开小火箭即可自动识别并添加；
   - 手动配置时：类型选 `Socks5`，填写 IP、端口、账号、密码，**开启 TLS**，并勾选 **“允许不安全 / 跳过证书验证”**。
3. **Android（v2rayNG / Sing-box / Clash Meta）**：
   - 导入链接或在 SOCKS 配置中开启 `TLS` 选项。

---

## 🛠️ 便捷管理命令

| 操作 | 命令 |
| :--- | :--- |
| **打开交互式主菜单** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)` |
| **查看服务运行状态** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) status` |
| **查看已导出的所有节点/链接** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) export` |
| **重启代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) restart` |
| **停止代理服务** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) stop` |
| **彻底卸载与数据清理** | `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) uninstall` |

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。
