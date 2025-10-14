# 🚀 sing-box-vps 一键部署与管理脚本

![GitHub repo size](https://img.shields.io/github/repo-size/hansvlss/sing-box-vps?color=blue)
![GitHub last commit](https://img.shields.io/github/last-commit/hansvlss/sing-box-vps?color=brightgreen)
![GitHub license](https://img.shields.io/github/license/hansvlss/sing-box-vps)
![GitHub stars](https://img.shields.io/github/stars/hansvlss/sing-box-vps?style=social)

> 🔹 作者：**Hans**  
> 🔹 系统支持：**Debian / Ubuntu / CentOS**  
> 🔹 脚本用途：快速在 VPS 上部署 **sing-box 节点服务**，并可选安装 **Web 面板** 实时监控资源、证书与流量。

---

## 🧭 项目简介

**sing-box-vps** 是一个用于 VPS 环境的自动化安装与管理脚本集合，帮助你：

- 🧩 快速部署 **sing-box 4in1 节点服务**（支持 VLESS / VMESS / Trojan / Hysteria2）
- 🔐 自动申请与续期 **Let's Encrypt TLS 证书**
- ⚙️ 支持一键启动、重启、开机自启 **systemd 服务**
- 📊 可选安装 **Web 可视化面板**（实时显示 CPU、内存、磁盘、带宽、证书信息等）
- 🪶 纯 Bash 编写，无任何依赖语言，完全本地执行

---

## ⚡️ 一键安装脚本

### 🧠 方式一：安装 sing-box 节点（主程序）

```
bash <(curl -fsSL https://raw.githubusercontent.com/hansvlss/sing-box-vps/main/singbox-4in1.sh)

```
### 🖥️ 方式二：安装 Web 面板（可选）

```
bash <(curl -fsSL https://raw.githubusercontent.com/hansvlss/sing-box-vps/main/sb-panel.sh)

```
面板功能包括：
	•	📈 实时监控：CPU / 内存 / 磁盘 / 网络速率 / 流量统计
	•	🔐 展示 TLS 证书信息（颁发者、到期时间、签名算法等）
	•	🛰️ 查看监听端口状态
	•	📋 一键复制节点订阅信息（VLESS / VMESS / Trojan / Hysteria2）
	•	♻️ 自带自动刷新与无缓存优化
