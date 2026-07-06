#Requires -Version 5.1
<#
.SYNOPSIS
    逆向工程环境统一控制器（支持 Docker/Podman 容器与 VirtualBox 虚拟机联动）
.DESCRIPTION
    本脚本用于一键管理 REMnux（Linux 恶意软件分析）和 Windows10（沙箱/调试）环境。

    工作目录：D:\security\RE_Workspace
    日志路径：D:\security\RE_Workspace\.re-env.log
    INetSim IP 记录：D:\security\RE_Workspace\.inetsim_ip

.USAGE
    .\re-env.ps1 <command> [options]

    # 启动 REMnux 容器（交互式 bash shell，exit 后容器自动销毁）
    .\re-env.ps1 start-linux

    # 隔离模式：断网 + 丢弃所有 Linux Capabilities
    .\re-env.ps1 start-linux -Isolated

    # 启动容器并加载样本（样本自动复制到 linux_targets/ 供容器挂载）
    .\re-env.ps1 start-linux -Isolated .\bin\evil.exe

    # 停止并销毁容器
    .\re-env.ps1 stop-linux

    # 恢复 Clean_Base 快照后启动 Windows10 VM
    .\re-env.ps1 start-win

    # 强制断电 + 恢复快照（无条件重置）
    .\re-env.ps1 reset-win

    # 启动 INetSim 网络模拟
    .\re-env.ps1 start-sim

    # 停止并销毁 INetSim
    .\re-env.ps1 stop-sim

    # 查看所有环境状态面板
    .\re-env.ps1 status

    # 打印本帮助信息
    .\re-env.ps1 help

.COMMANDS
    start-linux [-Isolated] [-SamplePath <path>]
        启动 REMnux 容器（交互式 bash shell，exit 后自动销毁）。
        -Isolated 启用最高级别隔离（--network=none
        --cap-drop=ALL --security-opt=no-new-privileges）。
        非隔离模式下若存在 .inetsim_ip 文件，自动追加 --dns=<ip> 联动 INetSim。
        -SamplePath 可传入样本路径（自动复制到 /home/remnux/malware/）。

    stop-linux
        停止并强制销毁 remnux_analysis 容器（docker/podman stop + rm -f）。

    start-win
        恢复 VirtualBox 快照 Clean_Base 后以 GUI 模式启动 Windows10 虚拟机。
        每次启动前都会恢复快照，确保干净分析环境。

    reset-win
        强制断电虚拟机（poweroff），等待 3 秒后恢复 Clean_Base 快照。
        用于分析后重置状态。

    start-sim
        在 re-env-net 网络中启动 inetsim/inetsim:latest 容器，映射常用端口
        （53/TCP+UDP, 80, 443, 25, 110, 143, 993, 995, 3306, 5432）。
        分配到的 IP 写入 .inetsim_ip 文件，供 start-linux 联动使用。

    stop-sim
        停止并销毁 INetSim 容器，删除 .inetsim_ip 文件，保留 re-env-net 网络。

    status
        打印 Engine、Workspace、Linux 容器状态、Windows VM 状态、INetSim 状态
        的实时面板。

    help
        打印本帮助信息（Get-Help -Full 的完整输出）。

.REQUIREMENTS
    - Docker Desktop 或 Podman（含 rootless 模式）
    - Oracle VM VirtualBox，VBoxManage.exe 在 C:\Program Files\Oracle\VirtualBox\
    - 镜像：docker.io/remnux/remnux-distro:noble
    - VM：VirtualBox 中名为 Windows10 的虚拟机，预存 Clean_Base 快照
    - 可选：docker.io/inetsim/inetsim:latest

.EXAMPLE
    完整联动流程：
        .\re-env.ps1 start-sim        # 启动 INetSim，IP 写入 .inetsim_ip
        .\re-env.ps1 start-linux      # 自动读取 .inetsim_ip，DNS 指向 INetSim
        .\re-env.ps1 start-win        # 启动 Windows 沙箱 VM
        .\re-env.ps1 status           # 确认所有环境就绪

    隔离样本分析：
        .\re-env.ps1 start-linux -Isolated -SamplePath .\bin\suspicious.bin
#>

# ================= 1. 参数定义区 =================
param(
    # 必填参数：指定要执行的命令，使用 ValidateSet 限制只能输入指定的几个字符串，防止误操作
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("start-linux", "stop-linux", "start-win", "reset-win", "start-sim", "stop-sim", "status", "help")]
    [string]$Command,

    # 可选参数：指定要分析的样本路径（主要用于 start-linux 时传递样本名）
    [Parameter(Position=1)]
    [string]$SamplePath,

    # 开关参数：是否启用高危隔离模式（断开网络、丢弃所有 Linux Capabilities）
    [switch]$Isolated
)

# ================= 2. 核心配置区 =================
# 使用哈希表集中管理所有路径、镜像名和端口，方便后续修改
$Config = @{
    Workspace      = "D:\security\RE_Workspace"                  # 宿主机上的主工作目录
    LinuxImage     = "docker.io/remnux/remnux-distro:latest" # REMnux 官方 Docker/Podman 镜像（默认 :latest，用户可自行改为 :noble 等 tag）
    VboxVMName     = "Windows10"                        # VirtualBox 中的虚拟机名称
    VboxSnapshot   = "Clean_Base"                       # 启动前需要恢复的干净快照名称
    VBoxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" # VBoxManage 命令行工具路径
    GdbPort        = 9999                               # 映射到宿主机的 GDB 调试端口
    ContainerName  = "remnux_analysis"                  # 运行时的容器名称
    LogFile        = "D:\security\RE_Workspace\.re-env.log"      # 操作日志保存路径
    INetSimNetwork = "re-env-net"                        # INetSim Docker 网络名
    INetSimImage   = "0x4d4c/inetsim:latest"           # INetSim 官方镜像（用户实际 pull 的是 0x4d4c/inetsim）
    INetSimName    = "inetsim_sim"                       # INetSim 运行时容器名
    INetSimIPFile  = "D:\security\RE_Workspace\.inetsim_ip" # INetSim IP 记录文件
}

# ================= 3. 日志记录函数 =================
# 全局共享的无 BOM UTF-8 编码器，避免每次 Write-Log 都 new 一个对象
$Script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Log {
    param(
        [string]$Message,                            # 日志内容
        [System.ConsoleColor]$Color = "White"        # 控制台输出颜色
    )

    # 获取当前时间戳并格式化
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # 用 AppendAllText 以 UTF-8 无 BOM 追加写入。
    # 注意：不要用 Add-Content -Encoding UTF8（PS 5.1 默认带 BOM，且重复追加时会改写文件头导致乱码）
    $line = "$timestamp | $Message"
    [System.IO.File]::AppendAllText($Config.LogFile, $line + [Environment]::NewLine, $Script:Utf8NoBom)
    Write-Host $Message -ForegroundColor $Color
}

# ================= 4. 工作目录初始化 =================
function Initialize-Workspace {
    # 定义需要自动创建的子目录
    $dirs = @("linux_targets", "output", "windows_targets")

    foreach ($dir in $dirs) {
        $path = Join-Path $Config.Workspace $dir
        # 如果目录不存在，则强制创建并隐藏输出
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

# ================= 5. 容器引擎自动检测 =================
function Get-ContainerEngine {
    # 优先尝试检测 Docker
    try {
        # *> $null 是 PS 5.1+ 的语法，用于静默丢弃所有输出流（标准输出+标准错误），比 2>$null 更彻底
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { return "docker" }
    } catch {}

    # 如果 Docker 不可用，降级尝试检测 Podman
    try {
        & podman info *> $null
        if ($LASTEXITCODE -eq 0) { return "podman" }
    } catch {}

    # 如果两者都找不到，报错并退出脚本
    Write-Log "[!] Docker / Podman 均不可用" "Red"
    exit 1
}

# ================= 5b. 引擎结果缓存（消除 status 轮询带来的日志噪音） =================
# TTL 60s：托盘每 5s 轮询一次 status 时不再重复写 "[*] Engine: docker"
# 如果用户在会话中切换引擎，手动删除 .engine 文件可立即重探测
function Get-CachedEngine {
    $cacheFile = Join-Path $Config.Workspace ".engine"
    if (Test-Path $cacheFile) {
        try {
            $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
            if ($age.TotalSeconds -lt 60) {
                $cached = (Get-Content $cacheFile -Raw).Trim()
                if ($cached -eq "docker" -or $cached -eq "podman") {
                    return $cached
                }
            }
        } catch {}
    }
    $engine = Get-ContainerEngine
    try {
        [System.IO.File]::WriteAllText($cacheFile, $engine, $Script:Utf8NoBom)
    } catch {
        Write-Log "[!] 无法写入 .engine 缓存: $_" "Yellow"
    }
    return $engine
}

# ================= 6. INetSim 状态获取 =================
function Get-INetSimState {
    try {
        # 仅丢弃 stderr，stdout 要捕获到 $raw → 用 2>$null 而非 *>$null
        $raw = & $Engine ps -a --filter "name=$($Config.INetSimName)" --format "{{.Status}}" 2>$null
        if ($raw) { return $raw }
        return "Not running"
    } catch {
        return "Unknown"
    }
}

# ================= 7. VirtualBox 状态获取（防解析炸裂版） =================
function Get-VBoxState {
    param(
        [string]$VMName,
        [string]$VBoxPath
    )

    try {
        # 获取虚拟机的机器可读信息（键值对格式）
        # 仅丢弃 stderr，stdout 要捕获到 $raw → 用 2>$null 而非 *>$null
        $raw = & $VBoxPath showvminfo $VMName --machinereadable 2>$null
        
        # 核心防崩溃逻辑：
        # 1. 用 Select-String 提取包含 "VMState=" 的行
        # 2. 使用 -replace 正则替换掉 'VMState="' 和 剩余的 '"'
        # 这种纯字符串替换写法完美避开了 PS 5.1 中 Trim('"') 或 Split('=') 嵌套引发的引号解析灾难
        ($raw | Select-String "VMState=") -replace 'VMState="','' -replace '"',''
    } catch {
        return "Unknown"
    }
}

# ================= 8. 脚本初始化 =================
# help 命令不需要探测引擎，单独处理后直接返回
if ($Command -eq "help") {
    $lines = (Get-Content -Path $PSCommandPath -Encoding UTF8)
    $start = $null; $end = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*<#\s*$') { $start = $i }
        if ($lines[$i] -match '^\s*#>\s*$') { $end = $i; break }
    }
    if ($start -ne $null -and $end -ne $null) {
        $lines[($start + 1)..($end - 1)] | ForEach-Object {
            $_ -replace '^\s*#\s?', ''
        } | Write-Host
    } else {
        Write-Host "帮助信息未找到。" -ForegroundColor Red
    }
    exit 0
}

# 其它命令：先检测当前可用的容器引擎（用 60s 缓存避免 status 轮询时反复探测+写日志）
# status 命令是只读探针，缓存命中即可，不要往 .re-env.log 里灌 Engine 行
if ($Command -ne "status") {
    $Engine = Get-CachedEngine
    Write-Log "[*] Engine: $Engine" "Cyan"
} else {
    # status 分支第一次跑时引擎还没初始化（缓存文件也可能不存在）；按需探测但不写日志
    if (-not $Engine) {
        $Engine = Get-CachedEngine
    }
}

# ================= 9. 命令路由与执行 =================
switch ($Command) {

    # --- 启动 Linux (REMnux) 容器 ---
    "start-linux" {
        Initialize-Workspace

        # 前置检查：同名容器已存在则自动 rm -f，符合"阅后即焚"语义
        # 仅丢弃 stderr，stdout 要捕获到 $existing
        $existing = & $Engine ps -a --filter "name=$($Config.ContainerName)" --format "{{.Names}}" 2>$null
        if ($existing) {
            Write-Log "[*] 检测到同名容器 $($Config.ContainerName)，自动销毁（阅后即焚）" "Yellow"
            & $Engine rm -f $Config.ContainerName *> $null
        }

        # 若用户传入了 -SamplePath，在启动 docker run 之前先把样本复制到 linux_targets/（挂载点）。
        # 注意：必须放在 `& $Engine run --rm -it` 之前——那是阻塞式交互容器，只有用户 exit 才会返回，
        # 放在 run 之后等于在容器销毁后才复制，样本永远到不了 /home/remnux/malware/
        if ($SamplePath) {
            $targetsDir = Join-Path $Config.Workspace "linux_targets"
            try {
                $resolvedSource = (Resolve-Path -LiteralPath $SamplePath -ErrorAction Stop).Path
            } catch {
                Write-Log "[!] 无法解析样本路径: $SamplePath" "Red"
                return
            }
            $fileName = Split-Path -Leaf $resolvedSource
            $destPath = Join-Path $targetsDir $fileName

            # 防穿越：解析后的目标路径必须在 linux_targets/ 下（带分隔符，避免 linux_targets2 误判）
            $destFull = [System.IO.Path]::GetFullPath($destPath)
            $targetsFull = [System.IO.Path]::GetFullPath($targetsDir) + [System.IO.Path]::DirectorySeparatorChar
            if (-not $destFull.StartsWith($targetsFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "[!] 拒绝：目标路径逃出 linux_targets/ ($destFull)" "Red"
                return
            }

            Copy-Item -LiteralPath $resolvedSource -Destination $destPath -Force
            Write-Log "[+] 样本已复制: $fileName -> /home/remnux/malware/$fileName" "Green"
        }

        # 拼接宿主机与容器内的挂载路径
        $target = Join-Path $Config.Workspace "linux_targets"
        $output = Join-Path $Config.Workspace "output"

        # 构建挂载参数数组 (-v) 和端口映射 (-p)
        $mounts = @(
            "-v", "${target}:/home/remnux/malware",
            "-v", "${output}:/home/remnux/output",
            "-p", "$($Config.GdbPort):9999"
        )

        $extra = @() # 用于存放额外的安全/环境参数

        # 如果是 Podman 引擎，需要添加 SELinux 标签 (:Z) 和用户命名空间映射
        if ($Engine -eq "podman") {
            $mounts[1] += ":Z"
            $mounts[3] += ":Z"
            $extra += "--userns=keep-id"
        }

        # 如果用户传入了 -Isolated 开关，启用最高级别的安全隔离
        if ($Isolated) {
            $extra += "--network=none"                  # 彻底断开容器网络
            $extra += "--cap-drop=ALL"                  # 丢弃所有 Linux 特权能力
            $extra += "--security-opt=no-new-privileges" # 禁止进程通过 execve 获取新特权
        } elseif (Test-Path $Config.INetSimIPFile) {
            # INetSim 联动：非隔离模式下，将容器 DNS 指向 INetSim
            $simIP = Get-Content $Config.INetSimIPFile -Raw
            if ($simIP) {
                $simIP = $simIP.Trim()
                # 校验 IP 合法性，避免 .inetsim_ip 被篡改成任意字符串注入到 --dns 参数
                if ([System.Net.IPAddress]::TryParse($simIP, [ref]$null)) {
                    $extra += "--dns=$simIP"
                    Write-Log "[*] INetSim联动: DNS → $simIP" "Cyan"
                } else {
                    Write-Log "[!] .inetsim_ip 内容不是合法 IP（$simIP），跳过 INetSim 联动" "Yellow"
                }
            }
        }

        Write-Log "[+] Starting REMnUX container..." "Green"

        # 使用反引号 (`) 换行，使长命令更易读。传入构建好的数组参数
        # 注意：这是阻塞式交互容器，会一直跑到用户在容器内 exit 才返回
        # 显式指定 bash 作为 entrypoint——remnux/remnux-distro 默认 CMD 是 supervisord，
        # 不加 bash 的话不会给交互 shell，输入 ls/pwd 等命令也没有反应
        & $Engine run --rm -it --name $Config.ContainerName `
            $mounts $extra $Config.LinuxImage bash
    }

    # --- 停止并销毁 Linux 容器 ---
    "stop-linux" {
        Write-Log "[-] Stopping container..." "Yellow"
        # 停止并强制删除容器，使用 *> $null 忽略可能出现的 "容器不存在" 报错
        & $Engine stop $Config.ContainerName *> $null
        & $Engine rm -f $Config.ContainerName *> $null
        Write-Log "[+] Container removed" "Green"
    }

    # --- 启动 Windows 虚拟机 ---
    "start-win" {
        Write-Log "[+] Restoring snapshot..." "Green"
        # 启动前先恢复到干净快照，确保每次分析都在无毒环境中进行
        & $Config.VBoxManagePath snapshot $Config.VboxVMName restore $Config.VboxSnapshot *> $null

        # Clean_Base 快照本身可能是 saved 态（休眠快照），restore 后 VM 会处于 saved。
        # 丢弃保存态，确保 startvm 是冷启动而非从休眠唤醒（保证环境绝对干净）
        $vmState = & $Config.VBoxManagePath showvminfo $Config.VboxVMName --machinereadable 2>$null
        if ($vmState -match 'VMState="saved"') {
            Write-Log "[*] 快照为已保存态，丢弃保存态以冷启动..." "Yellow"
            & $Config.VBoxManagePath discardstate $Config.VboxVMName *> $null
        }

        Write-Log "[+] Starting VM..." "Green"
        # 以 GUI 模式启动虚拟机
        & $Config.VBoxManagePath startvm $Config.VboxVMName --type gui
    }

    # --- 重置 Windows 虚拟机 ---
    "reset-win" {
        Write-Log "[!] Powering off VM..." "Red"
        # 强制切断虚拟机电源（相当于拔插头），忽略可能因虚拟机已关闭而产生的报错
        & $Config.VBoxManagePath controlvm $Config.VboxVMName poweroff *> $null

        # 等待 3 秒，确保 VirtualBox 进程完全释放文件锁
        Start-Sleep 3

        Write-Log "[+] Restoring snapshot..." "Green"
        # 恢复到干净快照
        & $Config.VBoxManagePath snapshot $Config.VboxVMName restore $Config.VboxSnapshot

        # Clean_Base 快照本身可能是 saved 态（休眠快照），restore 后 VM 会处于 saved。
        # 丢弃保存态，确保最终是 poweroff（干净关机状态）而非 saved（休眠）
        $vmState = & $Config.VBoxManagePath showvminfo $Config.VboxVMName --machinereadable 2>$null
        if ($vmState -match 'VMState="saved"') {
            Write-Log "[*] 快照恢复后为已保存态，丢弃以彻底关机..." "Yellow"
            & $Config.VBoxManagePath discardstate $Config.VboxVMName *> $null
        }

        Write-Log "[+] Reset complete" "Cyan"
    }

    # --- 启动 INetSim 网络模拟 ---
    "start-sim" {
        # 创建 Docker 网络（如果不存在）
        # 捕获 stdout 用 2>$null（若已存在 network ls 会返回名字，create 不需要 stdout）
        $netExists = & $Engine network ls --filter "name=$($Config.INetSimNetwork)" --format "{{.Name}}" 2>$null
        if (-not $netExists) {
            Write-Log "[+] Creating Docker network: $($Config.INetSimNetwork)" "Green"
            & $Engine network create $Config.INetSimNetwork *> $null
        }

        Write-Log "[+] Starting INetSim container..." "Green"
        & $Engine run -d --rm --name $Config.INetSimName `
            --network $Config.INetSimNetwork `
            -p 53:53 -p 53:53/udp -p 80:80 -p 443:443 -p 25:25 -p 25:25/udp `
            -p 110:110 -p 143:143 -p 993:993 -p 995:995 `
            -p 3306:3306 -p 5432:5432 `
            $Config.INetSimImage *> $null

        # 轮询等待容器就绪（最多 30s），避免固定 Start-Sleep 2 在慢主机上空读 IP
        # 仅丢弃 stderr，stdout 要捕获到变量 → 用 2>$null 而非 *>$null
        $deadline = (Get-Date).AddSeconds(30)
        $inetsimIP = $null
        while ((Get-Date) -lt $deadline) {
            # 先确认容器还在（避免 stop-sim 中途把容器销毁后这里继续空转 30s）
            $exists = (& $Engine ps -a --filter "name=$($Config.INetSimName)" --format "{{.Names}}" 2>$null)
            if (-not $exists) {
                Write-Log "[*] INetSim 容器已被外部销毁，start-sim 提前退出" "Yellow"
                break
            }

            $running = (& $Engine inspect $Config.INetSimName --format "{{.State.Running}}" 2>$null)
            if ($running -and $running.Trim() -eq "true") {
                # Go 模板用 index 函数访问带连字符的网络名（"re-env-net" 不是合法 Go identifier，点语法会解析失败）
                $ipRaw = (& $Engine inspect $Config.INetSimName --format "{{(index .NetworkSettings.Networks \"$($Config.INetSimNetwork)\").IPAddress}}" 2>$null)
                # Go 模板在字段缺失时渲染为字面字符串 "null"，必须排除
                if ($ipRaw -and $ipRaw.Trim() -ne "null") {
                    $inetsimIP = $ipRaw.Trim()
                    break
                }
            }
            Start-Sleep 1
        }
        if ($inetsimIP) {
            # 用 WriteAllText + UTF8Encoding($false) 写无 BOM 的文件
            # 旧代码 Out-File -Encoding UTF8 在 PS 5.1 下会写入 BOM，导致下游 start-linux 读到 BOM 污染 --dns 参数
            [System.IO.File]::WriteAllText($Config.INetSimIPFile, $inetsimIP, $Script:Utf8NoBom)
            Write-Log "[+] INetSim started, IP: $inetsimIP" "Green"
            Write-Log "[*] DNS redirect: add --dns $inetsimIP to start-linux" "Cyan"
        } else {
            Write-Log "[!] INetSim 容器在 30s 内未就绪，无法获取 IP" "Yellow"
        }
    }

    # --- 停止 INetSim ---
    "stop-sim" {
        Write-Log "[-] Stopping INetSim..." "Yellow"
        & $Engine stop $Config.INetSimName *> $null
        & $Engine rm -f $Config.INetSimName *> $null
        # 保留网络，下次启动可复用
        if (Test-Path $Config.INetSimIPFile) { Remove-Item $Config.INetSimIPFile -Force }
        Write-Log "[+] INetSim stopped" "Green"
    }

    # --- 查看环境状态 ---
    "status" {
        # 用 StringBuilder 拼接输出，最后一次性 Write-Output（这样 subprocess 捕获 stdout 才能拿到内容）。
        # 注意：不要用 Write-Host —— 它走信息流（stream 6），ps_bridge.py 的 subprocess.run(capture_output=True) 抓不到。
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine("==== ENV STATUS ====")
        $null = $sb.AppendLine("Engine: $Engine")
        $null = $sb.AppendLine("Workspace: $($Config.Workspace)")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("[Linux Container]")
        $c = & $Engine ps -a --filter "name=$($Config.ContainerName)" --format "{{.Status}}" 2>$null
        $line = if ($c) { $c } else { "Not running" }
        $null = $sb.AppendLine($line)
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("[Windows VM]")
        $state = Get-VBoxState $Config.VboxVMName $Config.VBoxManagePath
        $null = $sb.AppendLine($state)
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("[INetSim]")
        $simState = Get-INetSimState
        $null = $sb.AppendLine($simState)
        if ((Test-Path $Config.INetSimIPFile) -and ($simState -ne "Not running")) {
            $simIP = Get-Content $Config.INetSimIPFile -Raw
            $null = $sb.AppendLine("DNS/HTTP sim: $simIP")
        }
        $sb.ToString().TrimEnd() | Write-Output
    }
}