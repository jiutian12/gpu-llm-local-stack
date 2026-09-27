# -*- coding: utf-8 -*-
<#
.SYNOPSIS
  Bonsai 2 27B 服务守护 —— 服务停了就拉起来，但**只在显存确实空着**的时候才动手。

.DESCRIPTION
  与 gpu_overcommit_guard.ps1 的分工（两者不能同时跑）：

    gpu_overcommit_guard.ps1  管 vLLM 链路（显存超配 / loopback 失效 / 引擎停滞），
                              它带 -EnableRestart，会把 vLLM 拉回来抢显存，
                              所以 Bonsai 模式下必须先停掉它。
    bonsai_guard.ps1          管 Bonsai 链路，只做一件事：
                              服务掉了 + 显存是空的 -> 重新拉起。

  为什么必须加「显存是空的」这个前提：
    24 GiB 卡上 Bonsai 与 vLLM 无法共存。若服务掉了而显存仍被别的进程占着，
    直接重启会走进 WDDM 显存超配 —— 表现是**能加载、日志无任何报错**，
    但真填上下文时 prefill 从 ~1500 t/s 崩到 16 t/s（板卡功耗 297W -> 96W）。
    所以本守护在显存不空时**只记录、不动作**，等它自己空出来。

  健康判据（两个都要通过）:
    模型后端 18020 : TCP 可连 + GET /health 返回 200
    网关     1234 : TCP 可连
  任一连续 $ConsecutiveChecks 次不通、并且显存空着，才执行启动。

  启动动作 = WSL 侧 start_wsl_services_bonsai.sh（幂等、带配置漂移检测），
  它会把 PostgreSQL / 模型 / litellm / 监控一并补齐。

.PARAMETER IntervalSec
  采样间隔，默认 15 秒。常驻模式下进程内部自己 sleep，不依赖计划任务
  （计划任务每分钟新建进程会闪黑窗，2026-09-12 已废弃）。

.PARAMETER ConsecutiveChecks
  连续多少次判定为"服务已停"才动作。默认 4（15s x 4 = 60 秒）。
  调大更保守，调小更快恢复，但太小时会把"正在加载"误判成"已停止"。

.PARAMETER FreeVramMiB
  显存"算作空着"的阈值（MiB），默认 1000。
  实测本机无模型时 nvidia-smi memory.used 为 0 MiB，所以 1000 已经相当宽松。

.PARAMETER StartupGraceSec
  启动宽限期：本进程刚起、或刚执行过一次启动之后的这段时间内不动作。
  默认 180 秒 —— llama.cpp 加载 5.9 GB + 分配 KV 要约 10~30 秒，
  不设宽限会把"正在加载"当成"没起来"，反复重启。

.PARAMETER CooldownMinutes
  两次自动启动之间的最小间隔，默认 10 分钟。

.PARAMETER MaxRestartsPerHour
  每小时的自动启动次数上限（熔断），默认 3。
  超过就只告警不动作 —— 反复重启说明有更根本的问题，不该继续刷。

.PARAMETER StallSec
  「引擎停滞」判定阈值，默认 120 秒。
  **服务活着 ≠ 引擎在干活** —— llama.cpp 卡死时 /health 照样返回 200，
  只有 /slots 的进度计数是诚实的。实测 2026-09-25：一个 46k token 的 prefill
  卡在 slot 上，90 秒只推进 26 个 token（健康时应是 ~1000+ t/s），
  而 /health 一直是 200。本判据读 /slots 的 n_prompt_tokens + n_decoded 累计值，
  若「有 slot 在处理」但累计值连续 StallSec 秒不增长，即判为停滞并告警。

.PARAMETER CleanStale
  **实验性、默认关闭**。服务停了、显存却被占着，而且 GPU 处于「假忙」状态  （显存控制器无流量 + 功耗 < 150W）时，先杀掉 WSL 里残留的 llama-server / vllm 再启动。
  判据来自实测（2026-09-25）：显存"被占着但没人算"通常就是崩溃/被 kill 后
  没释放的僵尸 CUDA 上下文 —— 实测表现为**利用率 100%、显存控制器 0%、功耗 98W**，
  占用挂在 vmwp.exe（WSL2 虚拟机进程）上。
  ⚠️ 只 `pkill` 未必能释放僵尸上下文，必要时仍需 `wsl --shutdown`。
  ⚠️ 会杀进程，风险自负；开启前请确认没有别的任务在用同一张卡。

.PARAMETER PauseFile
  存在这个文件就暂停动作（只采样、只记录）。默认
  monitoring_cfg\bonsai_guard.pause。想在 stop_all 之后保持停机状态时创建它。

.EXAMPLE
  # 常驻模式（推荐；由 start_all.ps1 隐藏拉起）
  powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden `
    -File bonsai_guard.ps1 -EnableRestart -Watch

.EXAMPLE
  # 单次检查，只看判定过程，不动作
  powershell -NoProfile -ExecutionPolicy Bypass -File bonsai_guard.ps1 -ChecksPerRun 1 -DryRun
#>
[CmdletBinding()]
param(
    [int]   $IntervalSec         = 15,
    [int]   $ConsecutiveChecks   = 4,
    [double]$FreeVramMiB         = 1000,
    [int]   $StartupGraceSec     = 180,
    [int]   $CooldownMinutes     = 10,
    [int]   $MaxRestartsPerHour  = 3,
    [int]   $StallSec            = 120,
    [double]$MinProgTps          = 5,
    [int]   $ModelPort           = 18020,
    [int]   $GatewayPort         = 1234,
    [string]$WslDistro           = 'Ubuntu',
    [string]$RestartScript       = '/mnt/c/Users/administrat0r/start_wsl_services_bonsai.sh',
    [int]   $ChecksPerRun        = 1,
    [switch]$EnableRestart,
    [switch]$CleanStale,
    [switch]$Watch,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$CfgDir  = 'C:\Users\administrat0r\monitoring_cfg'
$StateFi = Join-Path $CfgDir 'bonsai_guard_state.json'
$LogFi   = Join-Path $CfgDir 'bonsai_guard.log'
$PauseFi = Join-Path $CfgDir 'bonsai_guard.pause'
$NvSmi   = "$env:SystemRoot\System32\nvidia-smi.exe"

# 函数间传诊断信息的 script 作用域变量（别用局部变量 —— 函数里赋值不会外传）
$script:SlotReadErr    = ''
$script:LastSlotErrLog = 0

# WSL 会往环境里塞 http_proxy/HTTP_PROXY，.NET 的 HttpWebRequest 会因此报错，
# 所以本进程内先把它们清掉（只影响本进程）。
foreach ($n in @('http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','no_proxy','NO_PROXY')) {
    if (Test-Path "Env:$n") { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
}

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    if (-not $DryRun) {
        if ((Test-Path $LogFi) -and ((Get-Item $LogFi).Length -gt 524288)) {
            Move-Item $LogFi "$LogFi.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogFi -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Test-Tcp([int]$port, [int]$timeoutMs = 1500) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $c.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { if ($c) { try { $c.Close() } catch { } } }
}

function Test-Health([int]$port, [int]$timeoutSec = 6) {
    # llama.cpp 的 /health 就绪时返回 200 {"status":"ok"}
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/health")
        $req.Proxy = $null
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch { return $false }
}

function ConvertTo-Num($v) {
    # nvidia-smi 在部分状态下会输出 [N/A]，直接 [double] 转换会抛异常
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if ($s -eq '' -or $s -match 'N/?A') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d)) { return $d }
    return $null
}

function Get-Gpu {
    <# 直接问 NVML，不依赖 WSL 侧的 9400 exporter ——
       本守护要判定的恰恰是"WSL 可能已经挂了"，那时 exporter 也一起没了。 #>
    if (-not (Test-Path $NvSmi)) { return $null }
    try {
        $o = & $NvSmi --query-gpu=memory.used,memory.total,utilization.gpu,utilization.memory,power.draw --format=csv,noheader,nounits 2>$null
        $t = [string](@($o) | Select-Object -First 1)
        $p = $t -split ','
        if ($p.Count -lt 5) { return $null }
        $used = ConvertTo-Num $p[0]
        if ($null -eq $used) { return $null }
        return @{
            Used    = $used
            Total   = ConvertTo-Num $p[1]
            Util    = ConvertTo-Num $p[2]
            UtilMem = ConvertTo-Num $p[3]   # 显存控制器利用率：判定"假忙"的关键信号
            Power   = ConvertTo-Num $p[4]
        }
    } catch { return $null }
}

function Get-GpuText($g) {
    if ($null -eq $g) { return '显存读数失败（nvidia-smi 不可用）' }
    $s = ('显存 {0:N0}/{1:N0} MiB' -f $g.Used, $g.Total)
    if ($null -ne $g.Util)    { $s += (' 利用率 {0:N0}%' -f $g.Util) }
    if ($null -ne $g.UtilMem) { $s += (' 显存控制器 {0:N0}%' -f $g.UtilMem) }
    if ($null -ne $g.Power)   { $s += (' 功耗 {0:N0}W' -f $g.Power) }
    return $s
}

function Test-FakeBusy($g) {
    <# GPU「假忙」：显存被占着，但**没有任何显存流量**、功耗也远低于正常工作水平。
       正常工作（prefill / decode）功耗 230~400W 且显存控制器有持续流量；
       僵尸 CUDA 上下文则表现为 利用率 100% / 显存控制器 0% / 功耗 ~98-130W ——
       SM 每个周期都在等已经被换出到主机内存的那部分显存，所以"忙但不算"。
       这是"功率上不去"的根因特征，而不是功耗墙或降频。 #>
    if ($null -eq $g) { return $false }
    if (($null -ne $g.Power) -and ($g.Power -ge 150))   { return $false }  # 有真实负载
    if (($null -ne $g.UtilMem) -and ($g.UtilMem -gt 5)) { return $false }  # 显存有流量
    return $true
}

function Get-VramDetail($physMiB) {
    <# 读 WDDM 计数器判定超配：committed > physical 即已发生换页。
       顺带找出最大显存持有者（本机常态是 vmwp.exe，即 WSL2 虚拟机进程）。
       只在"需要判定/要出提示"时调用，不放进每次心跳。 #>
    try {
        $c = Get-Counter '\GPU Adapter Memory(*)\Total Committed','\GPU Adapter Memory(*)\Shared Usage','\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop
        $com = 0.0; $shr = 0.0; $ded = 0.0
        foreach ($s in $c.CounterSamples) {
            if     ($s.Path -match 'Total Committed') { if ($s.CookedValue -gt $com) { $com = $s.CookedValue } }
            elseif ($s.Path -match 'Shared Usage')    { if ($s.CookedValue -gt $shr) { $shr = $s.CookedValue } }
            elseif ($s.Path -match 'Dedicated Usage') { if ($s.CookedValue -gt $ded) { $ded = $s.CookedValue } }
        }
        if ($com -le 0) { return $null }

        $topPid = 0; $topMB = 0.0
        try {
            $e = Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop
            $agg = @{}
            foreach ($s in $e.CounterSamples) {
                if ($s.InstanceName -match 'pid_(\d+)') {
                    $k = [int]$Matches[1]
                    if (-not $agg.ContainsKey($k)) { $agg[$k] = 0.0 }
                    $agg[$k] += $s.CookedValue
                }
            }
            foreach ($k in $agg.Keys) { if ($agg[$k] -gt $topMB) { $topMB = $agg[$k]; $topPid = $k } }
        } catch { }
        $topName = '(未知)'
        if ($topPid -gt 0) {
            $pr = Get-Process -Id $topPid -ErrorAction SilentlyContinue
            if ($pr) { $topName = $pr.ProcessName }
        }
        $phys = if ($physMiB) { [double]$physMiB } else { 24564.0 }
        return @{
            CommittedMB = $com / 1MB
            SharedMB    = $shr / 1MB
            DedicatedMB = $ded / 1MB
            PhysicalMB  = $phys
            Ratio       = (($com / 1MB) / $phys)
            TopPid      = $topPid
            TopName     = $topName
            TopMB       = $topMB / 1MB
        }
    } catch { return $null }
}

function Write-StuckHint($g, $now) {
    <# 显存被占 + GPU 假忙 = 多半是僵尸 CUDA 上下文。
       本机实测（2026-09-25）：WSL 侧模型进程崩溃/被 kill 后没释放 GPU 上下文，
       23.5 GB 占用挂在 vmwp.exe（WSL2 虚拟机进程）上，SM 利用率 100% 但功耗只有 98W、
       显存控制器 0%。**这种情况下重启服务是起不来的**（显存闸门会一直挡着），
       必须先释放。最多每 30 分钟提示一次，避免刷屏。 #>
    if (($now - [double]$state.StuckHintAt) -lt 1800) { return }
    Write-Log '    [!] 疑似僵尸 CUDA 上下文：显存被占着，但显存控制器没有任何流量（GPU 假忙）。'
    Write-Log '      本机最常见原因: WSL 侧模型进程崩溃/被 kill 后未释放 GPU 上下文，占用挂在 vmwp.exe 上。'
    Write-Log '      处理: wsl --shutdown    （释放 WSL 全部显存；随后本守护会在显存空出后自动拉起）'
    $vd = Get-VramDetail $(if ($g) { $g.Total } else { 0 })
    if ($vd) {
        Write-Log ('      证据: committed {0:N0} MiB / physical {1:N0} MiB = {2:P1}（超过 99.5% 即超配）；最大持有者 {3} (PID {4}) {5:N0} MiB' -f `
            $vd.CommittedMB, $vd.PhysicalMB, $vd.Ratio, $vd.TopName, $vd.TopPid, $vd.TopMB)
    }
    $state.StuckHintAt = $now
    Save-State $state
}

function ConvertTo-SlotList($raw) {
    <# 把 /slots 的解析结果统一摊平成"每项是一个 slot 对象"的列表。
       ⚠️ PowerShell 5.1 的 ConvertFrom-Json 对**顶层数组**的处理很坑（2026-09-25 实测）：
         `@($txt | ConvertFrom-Json)` 只得到 **1** 个元素，
         而那个元素的 .id 却是 @(0,1,2) —— 即拿到了一个"属性全是数组"的包装对象。
         后果：`[double]$s.n_prompt_tokens` 抛
         "无法将 System.Object[] 类型的值转换为 System.Double 类型"，
         被 catch 吞掉后整个停滞检测静默失效。
       两种形状都在这里处理掉，别再依赖 ConvertFrom-Json 的展开行为。 #>
    $list = @()
    if ($null -eq $raw) { return $list }
    if ($raw -is [System.Array]) { return @($raw) }

    $idv = $raw.id
    if ($idv -is [System.Array]) {
        for ($k = 0; $k -lt $idv.Count; $k++) {
            $o = New-Object psobject
            foreach ($p in $raw.PSObject.Properties) {
                $val = $p.Value
                $vv = $val
                if ($val -is [System.Array]) { $vv = $val[$k] }
                $o | Add-Member -NotePropertyName $p.Name -NotePropertyValue $vv
            }
            $list += $o
        }
    } else {
        $list = @($raw)
    }
    return $list
}

function Get-SlotProgress {
    <# 读 /slots，汇总"引擎到底推进了多少"。
       服务活着 ≠ 引擎在干活：llama.cpp 卡死时 /health 照样返回 200，
       只有这里的进度计数是诚实的。
       实测 2026-09-25：slot1 的 n_prompt_tokens 从 46556 到 46582 花了 90 秒
       （健康时应是 ~1000+ t/s），本质是显存超配换页导致的停滞。
       多个字段可能同时存在（n_past 与 n_decoded 语义重叠），这里全部求和 ——
       我们只关心"这个数还在不在变"，重叠不影响判定。
       失败时把原因写进 $script:SlotReadErr，调用方必须记录 —— 不许静默。 #>
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$ModelPort/slots")
        $req.Proxy = $null
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()

        $slots = @(ConvertTo-SlotList ($txt | ConvertFrom-Json))
        $proc = 0; $total = 0.0; $busyId = -1
        foreach ($s in $slots) {
            if ($s.is_processing) { $proc++; if ($busyId -lt 0) { $busyId = [int]$s.id } }
            foreach ($f in @('n_prompt_tokens','n_prompt_tokens_processed','n_decoded','n_past')) {
                $v = $s.$f
                if ($null -ne $v) { $total += [double]$v }
            }
        }
        $script:SlotReadErr = ''
        return @{ Total = $total; Processing = $proc; BusySlot = $busyId; Slots = $slots.Count }
    } catch {
        $script:SlotReadErr = $_.Exception.Message
        return $null
    }
}

function Write-StallHint($prog, $g, $stalledFor, $now) {
    <# 引擎停滞告警。核心是显存超配 —— 这与"服务已停"是完全不同的故障：
       端口通、/health 200，但推理慢到等于不可用。最多每 30 分钟提示一次。 #>
    if (($now - [double]$state.StallHintAt) -lt 1800) { return }
    Write-Log ('    [!] 引擎停滞：服务在跑，但 slot {0} 的进度已 {1} 秒零增长' -f $prog.BusySlot, $stallSec)
    Write-Log ('      判据: /slots 的 n_prompt_tokens + n_decoded 累计值不再增长（/health 此时仍是 200，不可信）')
    $vd = Get-VramDetail $(if ($g) { $g.Total } else { 0 })
    if ($vd) {
        $over = ($vd.Ratio -ge 0.995)
        Write-Log ('      显存: committed {0:N0} MiB / physical {1:N0} MiB = {2:P1}{3}' -f `
            $vd.CommittedMB, $vd.PhysicalMB, $vd.Ratio, $(if ($over) { '  ← 已超配，正在换页' } else { '' }))
        Write-Log ('      最大持有者: {0} (PID {1}) {2:N0} MiB（本机常态是 vmwp.exe，即 WSL2 虚拟机进程）' -f `
            $vd.TopName, $vd.TopPid, $vd.TopMB)
        if ($over) {
            Write-Log '      根因: 显存超配 —— 被换出到主机内存的页每次访问都要走 PCIe，prefill 会掉到千分之一。'
        }
    }
    Write-Log '      处理: bash ~/stop_bonsai.sh && bash /mnt/c/Users/administrat0r/start_wsl_services_bonsai.sh'
    Write-Log '            或 wsl --shutdown 后重跑 start_all.bat'
    Write-Log '      降基线: BONSAI_MMPROJ=0 省 0.59 GiB；BONSAI_NP=2 每路仍 262144、省约 4.5 GiB'
    $state.StallHintAt = $now
    Save-State $state
}

function Read-State {
    if (Test-Path $StateFi) {
        try { return Get-Content $StateFi -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        Streak = 0; LastRestart = ''; LastNote = ''; GraceUntil = 0
        Restarts = @(); LastHeartbeat = 0; StuckHintAt = 0
        LastProg = $null; LastProgAt = 0; StallStreak = 0; StallHintAt = 0; LastRate = 0
    }
}

function Save-State($o) {
    if ($DryRun) { return }
    try { ($o | ConvertTo-Json -Depth 4) | Set-Content $StateFi -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 单实例锁
# start_all.ps1 是幂等的，但"手动双击 + 脚本拉起"仍可能并存两个实例。
# 命名互斥体在进程退出时自动释放；上一实例异常死亡会抛 AbandonedMutex，
# 那种情况按"拿到锁"处理（否则会永久锁死）。
$mtx = $null
$owned = $false
try {
    $mtx = New-Object System.Threading.Mutex($false, 'Local\BonsaiGuard')
    try { $owned = $mtx.WaitOne(0) } catch { $owned = $true }
} catch { $owned = $true }
if (-not $owned) {
    Write-Log '已有另一个 Bonsai 守护在运行，本实例退出'
    exit 0
}

$state = Read-State
foreach ($f in @('Streak','LastRestart','LastNote','GraceUntil','Restarts','LastHeartbeat','StuckHintAt',
                 'LastProg','LastProgAt','StallStreak','StallHintAt','LastRate')) {
    if (-not ($state.PSObject.Properties.Name -contains $f)) {
        $state | Add-Member -NotePropertyName $f -NotePropertyValue 0 -Force
    }
}
if ($null -eq $state.Streak)  { $state.Streak = 0 }
if ($null -eq $state.Restarts) { $state.Restarts = @() }

$now0 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (($null -eq $state.GraceUntil) -or ([double]$state.GraceUntil -lt $now0)) {
    # 进程刚起：给 start_all.ps1 刚拉起来的模型留出加载时间，别和它抢
    $state.GraceUntil = $now0 + $StartupGraceSec
}

$iterations = if ($Watch) { [int]::MaxValue } else { $ChecksPerRun }
$totTxt     = if ($Watch) { '∞' } else { [string]$ChecksPerRun }

if ($Watch) {
    # ⚠️ 这里必须先把字符串拼好、赋给变量，再统一 -f。
    # 写成 `Write-Log ('a' + 'b') -f $x` 是错的 —— 命令调用语法下 `-f` 会被当成
    # Write-Log 的参数名（报 "找不到与参数名称 f 匹配的参数"），字符串原样输出、
    # 占位符一个都不会被替换。所以格式化必须在括号内完成。
    $banner = ('常驻守护启动: 每 {0}s 采样 | 连续 {1} 次不通才动作 | 显存闸门 <= {2:N0} MiB | ' +
               '冷却 {3} 分钟 | 每小时最多 {4} 次 | 清理残留={5}') -f `
        $IntervalSec, $ConsecutiveChecks, $FreeVramMiB, $CooldownMinutes, $MaxRestartsPerHour, [bool]$CleanStale
    Write-Log $banner
    Write-Log ('日志: {0}    暂停: 创建 {1} 即可' -f $LogFi, $PauseFi)
}

for ($i = 1; $i -le $iterations; $i++) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $gpu = Get-Gpu

    $modelTcp = Test-Tcp $ModelPort
    $modelUp  = if ($modelTcp) { Test-Health $ModelPort } else { $false }
    $gwUp     = Test-Tcp $GatewayPort

    $down    = (-not $modelUp) -or (-not $gwUp)
    $inGrace = ($now -lt [double]$state.GraceUntil)

    if ($null -eq $gpu) {
        $vramFree = $false
    } else {
        $vramFree = ($gpu.Used -le $FreeVramMiB)
    }
    $gpuTxt = Get-GpuText $gpu

    $svcTxt = ('模型 :{0} {1} | 网关 :{2} {3}' -f `
        $ModelPort, $(if ($modelUp) { 'UP' } elseif ($modelTcp) { 'TCP-ONLY' } else { 'DOWN' }),
        $GatewayPort, $(if ($gwUp) { 'UP' } else { 'DOWN' }))

    if ($down) {
        Write-Log ('[{0}/{1}] {2} | {3}' -f $i, $totTxt, $svcTxt, $gpuTxt)
    } else {
        # 心跳：健康时每 40 个采样（默认 10 分钟）记一条，避免每 15 秒刷日志
        if (($now - [double]$state.LastHeartbeat) -ge ($IntervalSec * 40)) {
            Write-Log ('[心跳] {0} | {1}' -f $svcTxt, $gpuTxt)
            $state.LastHeartbeat = $now
            # 服务虽然活着，但"显存被占 + GPU 假忙"同样要提醒：这时卡是退化的，
            # 请求会极慢，而守护因为判据是"服务在"不会动作，容易被忽略。
            if ((-not $vramFree) -and (Test-FakeBusy $gpu)) { Write-StuckHint $gpu $now }
            Save-State $state
        }
    }

    if (-not $down) {
        # --- 引擎停滞检测（关键：服务活着 ≠ 引擎在干活）---
        # ⚠️ 不能只判"进度有没有变化"：实测超配抖振时进度**仍在缓慢爬**
        #    （90 秒推进 26 个 token ≈ 0.3 t/s），只是比健康值慢约三个数量级。
        #    所以判据必须是**推进速率**。
        #    健康参考: prefill 700~1500 t/s/路，decode 30~80 t/s/路（含 250k 深上下文 32 t/s）。
        #    阈值 5 t/s 既远低于任何健康速率，又远高于病态的 0.3 t/s。
        $prog = Get-SlotProgress
        if (-not $prog) {
            # 不许静默：读不到 /slots 就等于停滞检测瞎了，必须留痕（5 分钟最多一条）
            if (($now - [double]$script:LastSlotErrLog) -ge 300) {
                Write-Log ('    [!] 读 /slots 失败，停滞检测本轮无效: {0}' -f $script:SlotReadErr)
                $script:LastSlotErrLog = $now
            }
        }
        if ($prog) {
            if (($prog.Processing -gt 0) -and ($null -ne $state.LastProg)) {
                $dt2 = $now - [double]$state.LastProgAt
                if (($dt2 -ge 2) -and ($dt2 -le 600)) {
                    $rate = ($prog.Total - [double]$state.LastProg) / $dt2
                    $state.LastRate = [math]::Round($rate, 2)
                    if ($rate -lt $MinProgTps) {
                        $state.StallStreak = [int]$state.StallStreak + 1
                    } else {
                        if ([int]$state.StallStreak -ne 0) {
                            Write-Log ('    引擎恢复推进（{0:N1} t/s，原停滞 {1} 次采样）' -f $rate, $state.StallStreak)
                        }
                        $state.StallStreak = 0
                    }
                }
            } else {
                $state.StallStreak = 0
            }
            $state.LastProg = $prog.Total
            $state.LastProgAt = $now

            # [!] 命名陷阱：局部变量绝不能叫 $stallSec —— PowerShell 变量名**大小写不敏感**，
            #   那会和参数 $StallSec 变成同一个变量，赋值后判据就成了 "X >= X" 恒为真，
            #   于是第一个采样（还没有基线）也会误报停滞。实测踩过，故用 $stalledFor。
            $stalledFor = [int]$state.StallStreak * $IntervalSec
            if ($stalledFor -ge $StallSec) {
                Write-Log ('[{0}/{1}] {2} | {3} | [!] 停滞 {4}s（slot {5} 处理中，推进仅 {6:N1} t/s）' -f `
                    $i, $totTxt, $svcTxt, $gpuTxt, $stalledFor, $prog.BusySlot, [double]$state.LastRate)
                Write-StallHint $prog $gpu $stalledFor $now
            }
        }
        if ($state.Streak -ne 0) { Write-Log ('    服务已恢复，连续计数清零（原 {0}）' -f $state.Streak) }
        $state.Streak = 0
        Save-State $state
        if ($i -lt $iterations) { Start-Sleep -Seconds $IntervalSec }
        continue
    }

    # ---------------------------------------------------------- 服务已停
    $state.Streak = [int]$state.Streak + 1

    if ($inGrace) {
        Write-Log ('    宽限期内（还剩 {0:N0}s；多为刚启动正在加载）—— 不动作' -f ([double]$state.GraceUntil - $now))
    } elseif ($state.Streak -lt $ConsecutiveChecks) {
        Write-Log ('    连续不通 {0}/{1}，继续观察' -f $state.Streak, $ConsecutiveChecks)
    } else {
        Write-Log ('>>> 连续 {0} 次不通 —— 服务判定为已停止' -f $state.Streak)

        $why = ''

        # --- 闸门 1: 人工暂停 / 安全开关 ---
        if (Test-Path $PauseFi) {
            $why = "存在暂停文件 $PauseFi"
        } elseif (-not $EnableRestart) {
            $why = '未加 -EnableRestart（安全模式，只告警不执行）'
        } elseif ($DryRun) {
            $why = 'DryRun（只判定不执行）'
        }

        # --- 闸门 2: 显存必须是空的 ---
        # 不空就只记录。可选地先尝试清掉"占着显存但 GPU 空转"的残留，再重新评估。
        if (($why -eq '') -and (-not $vramFree)) {
            if ($CleanStale -and ($null -ne $gpu)) {
                # 判据已从"利用率<10% 且 功耗<80W"改为 Test-FakeBusy。
                # 原判据实际上永远不会命中：真实的僵尸上下文是 **利用率 100%**、
                # 显存控制器 0%、功耗 ~98-130W —— 利用率那一条就把它排除了，
                # 于是 -CleanStale 成了死代码。现在按"显存无流量 + 功耗偏低"判定。
                if (Test-FakeBusy $gpu) {
                    Write-Log '    -CleanStale: 显存被占但显存无流量、功耗偏低（疑似僵尸上下文），清理 WSL 侧残留的模型进程...'
                    $kill = "pkill -f '[l]lama-server' 2>/dev/null; pkill -f '[v]llm serve' 2>/dev/null; sleep 4; echo CLEANED"
                    $ko = & wsl.exe -d $WslDistro -- bash -lc $kill 2>&1
                    foreach ($ln in $ko) { Write-Log ('      ' + $ln.ToString()) }
                    Start-Sleep -Seconds 4
                    $gpu = Get-Gpu
                    if ($null -ne $gpu) {
                        $vramFree = ($gpu.Used -le $FreeVramMiB)
                        $gpuTxt = Get-GpuText $gpu
                        Write-Log ('      清理后: {0} -> {1}' -f $gpuTxt, $(if ($vramFree) { '显存已空，可以启动' } else { '仍被占用' }))
                    }
                } else {
                    Write-Log '    -CleanStale: 显存有真实流量或功耗正常（可能在真算），不清理'
                }
            }
            if (-not $vramFree) {
                $why = ('显存不是空的（{0}；阈值 {1:N0} MiB）—— 不启动，等显存空出来' -f $gpuTxt, $FreeVramMiB)
            }
        }

        # --- 闸门 3: 冷却期 ---
        if ($why -eq '' -and $state.LastRestart) {
            $last = $null
            try { $last = [datetime]::Parse($state.LastRestart) } catch { }
            if ($last -and (((Get-Date) - $last).TotalMinutes -lt $CooldownMinutes)) {
                $why = ('仍在冷却期（上次启动 {0:N1} 分钟前 < {1} 分钟）' -f ((Get-Date) - $last).TotalMinutes, $CooldownMinutes)
            }
        }

        # --- 闸门 4: 每小时熔断 ---
        if ($why -eq '') {
            $recent = @($state.Restarts | Where-Object {
                $t = $null
                try { $t = [datetime]::Parse([string]$_) } catch { }
                if ($t) { (((Get-Date) - $t).TotalMinutes -lt 60) } else { $false }
            })
            if ($recent.Count -ge $MaxRestartsPerHour) {
                $why = ('一小时内已启动 {0} 次（上限 {1}）—— 熔断，只告警' -f $recent.Count, $MaxRestartsPerHour)
            }
        }

        if ($why -ne '') {
            Write-Log ('    跳过：{0}' -f $why)
            if ((-not $vramFree) -and (Test-FakeBusy $gpu)) { Write-StuckHint $gpu $now }
            $state.LastNote = $why
        } else {
            Write-Log ('    执行启动: wsl -d {0} -- bash {1}（幂等，约 1-3 分钟）' -f $WslDistro, $RestartScript)
            $out = & wsl.exe -d $WslDistro -- bash -lc "bash $RestartScript" 2>&1
            $txt = ($out | Out-String)
            foreach ($ln in $out) { Write-Log ('      ' + $ln.ToString()) }

            if ($txt -match 'failed to run|Access is denied|拒绝访问') {
                # 程序黑名单会把 wsl.exe 整个拦住 —— 这是环境问题，重启解决不了，
                # 所以拉长等待，别每轮都刷一遍同样的失败
                Write-Log '    [!] wsl.exe 无法启动（多半是「安全中心 > 程序黑名单」里有 wsl.exe）—— 30 分钟内不再尝试'
                $state.GraceUntil = $now + 1800
                $state.LastNote   = 'wsl.exe 被程序黑名单拦截'
            } else {
                $ts = (Get-Date).ToString('o')
                $state.LastRestart = $ts
                $state.Restarts    = @($state.Restarts) + @($ts)
                $state.LastNote    = '服务已停 + 显存空，已自动拉起'
                $state.GraceUntil  = $now + $StartupGraceSec
                Write-Log ('    已发起启动，宽限 {0} 秒后重新判定' -f $StartupGraceSec)
            }
        }

        if (-not $DryRun) { $state.Streak = 0 }
    }

    Save-State $state
    if ($i -lt $iterations) { Start-Sleep -Seconds $IntervalSec }
}

Save-State $state
exit 0
