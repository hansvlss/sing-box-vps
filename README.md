# 🚀 Sing-box VPS 一键四协议部署与可视化管理脚本（VPS 专用）

![GitHub repo size](https://img.shields.io/github/repo-size/hansvlss/sing-box-vps?color=blue)
![GitHub last commit](https://img.shields.io/github/last-commit/hansvlss/sing-box-vps?color=brightgreen)
![GitHub license](https://img.shields.io/github/license/hansvlss/sing-box-vps)
![GitHub stars](https://img.shields.io/github/stars/hansvlss/sing-box-vps?style=social)

> 🔹 作者：**Hans**  
> 🔹 系统支持：**Debian / Ubuntu / CentOS**  
> 🔹 脚本用途：快速在 VPS 上部署 **sing-box 节点服务**，并可选安装 **Web 面板** 实时监控资源、证书与流量。

---

## 一、项目简介

本项目提供 **一键四协议节点部署** 与 **Web 管理面板安装** 两大核心功能。  
支持在 **Debian / Ubuntu / CentOS / IPv4 / IPv6 / 双栈 VPS** 上快速搭建 sing-box 服务端，  
自动签发 HTTPS 证书，生成订阅链接，并支持网页端实时监控 VPS 状态与流量。

---

## 二、主要特性

- ✅ 一键部署四协议：**VLESS / VMESS / Trojan / Hysteria2**
- 🔐 自动申请与续期 **Let's Encrypt TLS** 证书
- ⚙️ 自带 systemd 服务：支持启动、停止、重启、开机自启
- 📊 可选安装 Web 可视化面板（实时监控 CPU / 内存 / 磁盘 / 网络流量）
- 📋 一键复制节点订阅信息（VLESS / VMESS / Trojan / Hysteria2）
- 🌍 支持 IPv6 / IPv4 / 双栈 VPS、arm64 与 x86_64 架构
- 🪶 纯 Bash 实现，无需数据库，轻量高效
- 🧱 面板页面通过 HTTPS + JSON 文件实时更新，无缓存干扰

---

## 三、安装方法
### 🧠 方式一：安装 sing-box 四协议节点（主程序）

```
bash <(curl -fsSL https://raw.githubusercontent.com/hansvlss/sing-box-vps/main/singbox-4in1.sh)

```
### 🖥️ 方式二：安装 Web 管理面板（可选）

```
bash <(curl -fsSL https://raw.githubusercontent.com/hansvlss/sing-box-vps/main/singbox_panel.sh)

```
### 面板功能包括：
- 📈 实时监控：CPU / 内存 / 磁盘 / 网络速率 / 流量统计
- 🔐 展示 TLS 证书信息（颁发者、到期时间、签名算法等）
- 🛰️ 查看监听端口状态
- 📋 一键复制节点订阅信息（VLESS / VMESS / Trojan / Hysteria2）
- ♻️ 自带自动刷新与无缓存优化
