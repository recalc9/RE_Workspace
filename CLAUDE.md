# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 本项目 **RE-Env** 是面向恶意软件分析与逆向工程的「双擎沙箱管控平台」。所有代码、注释、用户界面文案均以 **中文** 撰写，新代码请保持这一约定。

## 项目定位

一个统一的控制器，将 Docker/Podman（容器）与 VirtualBox（虚拟机）封装成「阅后即焚」的 CLI 与 GUI 工作流：

- **左脑（静态/网络）**：REMnux 容器，负责脱壳、反汇编、网络抓包模拟。
- **右脑（动态/行为）**：Windows 10 虚拟机，负责 x64dbg 动态调试、API 监控。

## 架构（三层分离）

| 层级 | 实现 | 职责 |
| --- | --- | --- |
| 控制面 | `re-env.ps1` | 唯一入口、参数校验、引擎检测、命令路由、日志审计 |
| 分析面 | REMnux 容器 + Win10 VM | 静态分析、动态调试、行为监控 |
| 数据面 | `D:\security\RE_Workspace` | 宿主机与分析环境之间安全的样本/产物穿透 |

控制面暴露的 7 个命令（`ValidateSet` 已锁定，不允许扩展）：`start-linux` / `stop-linux` / `start-win` / `reset-win` / `start-sim` / `stop-sim` / `status`。

## 常用命令

> 工作目录已硬编码为 `D:\security\RE_Workspace`。所有命令均在 PowerShell 5.1 下运行（不需要 PowerShell 7）。

### CLI 模式（PowerShell）

```powershell
.\re-env.ps1 start-linux              # 启动 REMnux 容器（交互式）
.\re-env.ps1 start-linux -Isolated    # 隔离模式：--network=none --cap-drop=ALL --security-opt=no-new-privileges
.\re-env.ps1 start-linux .\bin\evil.exe   # 第二参数作为样本路径，会回显到日志与容器内 /home/remnux/malware/
.\re-env.ps1 stop-linux                # 销毁容器
.\re-env.ps1 start-win                 # 恢复 Clean_Base 快照后启动 VM
.\re-env.ps1 reset-win                 # poweroff + 恢复快照（无条件重置）
.\re-env.ps1 start-sim                 # 启动 INetSim（写入 .inetsim_ip）
.\re-env.ps1 stop-sim                  # 销毁 INetSim
.\re-env.ps1 status                    # 打印引擎/容器/VM/INetSim 状态面板
```

INetSim 联动流程：先 `start-sim` 让 IP 写入 `.inetsim_ip`，再 `start-linux` 时脚本会自动读取并追加 `--dns=<ip>`。

### GUI 托盘模式

```bash
pip install pystray pillow    # 首次安装依赖
python tray_app.py            # 启动托盘（主线程跑 tkinter，pystray 在子线程）
```

托盘右键菜单项与 CLI 命令一一对应。关闭 tkinter 窗口只是 **隐藏到托盘**，右键菜单「❌ 退出」才会真正终止进程。

## 关键约定与坑

### 容器引擎自适应

`Get-ContainerEngine` 先探测 `docker info`，失败再降级到 `podman info`，都失败则 `exit 1`。**Podman 分支会自动改写挂载选项**：

- 在两个 `-v` 的容器侧路径追加 `:Z`（SELinux 标签）
- 追加 `--userns=keep-id`

新增容器命令时若涉及挂载，遵循同样的 Podman 兼容写法。

### `*>` 与 `$null` 的差别

本脚本统一使用 PowerShell 5.1+ 的 `*> $null` 静默丢弃所有输出流（标准输出 + 标准错误）。**不要替换为 `2>$null`**——后者在某些场景下会泄漏 stdout。

### VBox 状态解析（防炸裂写法）

`Get-VBoxState` 用 `Select-String "VMState="` + 两次 `-replace` 提取 `VMState="..."` 字段。**不要改用 `Split('=')` 或 `Trim('"')`**——PS 5.1 嵌套引号解析在 `--machinereadable` 输出上会崩溃。原始写法的注释明确说明了这一点。

### 日志路径

所有操作追加写入 `D:\security\RE_Workspace\.re-env.log`（UTF8，防中文乱码）。`re-env.ps1` 启动时只检测引擎并写一行；容器启动/停止等关键事件才写 `[+]`/`[-]`/`[!]` 行。INetSim 的 IP 单独存到 `.inetsim_ip`（无 BOM 的 UTF8，方便被 `Get-Content -Raw` 读取后 `.Trim()`）。

### 宿主机 ↔ 容器/VM 路径约定

- `linux_targets/` → 容器内 `/home/remnux/malware/`（静态样本落地点）
- `output/` → 容器内 `/home/remnux/output/`（dump、pcap 等产物回收点）
- `windows_targets/` → VM 内自动挂载为 `\\vboxsvr\re-env-targets`（transient + automount，需 Guest Additions）。`output/` 同理挂为 `re-env-output`。每次 `start-win` 重新挂载，关机后自动消失（阅后即焚）。

启动时通过 `Initialize-Workspace` 自动 `New-Item -Force` 创建上述目录。

## 模块结构（控制面 + GUI 桥）

```
re-env.ps1          # 控制面核心：所有命令的实际执行者（必须以 -File 调用）
ps_bridge.py        # subprocess 封装：powershell -ExecutionPolicy Bypass -NoProfile -File re-env.ps1 <cmd>
                    #   同步：run_ps_command(...)  -> (exit_code, stdout, stderr)
                    #   异步：run_ps_command_async(cmd, callback) -> 守护线程，回调签名 (exit_code, stdout, stderr)
tray_menu.py        # 托盘菜单 + 图标生成（无依赖 pystray 的运行时部分）
                    #   get_tray_icon() 返回主图标；菜单 build_menu(ctrl) 注入 TrayController 实例
tray_app.py         # GUI 主程序：TrayController 持有 pystray.Icon + tk.Tk
                    #   关键循环：每 5s 通过 ps_bridge 拉 status 刷新 tooltip
                    #   UI 更新必须回到主线程：用 self._tk_root.after(0, fn)
```

`ps_bridge.py` 顶部硬编码 `SCRIPT_PATH = r"D:\security\RE_Workspace\re-env.ps1"`，迁移或重命名工作区时需同步修改。

## 外部依赖（前置条件）

在跑任何命令前必须就绪：

1. **Docker Desktop 或 Podman**（含 rootless 模式与 SELinux）
2. **Oracle VM VirtualBox**，且 `VBoxManage.exe` 在 `C:\Program Files\Oracle\VirtualBox\`（如不在，需改 `$Config.VBoxManagePath`）
3. 镜像：`docker pull docker.io/remnux/remnux-distro:latest`
4. VM：VirtualBox 中名为 `Windows10` 的虚拟机，并预存名为 `Clean_Base` 的干净快照
5. 可选：`docker pull 0x4d4c/inetsim:latest`

VM 名 / 快照名 / 镜像名 / GDB 端口（默认 9999）等都集中在 `$Config` 哈希表中修改。

## 修改代码时的注意点

- `re-env.ps1` 顶部 `#Requires -Version 5.1` 与 `ValidateSet` 是双层保护：扩命令时两者都要更新。
- 所有可执行命令必须写日志（`Write-Log`）——这是审计追溯的唯一依据。
- `-Isolated` 与 INetSim DNS 联动互斥：`if ($Isolated) { ... } elseif (Test-Path $Config.INetSimIPFile) { ... }`，新参数若与隔离策略冲突，沿用这个 elseif 链。
- 托盘菜单的 `menu_item(label, cmd)` 闭包中 `ctrl.do_command(cmd, cb)` 是异步入口；任何「启动后立即读取状态」的逻辑请走 `ps_bridge.run_ps_command_async` + 回调，不要在 `do_command` 调用后阻塞等待。