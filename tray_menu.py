"""
tray_menu.py - 托盘菜单定义与命令转发层
定义菜单项、图标渲染（PNG bytes）、以及菜单回调逻辑。
"""

from PIL import Image, ImageDraw

# ------------------- 扁平化配色 -------------------
# 参考 Material Design / Windows 11 Fluent 的扁平色板
COLOR_PRIMARY = "#1a73e8"   # 主色（深蓝）
COLOR_TEXT = "#ffffff"      # 图标文字

# ------------------- 图标生成 -------------------

def _make_icon(color: str, text: str, size: int = 64) -> Image.Image:
    """生成扁平化图标：纯色方块 + 居中文字（极小圆角，无渐变无阴影）。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 扁平化：极小圆角（radius=8），纯色填充，无描边无阴影
    margin = 6
    draw.rounded_rectangle(
        [margin, margin, size - margin - 1, size - margin - 1],
        radius=8,
        fill=color
    )

    # 居中文字（注意：textbbox 返回的 (x0, y0, x1, y1) 中的 x0/y0 是字形的左/上 bearing，
    # 必须把它也减掉，否则 CJK 字形（以及任何带 left-side bearing 的字符）会偏左）
    bbox = draw.textbbox((0, 0), text)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (size - tw) // 2 - bbox[0]
    y = (size - th) // 2 - bbox[1]
    draw.text((x, y), text, fill=COLOR_TEXT)

    return img


def get_tray_icon() -> Image.Image:
    """返回主托盘图标：深蓝底 + RE 字样（扁平化）。"""
    return _make_icon(COLOR_PRIMARY, "RE", size=64)


# ------------------- 菜单构建 -------------------

def build_menu(ctrl):
    """
    构建托盘右键菜单。

    ctrl: tray_app.TrayController 实例，
          提供 .do_command(cmd, callback) 和 .show_log() 方法。
    """
    import pystray

    def menu_item(label, cmd=None, cb=None):
        """生成普通菜单项，cmd 为命令字符串，cb 为回调。"""
        if cmd:
            return pystray.MenuItem(label, lambda i, k: ctrl.do_command(cmd, cb))
        else:
            return pystray.Menu.SEPARATOR

    return pystray.Menu(
        pystray.MenuItem("RE-Env  控制台", lambda i, k: None, enabled=False),

        menu_item("▶  启动 Linux (REMnux)",    "start-linux"),
        menu_item("⏸  停止 Linux",             "stop-linux"),

        pystray.Menu.SEPARATOR,

        menu_item("▶  启动 Windows VM",        "start-win"),
        menu_item("⏸  停止 Windows VM",        "stop-win"),
        menu_item("🔄  重置 Windows VM",        "reset-win"),

        pystray.Menu.SEPARATOR,

        menu_item("▶  启动网络模拟 (INetSim)", "start-sim"),
        menu_item("⏸  停止网络模拟",           "stop-sim"),

        pystray.Menu.SEPARATOR,

        pystray.MenuItem(
            "📊  环境状态",
            lambda i, k: ctrl.show_log()
        ),

        pystray.Menu.SEPARATOR,

        pystray.MenuItem(
            "❌  退出",
            lambda i, k: ctrl.quit()
        ),
    )
