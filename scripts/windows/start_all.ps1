# ============================================================
#  start_all.ps1 —— Windows 侧一键拉起全部服务（推荐入口）
#
#  职责划分（刻意不从 WSL 侧反向调 powershell，避免 UtilAcceptVsock 卡死）:
#    Windows 侧 : LibreHardwareMonitor(8085, 真实 CPU 温度源)
#                 主机指标 exporter(9401, CPU/温度/内存/磁盘)
#    WSL 侧     : PostgreSQL(5432) + vLLM(18020) + litellm(1234)
#                 + Prometheus(9090) + Grafana(3000) + GPU exporter(9400)
#                 + LLM 瀑布流(9410)
#
#  用法:
#    双击 start_all.bat                      （默认后端 = bonsai）
#    或: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\<你的用户名>\start_all.ps1
#
#  参数:
#    -Backend   bonsai(默认) | vllm-bonsai | vllm
#               vllm-bonsai = vLLM + prism_ternary 插件跑 Bonsai 2 27B PTQ1_0（**当前定版**）
#                             端口 18020（别名 qwen3.8-27b -> litellm 零改动）
#                             max_model_len 262144 / KV fp8 / max_num_seqs 128
#                             工具调用已开（--enable-auto-tool-choice --tool-call-parser qwen3_xml）
#                             ⚠️ 会自动先停用显存守护（守护会把 llama.cpp/原 vLLM 拉回来抢显存）
#               bonsai      = PrismML llama.cpp fork + 同一份 Bonsai 2 27B ternary 2-bit GGUF
#                             端口 18020，每路 262144 上下文，NP=3（实测上限）
#                             ⚠️ 此模式下同样会自动停用显存守护
#               vllm        = 原链路 Qwen3.8-27B-W4A16 + DFlash2，200k 上下文，MAX_SEQS=2
#    -Open      打开浏览器（默认不打开）
#    -SkipWsl   只拉起 Windows 侧组件（9401 / 8085）
#    -NoGuard   跳过监控守护拉起（bonsai / vllm-bonsai 模式下本来就跳过）
#    -Distro    WSL 发行版名，默认 Ubuntu
#
#  停止: 双击 stop_all.bat
#  切后端: start_all.bat                        (默认 = llama.cpp Bonsai M4)
#          start_all.bat -Backend vllm-bonsai   (vLLM / Bonsai)
#          start_all.bat -Backend bonsai        (llama.cpp / Bonsai, 即默认)
#          start_all.bat -Backend vllm          (原 vLLM / Qwen3.8-27B-W4A16)
# ============================================================
# --- 运行约束 ---
#  【-Backend vllm-bonsai】vLLM + prism_ternary 跑 Bonsai 2 27B PTQ1_0
#    max_model_len 262144 / max_num_seqs 128 / KV fp8 / gpu-util 0.90
#    工具调用: --enable-auto-tool-choice --tool-call-parser qwen3_xml
#    实测: KV 池 265,157 token（1.01x @256k）；解码 0→86.8 / 33k→74.1 t/s；
#          32 并发聚合 1027 t/s；280 题 88.2%
#    调参入口（全部进漂移检测，改完自动重启，见 WSL 脚本头注释）:
#      VLLM_MAX_LEN / VLLM_KV_DTYPE / VLLM_GPU_UTIL / VLLM_MAX_SEQS
#      VLLM_BATCH_TOKENS / VLLM_LONG_PREFILL / VLLM_TOOL_PARSER
#    ⚠️ 换 KV 精度要同步看容量：bf16 256k 一路要 17.2 GiB -> 起不来；
#       fp8 -> 1 路 256k；turboquant_4bit_nc -> 2 路 256k（但深层解码掉到 ~28 t/s）
#    ⚠️ gpu-util 别 ≥0.94：桌面非计算进程占 ~1.5 GiB，会直接报 free memory 不足
#
#  【-Backend vllm】(原 W4A16 + DFlash2) 运行约束（精简版；完整版见 WSL 侧 start_wsl_services.sh 头部）---
#  定版参数: CTX=huge  MAX_SEQS=2  MAX_LEN=200000  GPU_UTIL=0.93  VISION=1  SPEC=dflash2
#                （200k 上下文 / KV 池 209,059 token / 注意力块 2176 / mamba 块 128）
#                ⚠️ 240k(池 268,169) 已于 2026-09-12 降配，见 WSL 侧 start_wsl_services.sh；
#                   真值一律以 vLLM /metrics 的 cache_config_info{kv_cache_size_tokens} 为准。
#
#  ⚠️ (仅 -Backend vllm) MAX_SEQS 上限就是 2，不要再调大。这台机器的物理显存 24,564 MiB，
#     定版总提交 23,782 MiB，余量 782 MiB（占用 96.8%）。余量掉到 1% 以下即开始退化、越过物理上限必崩，WDDM 会把显存
#     挪到主机内存，性能当场塌约 10 倍（实测 MAX_SEQS=4 -> 1 路只剩 9.1 tok/s）。
#     判断退化：GPU 利用率 97-99% 但显存控制器只剩 3-9%、功耗仅 105-130W。
#     健康基线：1 路 76 tok/s / 2 路聚合 146 tok/s，显存控制器 66-73%、功耗 208-240W。
#     复核：Get-Counter '\GPU Adapter Memory(*)\Shared Usage','\GPU Adapter Memory(*)\Total Committed'
#
#  ⚠️ GPU_UTIL 在本配置下是空操作（KV_MEM 钉住 -> vLLM 跳过显存 profiling），
#     实测 0.88 与 0.93 占用完全一致，用 0.93（该档位原生值）即可，别往上调。
#
#  ⚠️ 启动日志里 "Unknown vLLM environment variable detected: XXX" 是误报，
#     不要据此删变量（补丁代码直接用 os.environ 读，只是 envs.py 没登记）。
#     详见 WSL 侧 start_wsl_services.sh 头部第 4 条。

param(
    [switch]$Open,
    [switch]$SkipWsl,
    [switch]$NoGuard,
    [ValidateSet('bonsai', 'vllm', 'vllm-bonsai')]
    [string]$Backend = 'bonsai',
    [string]$Distro = 'Ubuntu'
)

if ($Backend -notin @('bonsai', 'vllm', 'vllm-bonsai')) { $Backend = 'bonsai' }
$IS_BONSAI       = ($Backend -eq 'bonsai')
$IS_VLLM_BONSAI  = ($Backend -eq 'vllm-bonsai')

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$WIN_HOME   = $env:USERPROFILE                    # 例如 C:\Users\<你的用户名>
$WIN_MNT    = '/mnt/c/Users/' + $env:USERNAME     # 同一目录在 WSL 里的路径
$CFG_DIR    = "$WIN_HOME\monitoring_cfg"
$WIN_PY     = "$WIN_HOME\miniconda3\python.exe"
$HOST_EXP   = "$CFG_DIR\host_exporter_win.py"
$WSL_SCRIPT = if ($IS_BONSAI) {
    "$WIN_MNT/start_wsl_services_bonsai.sh"
} elseif ($IS_VLLM_BONSAI) {
    "$WIN_MNT/start_wsl_services_vllmbonsai.sh"
} else {
    "$WIN_MNT/start_wsl_services.sh"
}
$LHM_DIR    = "$WIN_HOME\LibreHardwareMonitor"
$LHM_EXE    = "$LHM_DIR\LibreHardwareMonitor.exe"
$LHM_PORT   = 8085

# 端口清单: 端口 / 名称 / 侧。18020 上跑哪个后端由 -Backend 决定。
$PORTS = @(
    @{ P = 8085;  N = 'LHM 传感器';        S = 'WIN' }
    @{ P = 9401;  N = '主机指标 exporter'; S = 'WIN' }
    @{ P = 5432;  N = 'PostgreSQL';        S = 'WSL' }
    @{ P = 18020; N = $(if ($IS_BONSAI) { 'Bonsai 2 27B (llama.cpp)' } elseif ($IS_VLLM_BONSAI) { 'Bonsai 2 27B (vLLM)' } else { 'vLLM 模型后端' }); S = 'WSL' }
    @{ P = 1234;  N = 'litellm 统一入口';   S = 'WSL' }
    @{ P = 9090;  N = 'Prometheus';        S = 'WSL' }
    @{ P = 3000;  N = 'Grafana';           S = 'WSL' }
    @{ P = 9400;  N = 'GPU exporter';      S = 'WSL' }
    @{ P = 9410;  N = 'LLM 瀑布流';         S = 'WSL' }
)

function Write-Step($n, $msg) {
    Write-Host ''
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

function Test-Port($p) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(1200, $false)
        if ($ok -and $c.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { if ($c -ne $null) { try { $c.Close() } catch {} } }
}

function Wait-Port($p, $sec) {
    for ($i = 0; $i -lt $sec; $i++) {
        if (Test-Port $p) { return $true }
        Start-Sleep -Seconds 1
    }
    return (Test-Port $p)
}

# 清代理: WSL 会把 http_proxy/HTTP_PROXY 大小写各传一份，.NET 用不区分大小写字典收
# 环境变量 -> Start-Process 抛 "已添加项。字典中的关键字:'https_proxy'"
foreach ($n in @('http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','no_proxy','NO_PROXY','ftp_proxy','FTP_PROXY')) {
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

Push-Location $WIN_HOME

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ' GPU + LLM 全栈一键启动  (Windows 侧拉起 -> WSL 内部服务)' -ForegroundColor Green
if ($IS_BONSAI) {
    Write-Host ' 模型后端: Bonsai 2 27B (ternary 2-bit) / PrismML llama.cpp CUDA' -ForegroundColor Cyan
    Write-Host '           18020 端口 · 每路 262144 上下文 · NP=3 · KV q4_0' -ForegroundColor DarkGray
} elseif ($IS_VLLM_BONSAI) {
    Write-Host ' 模型后端: Bonsai 2 27B (ternary 2-bit PTQ1_0) / vLLM + prism_ternary' -ForegroundColor Cyan
    Write-Host '           18020 端口 · max_model_len 262144 · KV turboquant_4bit · max_num_seqs 128 · CUDA graph' -ForegroundColor DarkGray
    Write-Host '           工具调用已开 (qwen3_xml) · 别名 qwen3.8-27b (litellm 零改动)' -ForegroundColor DarkGray
} else {
    Write-Host ' 模型后端: vLLM / Qwen3.8-27B-W4A16 + DFlash2' -ForegroundColor Cyan
    Write-Host '           18020 端口 · 200k 上下文 · MAX_SEQS=2' -ForegroundColor DarkGray
}
Write-Host " 发行版: $Distro    时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkGray

# ---------------- [1/4] 检查 WSL ----------------
Write-Step '1/5' '检查 WSL 环境'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Host '  [X] 未找到 wsl.exe，请先安装 WSL2' -ForegroundColor Red
    Pop-Location; exit 1
}
# WSL 侧可用性分三级探针。顺序不能省：
#   ① wsl.exe 这个**程序**能不能被启动   -> 与发行版无关，被安全策略拦住时会在这一级暴露
#   ② 有没有发行版能执行 bash            -> 工具 VM / 发行版状态
#   ③ 发行版能不能看见 Windows 文件系统  -> drvfs 挂载
# 历史上这三件事被合成一句"发行版 'Ubuntu' 不可用"，把"程序被黑名单拦住"误报成
# "发行版没装"，白查半天。所以必须分开报。
#
# 另外，① 通过而 ② 失败时也要先 `wsl --shutdown` 重建一次再放弃 —— 见下面 [1/5] 注释。
$script:WSL_LAUNCH_ERR = ''

function Test-WslLaunch {
    # 只判断 wsl.exe 这个**程序**能否被启动（与发行版无关），用来把
    # 「程序被安全策略/黑名单拦住」和「发行版不可用」这两件事分开报。
    #
    # 两条弯路（都实测过，别再走）：
    #   ① 用 `& wsl.exe` 且不处理错误流 —— 全局 $ErrorActionPreference='Continue' 下
    #      启动失败只写进错误流、不抛异常，被掩成"没有输出"，下游就报成
    #      "发行版 'Ubuntu' 不可用"，完全指错方向。
    #   ② 临时把 $ErrorActionPreference 提成 'Stop' —— 又走到另一个极端：
    #      程序正常往 stderr 写一行告警也会变成终止性错误。
    #      实测 hostname.exe 只因输出了用法提示就被误判成"无法启动"。
    #      wsl.exe 正常工作时恰恰会往 stderr 写 "Failed to translate ..."。
    #
    # 所以正确做法：保持 'Continue'，把错误流原文抓下来，**只按启动失败的特征词判定**，
    # 并把原文留作证据给用户看。判错的代价只是提示不够精确 —— 后面的 bash 探针
    # 仍然会拦住真正不可用的情况。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $combined = ''
    try {
        $combined = (& wsl.exe --status 2>&1 | Out-String).Trim()
    } catch {
        $combined = [string]$_.Exception.Message
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $script:WSL_LAUNCH_ERR = $combined
    if ($combined -match 'failed to run|Access is denied|拒绝访问|无法将|不是内部或外部命令') {
        return $false
    }
    return $true
}

# 不要用 `wsl -l -q` 判断发行版 —— 它的输出是 UTF-16，PowerShell 解析不稳定
function Test-WslBash([string]$name) {
    $a = @()
    if ($name -ne '') { $a += @('-d', $name) }
    $a += @('--', 'bash', '-lc', 'echo WSL_OK; exit 0')
    try { return ((((& wsl.exe @a 2>$null) | Out-String) -match 'WSL_OK')) } catch { return $false }
}

function Test-WslMount([string]$name) {
    # drvfs 失挂时 /mnt/c 是空目录，$WSL_SCRIPT 就"不存在" -> 报 127。
    # 用脚本文件本身当探针最直接。
    $a = @()
    if ($name -ne '') { $a += @('-d', $name) }
    $a += @('--', 'bash', '-lc', "test -f $WSL_SCRIPT && echo VIS_OK || echo VIS_BAD")
    try { return ((((& wsl.exe @a 2>$null) | Out-String) -match 'VIS_OK')) } catch { return $false }
}

function Invoke-WslRebuild {
    # 整个工具 VM 拆掉重建。只 `wsl --terminate <发行版>` 不够 —— 命名空间在 VM 层。
    Write-Host '      （这会一并停掉 WSL 里所有服务，稍后由 WSL 脚本重新拉起）' -ForegroundColor DarkGray
    try { & wsl.exe --shutdown 2>$null | Out-Null } catch { }
    Start-Sleep -Seconds 8
}

$useDistro = $Distro

if (-not (Test-WslLaunch)) {
    $detail = (($script:WSL_LAUNCH_ERR -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 2) -join ' / '
    Write-Host '  [X] wsl.exe 无法启动 —— 是「程序被拦」，不是发行版的问题' -ForegroundColor Red
    Write-Host "      原始报错: $detail" -ForegroundColor DarkGray
    Write-Host '      处理: 安全中心 > 命令安全 > 程序黑名单，把 wsl.exe 移除' -ForegroundColor Yellow
    Write-Host '      只要它还在名单里，本脚本、以及任何从编辑器/终端发起的 WSL 调用都会失败；' -ForegroundColor DarkGray
    Write-Host '      但已经在跑的 WSL 服务不受影响（vmmemWSL / wslservice 照常在）。' -ForegroundColor DarkGray
    $SkipWsl = $true
} else {
    $probeOk = (Test-WslBash $useDistro)
    if (-not $probeOk) {
        Write-Host "  [!] 发行版 '$useDistro' 执行 bash 失败，尝试默认发行版..." -ForegroundColor Yellow
        if (Test-WslBash '') { $useDistro = ''; $probeOk = $true }
    }
    # ⚠️ 这里也必须给一次重建机会：上一轮 drvfs 失挂（ConfigRemountDrvFsImpl）会让
    #    整个工具 VM 处于半死状态，表现可能就是 bash 探针直接失败。
    #     早期版本把重建逻辑只挂在"挂载探测失败"上，于是这种机器连回滚的机会都没有。
    if (-not $probeOk) {
        Write-Host '  [!] 无发行版可执行 bash —— 重建 WSL 工具 VM 后重试...' -ForegroundColor Yellow
        Invoke-WslRebuild
        if (Test-WslBash $useDistro) {
            $probeOk = $true
        } elseif (Test-WslBash '') {
            $useDistro = ''
            $probeOk = $true
        }
    }
    if (-not $probeOk) {
        Write-Host '  [X] WSL 仍不可用，跳过 WSL 侧，仅拉起 Windows 侧组件' -ForegroundColor Red
        Write-Host '      手动排查: wsl -l -v        （看发行版是否还在）' -ForegroundColor DarkGray
        Write-Host '                wsl -d Ubuntu -- bash -lc "echo hi"' -ForegroundColor DarkGray
        $useDistro = $null
        $SkipWsl = $true
    } else {
        Write-Host "  [OK] WSL 发行版可用: $useDistro" -ForegroundColor Green
        # --- ③ 能不能看见 Windows 文件系统 ---
        # 已知故障（2026-09-23 实测）：WSL 轻量级工具 VM 长时间不重启，而中途只有发行版
        # 单独重启过一次时，drvfs 重挂失败，内核日志留下：
        #   WSL (2 - init-systemd(Ubuntu)) ERROR: ConfigRemountDrvFsImpl:2256:
        #   Non-Admin namespace already initialized
        # 后果：/mnt/c /mnt/d /mnt/e ... 全变空目录，WSL 侧看不到任何 Windows 文件。
        # 症状：wsl.exe 刷一整屏 "Failed to translate 'C:\...'"，然后 WSL 脚本报 127。
        # ⚠️ PostgreSQL 这类 systemd 服务不受影响、照样活着，别把"5432 在"当 WSL 健康。
        if (Test-WslMount $useDistro) {
            Write-Host '  [OK] WSL 已挂载 Windows 文件系统' -ForegroundColor Green
        } else {
            Write-Host '  [!] WSL 看不到 Windows 文件系统（/mnt/* 未挂载）—— 重建 WSL 工具 VM...' -ForegroundColor Yellow
            Invoke-WslRebuild
            if (Test-WslMount $useDistro) {
                Write-Host '  [OK] 已恢复（wsl --shutdown 重建成功）' -ForegroundColor Green
            } else {
                Write-Host '  [X] 挂载仍然失败，跳过 WSL 侧' -ForegroundColor Red
                Write-Host '      查证据: wsl -d Ubuntu -- dmesg | grep -i drvfs' -ForegroundColor DarkGray
                Write-Host '      仍不行: 检查第三方 WSL 代理/防火墙，或重启 Windows' -ForegroundColor DarkGray
                $SkipWsl = $true
            }
        }
    }
}

# ---------------- [2/4] Windows 侧: LHM(8085) + 主机指标 exporter(9401) ----------------
Write-Step '2/5' 'Windows 侧: LibreHardwareMonitor(8085) + 主机指标 exporter(9401)'

# --- LHM：exporter 靠它拿真实 CPU 温度（ACPI 热区在本机是固定占位值）---
# 去重判据 = 进程 AND 端口，只看端口不够：
#   LHM 允许同时跑多个实例，若仅判端口，则在「进程在、但 web server 没开」时会
#   再拉一个实例出来（反复双击会越堆越多）。故先查进程，只要进程已在就不再启动。
#   进程在 + 端口在   -> 完全就绪，跳过
#   进程在 + 端口不在 -> 已在运行但 web server 没开；不启动新实例，只提示手动开
#   进程不在          -> 才启动
$lhmProc = @(Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)
$lhmPort = Test-Port $LHM_PORT

if ($lhmProc.Count -gt 0 -and $lhmPort) {
    Write-Host ("  [OK] LHM 已在运行 (PID {0}) 且 :{1} 已监听（真实 CPU 温度可用）—— 跳过启动" -f $lhmProc[0].Id, $LHM_PORT) -ForegroundColor Green
} elseif ($lhmProc.Count -gt 0) {
    Write-Host ("  [OK] LHM 进程已在运行 (PID {0}) —— 不再启动第二个实例" -f $lhmProc[0].Id) -ForegroundColor Green
    Write-Host "  [!] 但其 web server :$LHM_PORT 未监听 —— 请在 LHM 窗口里开一次:" -ForegroundColor Yellow
    Write-Host '      Options > Remote Web Server > Run (端口 8085)' -ForegroundColor DarkGray
} elseif (-not (Test-Path $LHM_EXE)) {
    Write-Host '  (未安装 LHM，跳过；CPU 温度将标记为不可用)' -ForegroundColor DarkGray
} else {
    Write-Host '  启动 LibreHardwareMonitor（会弹 UAC，需确认）...' -ForegroundColor DarkGray
    try { Start-Process -FilePath $LHM_EXE -WorkingDirectory $LHM_DIR -Verb RunAs | Out-Null } catch {}
    if (Wait-Port $LHM_PORT 25) {
        Write-Host "  [OK] LHM web server :$LHM_PORT 已监听" -ForegroundColor Green
    } else {
        Write-Host "  [!] :$LHM_PORT 未监听 —— 需在 LHM 里手动开一次:" -ForegroundColor Yellow
        Write-Host '      Options > Remote Web Server > Run (端口 8085)' -ForegroundColor DarkGray
    }
}

# --- 主机指标 exporter 9401 ---
# 关键：必须从 Windows 侧启动。历史上从 WSL 调 powershell.exe 启动的进程，
# 会在 WSL 会话回收时被一起带走（日志有 listening 但进程随即消失）。
if (Test-Port 9401) {
    Write-Host '  [OK] 9401 已在监听，跳过' -ForegroundColor Green
} elseif (-not (Test-Path $WIN_PY)) {
    Write-Host "  [X] 未找到 python: $WIN_PY" -ForegroundColor Red
} elseif (-not (Test-Path $HOST_EXP)) {
    Write-Host "  [X] 未找到脚本: $HOST_EXP" -ForegroundColor Red
} else {
    $started = $false
    try {
        Start-Process -FilePath $WIN_PY -ArgumentList @($HOST_EXP) `
            -WorkingDirectory $CFG_DIR -WindowStyle Hidden `
            -RedirectStandardOutput "$CFG_DIR\host_exporter_win.log" `
            -RedirectStandardError  "$CFG_DIR\host_exporter_win.log.err" | Out-Null
        $started = (Wait-Port 9401 15)
    } catch {
        Write-Host "  [!] Start-Process 失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if (-not $started) {
        # 兜底: WMI Win32_Process.Create —— 脱离当前进程树，受限会话下比 Start-Process 稳
        Write-Host '  换用 WMI 方式启动...' -ForegroundColor DarkGray
        try {
            $cls = [wmiclass]'Win32_Process'
            if ($cls.Create("`"$WIN_PY`" `"$HOST_EXP`"", $CFG_DIR).ReturnValue -eq 0) {
                $started = (Wait-Port 9401 15)
            }
        } catch {
            Write-Host "  [!] WMI 启动失败: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($started) { Write-Host '  [OK] 9401 已监听' -ForegroundColor Green }
    else { Write-Host '  [!] 9401 未起来，查看 monitoring_cfg\host_exporter_win.log.err' -ForegroundColor Yellow }
}

# ---------------- [2.5/5] Bonsai 模式: 先停显存守护（必须在拉起模型之前）----------------
# 守护带 -Watch -EnableRestart：一旦发现 vLLM 不在，就会调 restart_vllm.sh --force
# 把它拉回来。Bonsai 与 vLLM 抢同一张 24G 卡，所以必须先把守护停掉再动模型。
if (($IS_BONSAI -or $IS_VLLM_BONSAI) -and -not $SkipWsl) {
    Write-Step '2.5/5' ($(if ($IS_BONSAI) { 'Bonsai' } else { 'vLLM-Bonsai' }) + ' 模式: 停用显存守护（否则它会在 30 秒内把原 vLLM 拉回来抢显存）')
    try {
        # 字面量写死: $GUARD_TASK 在本步骤之后才定义，这里还不能引用
        Disable-ScheduledTask -TaskName 'GPU_VRAM_Overcommit_Guard' -ErrorAction SilentlyContinue | Out-Null
        Write-Host '  [OK] 已禁用计划任务 GPU_VRAM_Overcommit_Guard' -ForegroundColor Green
    } catch { }
    # ⚠️ 匹配串的完整字面量不能出现在本进程自己的命令行里，否则会把正在跑的
    #    脚本自己匹配上并杀掉（本文件里正好有这个字符串）。用拼接规避。
    $gpat = 'gpu_' + 'overcommit_' + 'guard'
    $gp = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$gpat*" })
    if ($gp.Count -gt 0) {
        foreach ($p in $gp) {
            Write-Host ("  [OK] 停掉守护进程 PID {0}" -f $p.ProcessId) -ForegroundColor Green
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Host '  [OK] 没有正在运行的守护进程' -ForegroundColor Green
    }
}

# ---------------- [3/4] WSL 侧 ----------------
if ($SkipWsl) {
    Write-Step '3/5' 'WSL 侧: 已跳过'
} else {
    $backendName = if ($IS_BONSAI) { 'Bonsai / llama.cpp' } elseif ($IS_VLLM_BONSAI) { 'Bonsai / vLLM' } else { 'vLLM' }
    Write-Step '3/5' "WSL 侧: 执行 $WSL_SCRIPT ($backendName + PG + litellm + 监控)"
    # WSL 侧脚本输出 UTF-8，而 PowerShell 默认按控制台 OEM 码页（GBK）解码子进程输出，
    # 结果整段中文变乱码（'侧服务启动' -> '渚ф湇鍔″惎鍔'）。必须同时修两件事：
    #   ① chcp 65001 —— 控制台码页本身要是 UTF-8（.bat 里已有，但直接调 ps1 时没有）
    #   ② [Console]::OutputEncoding —— 决定 PowerShell 按什么编码解码子进程 stdout
    # 两句都必须放在调用 wsl.exe 之前。
    try { & "$env:SystemRoot\System32\chcp.com" 65001 | Out-Null } catch { }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $wslArgs = @()
    if ($useDistro -ne '') { $wslArgs += @('-d', $useDistro) }
    $wslArgs += @('--', 'bash', '-lc', "bash $WSL_SCRIPT")
    Write-Host ("  > wsl.exe " + ($wslArgs -join ' ')) -ForegroundColor DarkGray
    & wsl.exe @wslArgs
    Write-Host "  WSL 脚本返回码: $LASTEXITCODE" -ForegroundColor DarkGray
}

# ---------------- [4/5] 显存超配守护 ----------------
# 这台机器 24 GiB 显存装不下「大上下文 + 图像 + 安全余量」，committed 会以
# 约 30 MiB/小时 缓慢抬升，越过物理上限后 WDDM 把显存兜底到主机内存，
# 推理静默从 ~80 tok/s 掉到 <1 tok/s（没有任何报错）。guard 负责检测并重启回收。
#
# 这里只保证「计划任务存在」；已存在就跳过，不重复创建。
# 停用：删除任务，或用 -NoGuard 跳过本步
#   schtasks /Delete /TN GPU_VRAM_Overcommit_Guard /F
$GUARD_TASK = 'GPU_VRAM_Overcommit_Guard'
$GUARD_PS1  = "$CFG_DIR\gpu_overcommit_guard.ps1"
# 用完整路径调 schtasks：受限会话（精简 PATH 的沙箱等）里它可能不在 PATH 上，
# 那时 `schtasks ...` 会直接报 "无法将 schtasks 项识别为 cmdlet"，本步骤静默失效。
$SCHTASKS   = "$env:SystemRoot\System32\schtasks.exe"

if ($IS_BONSAI -or $IS_VLLM_BONSAI) {
    # Bonsai / vLLM-Bonsai 模式跑的是「显存感知」守护：只做一件事 —— 服务掉了且显存确实空着，就拉起来。
    # 与 vLLM 的 gpu_overcommit_guard 不能共存：后者带 -EnableRestart 会把原 vLLM 拉回来抢显存
    # （已在 [2.5/5] 步停掉）。
    Write-Step '4/5' ($(if ($IS_BONSAI) { 'Bonsai 服务守护' } else { 'vLLM-Bonsai 服务守护' }) + ': 服务掉了且显存空着就自动拉起')
    $BONSAI_GUARD = "$CFG_DIR\bonsai_guard.ps1"
    # vllm-bonsai 用同一条守护，只是把「重启动作」换成拉起 vLLM 的 WSL 脚本
    $GUARD_RESTART = if ($IS_VLLM_BONSAI) { "$WIN_MNT/start_wsl_services_vllmbonsai.sh" } else { '' }
    if (-not (Test-Path $BONSAI_GUARD)) {
        Write-Host "  [X] 未找到 $BONSAI_GUARD" -ForegroundColor Red
    } elseif ($SkipWsl) {
        Write-Host '  [!] WSL 侧已跳过 —— 守护也一并跳过（否则它只会反复空转）' -ForegroundColor Yellow
    } else {
        # 匹配条件必须同时含 -File / -EnableRestart / -Watch：
        # 只按 'bonsai_guard' 匹配会误命中"命令文本里提到该字符串"的其他进程。
        # 用拼接规避自身命令行被匹配（同 gpu guard 的教训）。
        $bpat = 'bonsai_' + 'guard.ps1'
        # bonsai 与 vllm-bonsai 共用同一条守护脚本，靠 -RestartScript 里的 'vllmbonsai' 区分。
        # 两个后端的守护不能并存（都会抢同一张卡重启），先把「另一个后端」的守护停掉。
        $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like "*$bpat*" -and $_.CommandLine -like '*-Watch*' -and
                                   (($IS_VLLM_BONSAI -and $_.CommandLine -notlike '*vllmbonsai*') -or
                                    ((-not $IS_VLLM_BONSAI) -and $_.CommandLine -like '*vllmbonsai*')) })
        foreach ($p in $others) {
            Write-Host ("  [OK] 停掉另一后端的守护 PID {0}" -f $p.ProcessId) -ForegroundColor Green
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($others.Count -gt 0) { Start-Sleep -Seconds 2 }
        $brun = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -like "*$bpat*" -and $_.CommandLine -like '*-EnableRestart*' -and $_.CommandLine -like '*-Watch*' -and ($IS_VLLM_BONSAI -eq $false -or $_.CommandLine -like '*vllmbonsai*') })
        if ($brun.Count -gt 0) {
            Write-Host ("  [OK] 守护已在运行（PID {0}）" -f $brun[0].ProcessId) -ForegroundColor Green
        } else {
            try {
                $bArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                           '-WindowStyle','Hidden','-File',$BONSAI_GUARD,'-EnableRestart','-Watch')
                if ($GUARD_RESTART -ne '') { $bArgs += @('-RestartScript', $GUARD_RESTART) }
                Start-Process -FilePath 'powershell.exe' -ArgumentList $bArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null
                Start-Sleep -Seconds 3
                $chk = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                         Where-Object { $_.CommandLine -like "*$bpat*" -and $_.CommandLine -like '*-EnableRestart*' -and $_.CommandLine -like '*-Watch*' -and ($IS_VLLM_BONSAI -eq $false -or $_.CommandLine -like '*vllmbonsai*') })
                if ($chk.Count -gt 0) {
                    Write-Host ("  [OK] 已隐藏拉起守护（PID {0}，无窗口）" -f $chk[0].ProcessId) -ForegroundColor Green
                } else {
                    Write-Host '  [!] 拉起后未检测到进程，见 monitoring_cfg\bonsai_guard.log' -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("  [!] 拉起失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        Write-Host '       判据: :18020 /health 不通 或 :1234 不通（连续 4 次 ≈ 60 秒）' -ForegroundColor DarkGray
        Write-Host '       闸门: 只在显存 <= 1000 MiB（基本空着）时才启动；被占则只记录不动手' -ForegroundColor DarkGray
        Write-Host '       限流: 冷却 10 分钟；每小时最多 3 次' -ForegroundColor DarkGray
        Write-Host '       日志: monitoring_cfg\bonsai_guard.log' -ForegroundColor DarkGray
        Write-Host '       暂停: 新建空文件 monitoring_cfg\bonsai_guard.pause' -ForegroundColor DarkGray
    }
} elseif ($NoGuard) {
    Write-Step '4/5' '显存超配守护: 已跳过 (-NoGuard)'
} elseif (-not (Test-Path $GUARD_PS1)) {
    Write-Step '4/5' '显存超配守护'
    Write-Host "  [X] 未找到 $GUARD_PS1" -ForegroundColor Red
} else {
    Write-Step '4/5' '监控守护: 以隐藏常驻进程方式拉起（不再用计划任务）'
    # 历史教训（2026-09-12）：计划任务每分钟新建一个进程，Windows 会先为它创建
    # conhost 控制台，`-WindowStyle Hidden` 来不及拦 → 每分钟闪一次黑窗。
    # 现在改为：常驻单进程 + 由本脚本以 -WindowStyle Hidden **只创建一次**。
    # 窗口只在创建那一刻决定，之后进程内部自己 sleep 循环，因此不会再闪。
    try {
        $st = Get-ScheduledTask -TaskName $GUARD_TASK -ErrorAction SilentlyContinue
        if ($st -and $st.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskName $GUARD_TASK -ErrorAction SilentlyContinue | Out-Null
            Write-Host '  [OK] 已禁用旧的计划任务（改走常驻进程，避免黑窗）' -ForegroundColor Green
        }
    } catch { }

    # 匹配条件必须同时含 -File / -EnableRestart / -Watch：
    # 只按 'gpu_overcommit_guard' 匹配会误命中"命令文本里提到该字符串"的其他进程
    # （2026-09-12 实测：我自己的调试命令就被误判成 1 个残留守护进程）。
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -like '*gpu_overcommit_guard*' -and $_.CommandLine -like '*-EnableRestart*' -and $_.CommandLine -like '*-Watch*' })
    if ($running.Count -gt 0) {
        Write-Host ("  [OK] 监测已在运行（PID {0}）" -f ($running[0].ProcessId)) -ForegroundColor Green
    } else {
        try {
            $gArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                       '-WindowStyle','Hidden','-File',$GUARD_PS1,'-EnableRestart','-Watch')
            Start-Process -FilePath 'powershell.exe' -ArgumentList $gArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 3
            $chk = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -like '*gpu_overcommit_guard*' -and $_.CommandLine -like '*-EnableRestart*' -and $_.CommandLine -like '*-Watch*' })
            if ($chk.Count -gt 0) {
                Write-Host ("  [OK] 已隐藏拉起监测（PID {0}，无窗口）" -f ($chk[0].ProcessId)) -ForegroundColor Green
            } else {
                Write-Host '  [!] 拉起后未检测到进程，请查看 monitoring_cfg\gpu_guard.log' -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("  [!] 拉起失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Write-Host '       节奏: 常驻、每 10 秒采样一次；连续 3 次命中即重启 vLLM' -ForegroundColor DarkGray
    Write-Host '       判据: 显存超配 / loopback 失效 / 引擎停滞(有请求但 token 零增长)' -ForegroundColor DarkGray
    Write-Host '       日志: monitoring_cfg\gpu_guard.log   停止: stop_all.bat' -ForegroundColor DarkGray
}

# ---------------- [5/5] 端口汇总 ----------------
Write-Step '5/5' '端口健康检查'
$bad = @()
foreach ($x in $PORTS) {
    if (Test-Port $x.P) {
        Write-Host ("  [OK]   {0,-6} {1,-22} ({2})" -f $x.P, $x.N, $x.S) -ForegroundColor Green
    } else {
        Write-Host ("  [DOWN] {0,-6} {1,-22} ({2})" -f $x.P, $x.N, $x.S) -ForegroundColor Red
        $bad += "$($x.P) $($x.N)"
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host '  入口地址' -ForegroundColor Green
Write-Host '   litellm UI   : http://127.0.0.1:1234/ui    (密码 = master_key)'
Write-Host '   OpenAI API   : http://127.0.0.1:1234/v1     (模型名 qwen3.8-27b / claude-* 等)'
if ($IS_BONSAI) {
    Write-Host '   llama.cpp    : http://127.0.0.1:18020/v1/models  (直连)'
    Write-Host '   slot 状态    : http://127.0.0.1:18020/slots      (每路 262144 上下文)'
} elseif ($IS_VLLM_BONSAI) {
    Write-Host '   vLLM 直连     : http://127.0.0.1:18020/v1/models  (Bonsai 2 27B PTQ1_0)'
    Write-Host '   别名          : qwen3.8-27b                     (litellm 零改动)'
} else {
    Write-Host '   vLLM 直连     : http://127.0.0.1:18020/v1/models'
}
Write-Host '   Grafana      : http://127.0.0.1:3000        (admin/admin)'
Write-Host '   Prometheus   : http://127.0.0.1:9090'
Write-Host '   瀑布流网页    : http://127.0.0.1:9410/       (实时输入/输出/思考过程)'
Write-Host '   GPU 指标      : http://127.0.0.1:9400/metrics (WSL 侧)'
Write-Host '   主机指标      : http://127.0.0.1:9401/metrics (Windows 侧)'
if ($bad.Count -gt 0) {
    Write-Host "  未就绪: $($bad -join ', ')" -ForegroundColor Yellow
    $sess = if ($IS_BONSAI) { 'bonsai' } elseif ($IS_VLLM_BONSAI) { 'vllmbonsai' } else { 'vllm' }
    Write-Host "  排查: wsl -d Ubuntu -- tmux attach -t $sess     (模型日志)" -ForegroundColor DarkGray
    Write-Host '        wsl -d Ubuntu -- tmux attach -t litellm  (网关日志)' -ForegroundColor DarkGray
    Write-Host '        wsl -d Ubuntu -- tail -50 $HOME/monitoring/*.log' -ForegroundColor DarkGray
} else {
    Write-Host '  全部就绪' -ForegroundColor Green
}
if ($IS_BONSAI) {
    Write-Host '  提示: 长 prompt prefill 是算力受限（~1500 t/s 起），深上下文解码会降到 ~32 t/s 属正常' -ForegroundColor DarkGray
} elseif ($IS_VLLM_BONSAI) {
    Write-Host '  提示: 首启要 torch.compile + CUDA graph 捕获（约 2-4 分钟）才算就绪，属正常' -ForegroundColor DarkGray
    Write-Host '        实测: 单流 decode 64~87 t/s（同档 llama.cpp）；并发 4 路聚合 ~270 t/s' -ForegroundColor DarkGray
} else {
    Write-Host '  提示: 重启后首次发图片请求会有约 65s 视觉编码器预热，属正常' -ForegroundColor DarkGray
}
Write-Host '============================================================' -ForegroundColor DarkGray

if ($Open) {
    Start-Sleep -Seconds 2
    Start-Process 'http://127.0.0.1:3000/d/gpu-llm-full-monitor' -ErrorAction SilentlyContinue
    Start-Process 'http://127.0.0.1:9410/' -ErrorAction SilentlyContinue
}

Pop-Location
