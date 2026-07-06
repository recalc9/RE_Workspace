\# 🛡️ RE-Env: 双擎逆向沙箱管控平台



> \*\*逆向工程环境统一控制器\*\* | 基于 PowerShell 5.1 构建的 Docker/Podman + VirtualBox 自动化编排工具。



\[!\[PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/en-us/powershell/)

\[!\[Docker](https://img.shields.io/badge/Docker-Supported-2496ED.svg?logo=docker)](https://www.docker.com/)

\[!\[Podman](https://img.shields.io/badge/Podman-Supported-892CA0.svg?logo=podman)](https://podman.io/)

\[!\[VirtualBox](https://img.shields.io/badge/VirtualBox-Supported-183A61.svg?logo=virtualbox)](https://www.virtualbox.org/)



\## 🌟 项目简介



在恶意软件分析与逆向工程中，\*\*“环境纯净度”\*\* 与 \*\*“操作便捷性”\*\* 往往难以兼得。手动配置容器挂载、映射端口、恢复虚拟机快照不仅繁琐，且极易因人为疏忽导致样本逃逸或环境污染。



\*\*RE-Env\*\* 旨在解决这一痛点：它将复杂的底层虚拟化与容器化技术，封装成了极简的、具备 \*\*“阅后即焚”\*\* 特性的 CLI（命令行）工作流，让分析师能够专注于样本本身。



\## ✨ 核心特性



\- 🔄 \*\*双引擎自适应\*\*：自动检测并兼容 Docker 与 Podman（完美支持 Rootless 模式与 SELinux 标签）。

\- 🧠 \*\*左右脑协同\*\*：

&#x20; - \*\*左脑 (静态/网络)\*\*：REMnux 容器，负责脱壳、反汇编、网络抓包模拟。

&#x20; - \*\*右脑 (动态/行为)\*\*：Windows 10 虚拟机，负责 x64dbg 动态调试、API 监控。

\- 🛡️ \*\*最高级别隔离\*\*：内置 `-Isolated` 模式，一键实现物理断网与内核级降权，防止样本逃逸。

\- ♻️ \*\*状态机重置\*\*：每次启动 Windows 沙箱强制恢复干净快照，确保分析环境绝对无毒。

\- 📝 \*\*全链路审计\*\*：所有操作自动记录至带时间戳的本地日志文件。

\- 🌐 \*\*网络模拟联动\*\*：支持一键启动 INetSim 容器，自动与 REMnux DNS/HTTP 流量联动。

\- 🖥️ \*\*GUI 托盘前端\*\*：Python pystray 系统托盘，替代纯 CLI 操作，支持环境状态实时监控。



\## 🏗️ 架构设计



项目采用经典的“控制-分析-数据”三层分离架构：



| 架构层级 | 技术实现 | 核心职责 |

| :--- | :--- | :--- |

| \*\*控制面\*\* | `re-env.ps1` (PowerShell) | 统一入口、参数校验、引擎检测、状态路由、日志审计。 |

| \*\*分析面\*\* | REMnux (容器) + Win10 (VM) | 静态分析、动态调试、行为监控。 |

| \*\*数据面\*\* | `D:\\RE\_Workspace` | 标准化数据流转，实现宿主机与分析环境的安全穿透。 |



\## ⚙️ 环境要求



\- \*\*操作系统\*\*: Windows 10 / 11 (x64)

\- \*\*运行环境\*\*: Windows PowerShell 5.1+ (无需 PowerShell Core 7)

\- \*\*依赖软件\*\*:

&#x20; - \[Docker Desktop](https://www.docker.com/products/docker-desktop) 或 \[Podman](https://podman.io/)

&#x20; - \[Oracle VM VirtualBox](https://www.virtualbox.org/) (需将 `VBoxManage.exe` 路径配置正确)

\- \*\*镜像与快照\*\*:

&#x20; - 需提前拉取 REMnux 镜像：`docker pull docker.io/remnux/remnux-distro:latest`

&#x20; - 需在 VirtualBox 中创建名为 `Windows10` 的虚拟机，并打下名为 `Clean\_Base` 的干净快照。

&#x20; - 可选（INetSim）：提前拉取 INetSim 镜像：`docker pull 0x4d4c/inetsim:latest`



\## 📂 目录结构



脚本运行前会自动初始化以下工作目录：



```text

D:\\RE\_Workspace\\

├── linux\_targets\\       # 存放待分析的 Linux/跨平台 恶意样本

├── windows\_targets\\     # 存放待分析的 Windows PE 样本

├── output\\              # 分析产物输出目录 (如 dump 的内存、抓包 pcap)

├── .re-env.log          # 自动化操作审计日志

├── re-env.ps1           # 核心控制脚本
├── ps_bridge.py         # PowerShell 调用封装（托盘用）
├── tray_menu.py         # 托盘菜单定义
└── tray_app.py          # GUI 托盘主程序


## 🚀 使用方法

### CLI 模式（PowerShell）

```powershell
.\re-env.ps1 start-linux      # 启动 REMnux 容器
.\re-env.ps1 start-linux -Isolated  # 隔离模式（断网）
.\re-env.ps1 stop-linux        # 停止 REMnux
.\re-env.ps1 start-win         # 启动 Windows VM
.\re-env.ps1 reset-win         # 重置 Windows VM
.\re-env.ps1 start-sim         # 启动 INetSim 网络模拟
.\re-env.ps1 stop-sim          # 停止 INetSim
.\re-env.ps1 status            # 查看所有环境状态
```

### INetSim 联动流程

1. 启动 INetSim：`.\re-env.ps1 start-sim`
2. 启动 REMnux：`.\re-env.ps1 start-linux`（自动 DNS 联动）
3. 在 REMnux 容器内，访问任意域名都会被 INetSim 拦截并返回模拟响应

### GUI 托盘模式

```bash
# 安装依赖（首次）
pip install pystray pillow

# 启动托盘
python tray_app.py
```

托盘图标操作：
- **▶ 启动 Linux (REMnux)** — 启动容器
- **⏸ 停止 Linux** — 停止并销毁容器
- **▶ 启动网络模拟 (INetSim)** — 启动 INetSim 容器
- **📊 环境状态** — 弹出状态日志窗口
- **❌ 退出** — 完全退出程序

> 关闭 tkinter 窗口仅隐藏程序，右键托盘图标选择"退出"才终止进程。

