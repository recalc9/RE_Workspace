"""
ps_bridge.py - PowerShell 脚本调用封装
通过 subprocess 调用 re-env.ps1，捕获 stdout/stderr 并返回结构化结果。
"""

import subprocess
import threading
from pathlib import Path
from typing import Optional, Tuple

# Windows 专用：隐藏子进程的控制台窗口（pythonw.exe 启动 powershell 时默认会弹窗）
if hasattr(subprocess, "STARTUPINFO") and hasattr(subprocess, "STARTF_USESHOWWINDOW"):
    _HIDE_CONSOLE = subprocess.STARTUPINFO()
    _HIDE_CONSOLE.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    _HIDE_CONSOLE.wShowWindow = subprocess.SW_HIDE
else:
    _HIDE_CONSOLE = None

# 从本文件位置推导，避免迁移工作区时还要改硬编码路径
BASE_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = BASE_DIR / "re-env.ps1"

# 交互式阻塞命令：这些命令设计上是让用户长时间停留在交互 shell 里，
# 不应该被 ps_bridge 的默认 30s 超时杀掉（subprocess.TimeoutExpired 会
# 杀掉 powershell.exe，但容器仍在运行——造成 '看起来失败但其实在跑' 的鬼影）
LONG_RUNNING_COMMANDS = frozenset({"start-linux"})

DEFAULT_TIMEOUT = 30  # 秒，普通命令的默认超时


def run_ps_command(
    command: str,
    sample_path: Optional[str] = None,
    isolated: bool = False,
    timeout: Optional[int] = DEFAULT_TIMEOUT
) -> Tuple[int, str, str]:
    """
    调用 re-env.ps1 的指定命令，返回 (exit_code, stdout, stderr)。

    Args:
        command:    命令名，如 "start-linux", "status"
        sample_path: 可选，样本路径（用于 start-linux）
        isolated:   是否启用隔离模式（传递 -Isolated 开关）
        timeout:    命令超时秒数；None 表示不超时（用于交互式阻塞命令）
                    long-running 命令（LONG_RUNNING_COMMANDS）默认传 None

    Returns:
        (exit_code, stdout, stderr) 元组
    """
    # 交互式命令默认不超时（除非调用方显式传入 timeout）
    if timeout == DEFAULT_TIMEOUT and command in LONG_RUNNING_COMMANDS:
        timeout = None

    args = [
        "powershell",
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", str(SCRIPT_PATH),
        command
    ]

    if sample_path and command == "start-linux":
        args.append(sample_path)

    if isolated and command == "start-linux":
        args.append("-Isolated")

    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            startupinfo=_HIDE_CONSOLE
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        timeout_display = "infinite" if timeout is None else f"{timeout}s"
        return -1, "", f"Command timed out after {timeout_display}"
    except Exception as e:
        return -1, "", str(e)


def run_ps_command_async(
    command: str,
    callback,
    sample_path: Optional[str] = None,
    isolated: bool = False
) -> threading.Thread:
    """
    在后台线程中异步执行 PowerShell 命令，完成后调用 callback。

    Args:
        command:   命令名
        callback:  签名 (exit_code, stdout, stderr) -> None
        sample_path: 可选
        isolated:  是否启用隔离模式
    """
    def target():
        result = run_ps_command(command, sample_path, isolated)
        callback(*result)

    t = threading.Thread(target=target, daemon=True)
    t.start()
    return t


def get_status() -> str:
    """快速获取当前环境状态，返回原始输出字符串。"""
    _, stdout, _ = run_ps_command("status", timeout=15)
    return stdout
