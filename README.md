# 🛡️ RE-Env: 双擎逆向沙箱管控平台

> **逆向工程环境统一控制器** | 基于 PowerShell 5.1 构建的 Docker/Podman + VirtualBox 自动化编排工具。

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/en-us/powershell/)
[![Docker](https://img.shields.io/badge/Docker-Supported-2496ED.svg?logo=docker)](https://www.docker.com/)
[![Podman](https://img.shields.io/badge/Podman-Supported-892CA0.svg?logo=podman)](https://podman.io/)
[![VirtualBox](https://img.shields.io/badge/VirtualBox-Supported-183A61.svg?logo=virtualbox)](https://www.virtualbox.org/)

## 🌟 项目简介

在恶意软件分析与逆向工程中，**环境纯净度** 与 **操作便捷性** 往往难以兼得。手动配置容器挂载、映射端口、恢复虚拟机快照不仅繁琐，且极易因人为疏忽导致样本逃逸或环境污染。

**RE-Env** 旨在解决这一痛点：它将复杂的底层虚拟化与容器化技术，封装成了极简的、具备 **"阅后即焚"** 特性的 CLI 与 GUI 工作流，让分析师能够专注于样本本身。

## ✨ 核心特性

- 🔄 **双引擎自适应**：自动检测并兼容 Docker 与 Podman（支持 Rootless 模式与 SELinux 标签）。
- 🧠 **左右脑协同**：
  - **左脑（静态/网络）**：REMnux 容器，负责脱壳、反汇编、网络抓包模拟。
  - **右脑（动态/行为）**：Windows 10 虚拟机，负责 x64dbg 动态调试、API 监控。
- 🛡️ **最高级别隔离**：内置 `-Isolated` 模式，一键实现物理断网与内核级降权，防止样本逃逸。
- ♻️ **状态机重置**：每次启动 Windows 沙箱强制恢复干净快照（自动处理 saved 休眠态），确保分析环境绝对无毒。
- 📝 **全链路审计**：所有操作自动记录至带时间戳的本地日志文件（UTF-8 无 BOM，防中文乱码）。
- 🌐 **网络模拟联动**：一键启动 INetSim 容器，自动与 REMnux DNS/HTTP 流量联动。
- 🖥️ **GUI 托盘前端**：扁平化 pystray 系统托盘，替代纯 CLI 操作，支持环境状态实时监控。
- 📂 **宿主机↔环境穿透**：Linux 容器与 Windows VM 均可挂载宿主机目录，样本投递与产物回收零摩擦。

## 🏗️ 架构设计

项目采用经典的"控制-分析-数据"三层分离架构：

| 架构层级 | 技术实现 | 核心职责 |
| :--- | :--- | :--- |
| **控制面** | `re-env.ps1` (PowerShell) | 统一入口、参数校验、引擎检测、命令路由、日志审计。 |
| **分析面** | REMnux (容器) + Win10 (VM) | 静态分析、动态调试、行为监控。 |
| **数据面** | `D:\security\RE_Workspace` | 标准化数据流转，实现宿主机与分析环境的安全穿透。 |

## ⚙️ 环境要求

- **操作系统**: Windows 10 / 11 (x64)
- **运行环境**: Windows PowerShell 5.1+（无需 PowerShell Core 7）
- **依赖软件**:
  - [Docker Desktop](https://www.docker.com/products/docker-desktop) 或 [Podman](https://podman.io/)
  - [Oracle VM VirtualBox](https://www.virtualbox.org/)（`VBoxManage.exe` 默认在 `C:\Program Files\Oracle\VirtualBox\`，如不在需改 `$Config.VBoxManagePath`）
- **镜像与快照**:
  - REMnux 镜像：`docker pull docker.io/remnux/remnux-distro:latest`
  - VirtualBox 中创建名为 `Windows10` 的虚拟机，并打下名为 `Clean_Base` 的干净快照
  - VM 内需安装 **VirtualBox Guest Additions**（用于自动挂载共享文件夹）
  - 可选（INetSim）：`docker pull 0x4d4c/inetsim:latest`

## 📂 目录结构

脚本运行时自动初始化以下工作目录（工作区硬编码为 `D:\security\RE_Workspace`）：

```text
D:\security\RE_Workspace\
├── linux_targets\       # Linux 样本 → 容器内 /home/remnux/malware/
├── windows_targets\     # Windows 样本 → VM 内 Z: 盘（共享文件夹 re-env-targets）
├── output\              # 分析产物 → 容器内 /home/remnux/output/，VM 内 Y: 盘（re-env-output）
├── .re-env.log          # 操作审计日志（UTF-8 无 BOM）
├── .inetsim_ip          # INetSim IP 记录（供 start-linux DNS 联动）
├── .engine              # 引擎检测结果缓存（60s TTL）
├── re-env.ps1           # 核心控制脚本
├── ps_bridge.py         # PowerShell 调用封装（托盘用）
├── tray_menu.py         # 托盘菜单与图标
└── tray_app.py          # GUI 托盘主程序
```

## 🚀 使用方法

### CLI 模式（PowerShell）

```powershell
.\re-env.ps1 start-linux              # 启动 REMnux 容器（交互式 bash shell）
.\re-env.ps1 start-linux -Isolated    # 隔离模式：断网 + 丢弃所有 Capabilities
.\re-env.ps1 start-linux .\evil.exe   # 启动并加载样本（自动复制到 linux_targets/）
.\re-env.ps1 stop-linux               # 销毁 REMnux 容器
.\re-env.ps1 start-win                # 恢复快照后启动 Windows VM（自动挂载共享文件夹）
.\re-env.ps1 reset-win                # 强制断电 + 恢复快照（无条件重置）
.\re-env.ps1 start-sim                # 启动 INetSim（IP 写入 .inetsim_ip）
.\re-env.ps1 stop-sim                 # 销毁 INetSim
.\re-env.ps1 status                   # 打印引擎/容器/VM/INetSim 状态面板
.\re-env.ps1 help                     # 打印完整帮助
```

### 样本投递

- **Linux 样本**：`.\re-env.ps1 start-linux .\bin\suspicious.bin` —— 脚本自动把样本复制到 `linux_targets/`，容器内通过 `/home/remnux/malware/suspicious.bin` 访问。带路径穿越防护。
- **Windows 样本**：把 PE 文件放入 `windows_targets/`，`start-win` 后 VM 内 `Z:` 盘即可访问。

### INetSim 联动流程

```powershell
.\re-env.ps1 start-sim        # 1. 启动 INetSim，IP 写入 .inetsim_ip
.\re-env.ps1 start-linux      # 2. 自动读取 .inetsim_ip，DNS 指向 INetSim
.\re-env.ps1 status           # 3. 确认所有环境就绪
```

在 REMnux 容器内访问任意域名，都会被 INetSim 拦截并返回模拟响应（DNS/HTTP/SMTP 等）。

### GUI 托盘模式

```bash
pip install pystray pillow    # 首次安装依赖
python tray_app.py            # 启动托盘（自动脱离终端，后台运行）
```

托盘右键菜单（扁平化风格）：

- **▶ 启动 Linux (REMnux)** / **⏸ 停止 Linux**
- **▶ 启动 Windows VM** / **🔄 重置 Windows VM**
- **▶ 启动网络模拟 (INetSim)** / **⏸ 停止网络模拟**
- **📊 环境状态** — 弹出扁平化状态面板（支持刷新）
- **❌ 退出** — 完全终止进程

> 托盘每 4 秒自动刷新状态，tooltip 实时显示引擎与命令执行结果（✓/✗）。`python tray_app.py` 会自动切换到 `pythonw.exe` 脱离终端，不会卡住当前窗口。

## 🔒 安全姿态

- **`-Isolated` 模式**：`--network=none` + `--cap-drop=ALL` + `--security-opt=no-new-privileges`，物理断网且内核级降权。
- **阅后即焚**：所有容器与 VM 快照均为一次性，`stop-*` / `reset-win` 后立即销毁，不留痕迹。
- **路径穿越防护**：`-SamplePath` 会校验解析后路径必须落在 `linux_targets/` 下，拒绝逃逸。
- **DNS 注入防护**：`.inetsim_ip` 内容经 `[IPAddress]::TryParse` 校验，非法值不注入 `--dns`。
- **干净快照保证**：`start-win` / `reset-win` 检测并丢弃 saved 休眠态，确保每次冷启动自 Clean_Base。

## 📝 审计日志

所有关键操作追加写入 `D:\security\RE_Workspace\.re-env.log`，格式 `时间戳 | [级别] 消息`：

- `[+]` 成功事件（启动、挂载、复制）
- `[-]` 停止事件
- `[*]` 信息提示（引擎检测、联动、自动清理）
- `[!]` 警告/错误（失败、超时、降级）

`status` 命令是只读探针，不写日志，避免轮询时灌满审计文件。

## 📌 配置

所有路径、镜像名、端口集中在 `re-env.ps1` 顶部的 `$Config` 哈希表中：

```powershell
$Config = @{
    Workspace      = "D:\security\RE_Workspace"
    LinuxImage     = "docker.io/remnux/remnux-distro:latest"
    VboxVMName     = "Windows10"
    VboxSnapshot   = "Clean_Base"
    VBoxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    GdbPort        = 9999
    ContainerName  = "remnux_analysis"
    INetSimNetwork = "re-env-net"
    INetSimImage   = "0x4d4c/inetsim:latest"
    ...
}
```

迁移工作区时改 `Workspace` 即可（`ps_bridge.py` 已从 `__file__` 推导路径，无需改硬编码）。
