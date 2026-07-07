"""
tray_app.py - RE-Env 图形托盘主程序

功能：
  - 系统托盘图标（pystray），右键菜单驱动 re-env.ps1
  - 隐藏的 tkinter 窗口用于日志弹窗
  - 关闭主窗口时隐藏到托盘而非退出
  - 每 4s 刷新一次状态（单一定时器，避免多 after() 循环互相放大 PS 调用频率）
"""

import sys
import time
import tkinter as tk
from tkinter import scrolledtext
import threading
import queue
import logging

import pystray

# 本地模块
import ps_bridge
import tray_menu

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("RE-Env Tray")

# 状态主动轮询节拍
# TICK_SECONDS 从 STATUS_INTERVAL 推导，确保稳态 cadence = STATUS_INTERVAL
# 例如 4.0s → 4000ms tick → 每次 tick 时 >= 4.0 成立 → 4s 一次 fetch
STATUS_INTERVAL = 4.0     # 距上次 status 调用 >= 此秒数时主动刷新
TICK_SECONDS = int(STATUS_INTERVAL * 1000)  # tkinter after() 用毫秒

# ------------------- 扁平化主题 -------------------
# 参考 Material Design / Windows 11 Fluent 的扁平色板
THEME = {
    "bg":           "#f5f5f5",  # 窗口背景（浅灰）
    "panel":        "#ffffff",  # 面板 / 文本框背景
    "primary":      "#1a73e8",  # 主色（按钮、强调）
    "primary_hover":"#1557b0",  # 主色 hover
    "danger":       "#d93025",  # 关闭按钮
    "danger_hover": "#b3261e",
    "text":         "#202124",  # 主文字
    "text_muted":   "#5f6368",  # 次要文字
    "border":       "#dadce0",  # 边框
}

# 图标缓存（避免每次 get_tray_icon 都创建新 PIL Image）
_CACHED_TRAY_ICON = None


def _get_cached_tray_icon():
    """缓存图标，避免反复创建 PIL Image。"""
    global _CACHED_TRAY_ICON
    if _CACHED_TRAY_ICON is None:
        _CACHED_TRAY_ICON = tray_menu.get_tray_icon()
    return _CACHED_TRAY_ICON


def _flat_button(parent, text, command, bg_key="primary", fg="#ffffff"):
    """创建扁平化按钮：无边框、纯色背景、hover 变色。"""
    bg = THEME[bg_key]
    hover_bg = THEME[bg_key + "_hover"]
    btn = tk.Button(
        parent, text=text, command=command,
        relief=tk.FLAT, borderwidth=0, highlightthickness=0,
        bg=bg, fg=fg,
        activebackground=hover_bg, activeforeground=fg,
        padx=18, pady=8,
        font=("Segoe UI", 10),
        cursor="hand2",
    )
    btn.bind("<Enter>", lambda e: btn.config(bg=hover_bg))
    btn.bind("<Leave>", lambda e: btn.config(bg=bg))
    return btn


class TrayController:
    """托盘控制器：持有 tray icon 实例，协调 UI 与命令执行。"""

    def __init__(self):
        self._icon = None          # pystray.Icon 实例
        self._tk_root = None       # tkinter 根窗口（隐藏）
        self._log_window = None    # 日志弹窗（Toplevel）
        self._pending = queue.Queue()
        self._running = True
        self._last_status_at = 0.0 # 上次主动 status 的 monotonic 时间
        self._fetch_token = 0      # 递增 token，防止窗口销毁后 update 回调操作已销毁的 widget
        self._fetch_in_flight = False  # 并发保护：status 请求是否已在途中

    # ------------------- 托盘生命周期 -------------------

    def run(self):
        """启动托盘主循环（在主线程调用）。"""
        self._tk_root = tk.Tk()
        self._tk_root.withdraw()   # 隐藏根窗口

        # 唯一调度循环
        self._tk_root.after(TICK_SECONDS, self._tick)

        icon_image = _get_cached_tray_icon()

        self._icon = pystray.Icon(
            "re-env",
            icon_image,
            "RE-Env 沙箱管控平台",
            tray_menu.build_menu(self)
        )

        # 在子线程运行 pystray 主循环，避免阻塞 tkinter
        t = threading.Thread(target=self._icon.run, daemon=True)
        t.start()

        log.info("RE-Env tray started")
        self._tk_root.mainloop()

    # ------------------- 命令执行 -------------------

    def do_command(self, cmd: str, callback=None, isolated=False):
        """
        将命令转发给 ps_bridge 执行，完成后通过 callback 更新托盘。
        callback 会在 tkinter 主线程中执行以更新 UI。

        注意：本方法由 pystray 菜单回调线程调用，不能直接写 self._icon.title
        （pystray 的 title setter 非线程安全）。必须走 _update_tooltip 的 after() 回主线程。
        isolated=True 时传 -Isolated 开关（用于 start-linux / start-win 隔离模式）。
        """
        def on_done(exit_code, stdout, stderr):
            self._pending.put((cmd, exit_code, stdout, stderr))
            log.info(f"Command '{cmd}' finished (exit={exit_code})")

        ps_bridge.run_ps_command_async(cmd, on_done, isolated=isolated)
        tag = " (隔离)" if isolated else ""
        self._update_tooltip(f"RE-Env  |  {cmd}{tag}  执行中...")

    # ------------------- 托盘图标更新 -------------------

    def _set_tooltip_direct(self, text: str):
        """直接从主线程设置 tooltip（跳过 after()，减少事件队列压力）。"""
        if self._icon is not None:
            self._icon.title = text

    def _update_tooltip(self, text: str):
        """从后台线程设置 tooltip（通过 after() 回到主线程）。"""
        if self._icon is None or self._tk_root is None:
            return
        self._tk_root.after(0, lambda: setattr(self._icon, "title", text))

    # ------------------- 单一调度循环 -------------------

    def _tick(self):
        """每 TICK_SECONDS 触发一次：先消费队列，再按节拍主动拉 status。

        用 try/finally 保证 after() 续命一定执行——即使中间任何一步抛异常
        （比如 icon 已停止时写 title），也不会让 _tick 循环永久死亡。
        """
        if not self._running:
            return

        try:
            # 1) 消费所有待处理的命令结果
            try:
                while True:
                    cmd, exit_code, stdout, stderr = self._pending.get_nowait()
                    # 用命令结果反馈到 tooltip，让用户知道执行成功或失败
                    if exit_code == 0:
                        self._set_tooltip_direct(f"RE-Env  |  {cmd}  ✓")
                    else:
                        err_msg = (stderr or "").strip()[:30]
                        tooltip = f"RE-Env  |  {cmd}  ✗ {err_msg}" if err_msg else f"RE-Env  |  {cmd}  ✗"
                        self._set_tooltip_direct(tooltip[:127])
                    # 命令完成 → 立即拉一次最新 status 更新 tooltip
                    self._fetch_status_async()
                    self._last_status_at = time.monotonic()
            except queue.Empty:
                pass

            # 2) 按节拍主动拉 status
            if time.monotonic() - self._last_status_at >= STATUS_INTERVAL:
                self._fetch_status_async()
                self._last_status_at = time.monotonic()
        except Exception as e:
            log.warning(f"_tick 异常（已吞掉以保证循环续命）: {e}")
        finally:
            # 3) 续命——无论上面是否抛异常，都要 schedule 下一次 tick
            if self._running:
                self._tk_root.after(TICK_SECONDS, self._tick)

    def _fetch_status_async(self):
        """后台拉取 status 并在主线程上更新 tooltip（带并发保护）。"""
        if self._fetch_in_flight:
            return  # 已有一次 status 在途中，跳过

        def on_status_done(exit_code, stdout, stderr):
            self._fetch_in_flight = False
            def update():
                if not stdout:
                    return
                # 取更实用的行做 tooltip：Engine + 第一项状态（Linux/Windows/INetSim）
                # 跳过标题行 ==== ENV STATUS ====
                lines = stdout.strip().splitlines()
                # 取 Engine 行（如 "Engine: docker"）作为 tooltip 摘要
                engine_line = next((l for l in lines if l.startswith("Engine:")), None)
                if engine_line:
                    tooltip = f"RE-Env  |  {engine_line.strip()}"
                else:
                    tooltip = f"RE-Env  |  {lines[0]}" if lines else "RE-Env"
                self._set_tooltip_direct(tooltip[:127])
            self._tk_root.after(0, update)

        self._fetch_in_flight = True
        try:
            ps_bridge.run_ps_command_async("status", on_status_done)
        except Exception as e:
            self._fetch_in_flight = False
            log.warning(f"Status refresh failed: {e}")

    # ------------------- 日志窗口 -------------------

    def show_log(self):
        """点击托盘菜单'环境状态'，弹出日志窗口。"""
        self._tk_root.after(0, self._open_status_dialog)

    def _open_status_dialog(self):
        # 既有窗口：恢复显示
        if self._log_window is not None and self._log_window.winfo_exists():
            # withdraw() 后需要 deiconify() 才能恢复可见，lift() 仅改变 Z-order
            self._log_window.deiconify()
            self._log_window.lift()
            return

        win = tk.Toplevel(self._tk_root)
        win.title("RE-Env  环境状态")
        win.geometry("640x460")
        win.configure(bg=THEME["bg"])
        # 内容区域统一 padding
        content = tk.Frame(win, bg=THEME["bg"])
        content.pack(fill=tk.BOTH, expand=True, padx=16, pady=12)

        # 标题
        tk.Label(
            content, text="环境状态", font=("Segoe UI", 14, "bold"),
            bg=THEME["bg"], fg=THEME["text"], anchor="w"
        ).pack(fill=tk.X, pady=(0, 10))

        # 文本框：用 Frame 包装提供 1px 扁平边框
        text_frame = tk.Frame(content, bg=THEME["border"], highlightthickness=0)
        text_frame.pack(fill=tk.BOTH, expand=True)
        text = scrolledtext.ScrolledText(
            text_frame, wrap=tk.WORD, font=("Consolas", 10),
            relief=tk.FLAT, borderwidth=0,
            bg=THEME["panel"], fg=THEME["text"],
            insertbackground=THEME["text"],
            padx=10, pady=8,
            highlightthickness=0,
        )
        text.pack(fill=tk.BOTH, expand=True, padx=1, pady=1)

        # 加载当前状态（带 fetch token 防止窗口关闭后 TclError）
        self._fetch_token += 1
        token = self._fetch_token

        def fetch_and_display(token=token):
            _, stdout, _ = ps_bridge.run_ps_command("status", timeout=15)
            # 操作 UI 必须到主线程；先清空再插入，避免刷新后内容叠加
            def update():
                # 校验 token：如果 token 变了说明有更新请求，放弃这个过期结果
                if self._fetch_token != token:
                    return
                try:
                    text.delete("1.0", tk.END)
                    text.insert(tk.END, stdout or "无输出")
                    text.see(tk.END)
                except tk.TclError:
                    # widget 已被销毁（窗口已关闭），静默忽略
                    pass
            self._tk_root.after(0, update)

        def refresh_async():
            """刷新按钮：在 daemon 线程中异步拉取，避免阻塞 tkinter 主线程。"""
            self._fetch_token += 1
            t = threading.Thread(target=lambda: fetch_and_display(self._fetch_token), daemon=True)
            t.start()

        threading.Thread(target=lambda: fetch_and_display(token), daemon=True).start()

        # 按钮栏（扁平化）
        btn_frame = tk.Frame(content, bg=THEME["bg"])
        btn_frame.pack(fill=tk.X, pady=(10, 0))

        def close_and_clear():
            # 销毁时显式清空引用，避免下次打开时 winfo_exists() 兜底逻辑生效
            self._log_window = None
            win.destroy()

        _flat_button(btn_frame, "刷新", refresh_async, bg_key="primary").pack(side=tk.LEFT)
        _flat_button(btn_frame, "关闭", close_and_clear, bg_key="danger").pack(side=tk.RIGHT)

        self._log_window = win
        win.protocol("WM_DELETE_WINDOW", win.withdraw)  # 关闭时隐藏而非销毁

    # ------------------- 退出 -------------------

    def quit(self):
        """完全退出程序。"""
        self._running = False
        self._tk_root.after(0, self._do_quit)

    def _do_quit(self):
        if self._icon:
            self._icon.stop()
        self._tk_root.quit()
        sys.exit(0)


# ------------------- 入口 -------------------

if __name__ == "__main__":
    # 若当前用的是 python.exe（而非 pythonw.exe），尝试自动用 pythonw.exe 脱离终端
    # 这样用户不会因为 tkinter.mainloop() 阻塞而卡在终端里
    import os as _os
    _py = _os.path.basename(sys.executable).lower()
    if _py == "python.exe":
        _pyw = _os.path.join(_os.path.dirname(sys.executable), "pythonw.exe")
        if _os.path.exists(_pyw):
            print("RE-Env 托盘即将在后台启动… 如需关闭请右键托盘图标点「❌ 退出」。")
            try:
                _os.execv(_pyw, [_pyw] + sys.argv)
                # execv 成功时不返回；下面的代码只在 execv 抛异常时执行
            except OSError as e:
                print(f"[*] 切换到 pythonw.exe 失败（{e}），改用当前进程继续。")
        else:
            print("RE-Env 托盘已启动（当前终端被 tkinter 占用属正常现象）。")
            print("提示：下次用 pythonw tray_app.py 启动就不会卡终端了。")

    controller = TrayController()
    controller.run()
