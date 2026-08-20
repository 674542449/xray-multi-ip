# Xray Multi-IP 一键批量代理部署脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Xray-core](https://img.shields.io/badge/Core-Xray--core-red.svg)](https://github.com/XTLS/Xray-core)

专为**多 IP / 站群 VPS 服务器**打造的 Xray 批量代理自动化部署与管理脚本。支持一键将服务器绑定的所有 IP 批量映射为独立的入站/出站代理节点，实现“进出 IP 一致”与“单机多 IP 独享出口”，广泛适用于跨境电商多店铺防关联、爬虫 IP 池、海外社媒矩阵管理与多出口代理场景。

---

## ✨ 核心优化与改进特性

相比原版脚本，本项目进行了深度加固与工程化优化：

1. **🛡️ 防火墙端口自动放行**
   - 自动识别系统防火墙（`UFW`、`Firewalld`、`iptables`）。
   - 根据 IP 数量自动计算端口范围（例如 `20000:20050`）并一键批量放行 TCP/UDP 规则。

2. **📦 完备的系统依赖自适应**
   - 全面兼容 `Debian`、`Ubuntu`、`CentOS`、`RHEL`、`AlmaLinux`、`Rocky Linux`、`Alpine` 与 `Arch Linux`。
   - 自动检测并补齐 `curl`、`wget`、`unzip`、`iproute2` 等基础工具。

3. **🧹 0 残留临时文件管理**
   - 采用 `mktemp -d` 安全隔离目录与 Bash `trap` 信号捕获机制。
   - 无论安装成功还是中途 `Ctrl+C` 异常终止，均自动彻底清理解压垃圾与临时安装包。

4. **⚡ 高并发与文件描述符调优**
   - Systemd 服务内置 `LimitNOFILE=65535`、`LimitNPROC=65535` 及 `LimitCORE=infinity`。
   - 彻底解决大并发请求下由于 `1024` 句柄上限导致的 `too many open files` 丢包与断连问题。

5. **🔇 日志级别优化与防爆盘**
   - 默认开启 `[log] loglevel = "warning"`。
   - 屏蔽海量正常连接/握手日志，防止高频代理流量迅速写爆 VPS 磁盘。

6. **📋 节点批量导出（开箱即用）**
   - SOCKS 模式自动导出为工业标准格式：
     ```text
     IP:端口:账号:密码
     ```
   - 默认保存在 `/root/xray_proxies.txt`，可直接一键复制导入至 **指纹浏览器（AdsPower/Hubstudio/BitBrowser）**、**爬虫 IP 池框架** 或代理管理工具中。
   - VMess 模式自动导出 `vmess://` 分享链接列表（`/root/xray_vmess.txt`）。

7. **🚀 架构自适应与精准 IP 识别**
   - 自动识别 `x86_64` (amd64) 与 `aarch64` (ARM64 / 甲骨文 ARM / AWS Graviton) 架构并下载匹配核心。
   - 智能过滤 `127.0.0.1`、Docker 虚拟网卡及私有内网 IP，确保公网出口精准绑定。

---

## 🚀 一键安装与运行

### 1. 交互式菜单模式（推荐新手）
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```
或使用 `wget`：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh)
```

### 2. SOCKS5 模式快速一键部署
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) socks
```

### 3. VMess+WS 模式快速一键部署
```bash
bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) vmess
```

---

## 🛠️ 便捷管理命令

安装后可随时通过命令行进行快捷控制：

| 命令 | 说明 |
| :--- | :--- |
| `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) status` | 查看 XrayL 服务运行状态 |
| `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) restart` | 重启代理服务 |
| `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) stop` | 停止代理服务 |
| `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) export` | 查看并打印已导出的代理节点列表 |
| `bash <(curl -fsSLk https://raw.githubusercontent.com/674542449/xray-multi-ip/main/xrayL.sh) uninstall` | 彻底卸载 XrayL 并清理所有配置文件 |

---

## 📂 文件与路径说明

- **主执行文件**：`/usr/local/bin/xrayL`
- **TOML 配置文件**：`/etc/xrayL/config.toml`
- **Systemd 服务文件**：`/etc/systemd/system/xrayL.service`
- **SOCKS 导出列表**：`/root/xray_proxies.txt`
- **VMess 导出列表**：`/root/xray_vmess.txt`

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。
