# -*- coding: utf-8 -*-
<#
.SYNOPSIS
  GPU / vLLM 健康守护 —— 每 10 秒采样一次，连续 3 次命中即自动重启 vLLM。

.DESCRIPTION
  负责三类**必须靠重启才能恢复**的故障（2026-09-12 实测归纳）：

  (A) 显存超配：WDDM 把一部分显存静默兜底到主机内存（D3D "Shared"），
      访问要走 PCIe，推理可掉到 1/10。判据是 committed/physical 而非"Shared 多大"。
      实测：97-99% 时通常还健康，越接近 100% 越危险。

  (B) loopback 条目失效：WSL 镜像网络下"杀掉 vLLM 后立即重启"会留下失效条目，
      端口在监听但 127.0.0.1 上 HTTP 完全无响应（LAN IP 正常），
      litellm/Prometheus 全断。**显存判据发现不了它。**

  (C) 引擎停滞（新增，2026-09-12 16:46 实测）：有请求在跑、SM 100% 忙，
      但 prompt 与 generation 的 token 计数**连续 30 秒零增长**，功率掉到 ~107 W、
      显存控制器只剩 0-3%。此时 running=2 且 waiting=3，客户端全部卡住。
      **这种状态下 committed 只有 98.08%，显存判据同样发现不了** —— 这就是
      16:46 那次没有自动重启的原因。

  判据 (C) 的信号来自引擎自己的累计计数器（prompt_tokens_total +
  generation_tokens_total），**比"功率低"更可靠**：正常 prefill 即使在最深的
  上下文下也能跑到 180 tok/s，30 秒不可能一个 token 都不动。

.PARAMETER IntervalSec
  两次采样之间的间隔。默认 10 秒。计划任务每 1 分钟拉起一次本脚本，
  脚本内部循环 ChecksPerRun 次，因此覆盖率≈连续。

.PARAMETER ChecksPerRun
  非常驻模式下每次被拉起后采样多少次。默认 5（= 50 秒）。

.PARAMETER Watch
  **常驻模式**：内部无限循环，每 IntervalSec 秒采样一次，直到进程被杀。
  这是当前推荐的用法 —— 由 start_all.ps1 以 -WindowStyle Hidden 只拉起一次。
  （历史方案是"计划任务每 1 分钟拉起一次"，但那样每分钟新建进程会闪一次黑窗，
  已在 2026-09-12 废弃。计划任务请保持 Disabled。）

.PARAMETER ConsecutiveChecks
  连续命中多少次才重启。默认 3（= 30 秒持续异常）。

.PARAMETER CooldownHours
  两次自动重启的最小间隔。默认 0.5 小时。实测今天 12:03 与 16:46 各退化一次，
  冷却期太长会导致第二次退化无法自愈，所以给 30 分钟。

.PARAMETER RequireIdle
  只在引擎空闲（num_requests_running=0）时才重启。默认不加 —— 即"检测到就重启"。
  (B)/(C) 两类故障下引擎本来就收不到/产不出 token，此开关自动失效。

.PARAMETER DryRun
  只打印判定过程，不写状态、不重启。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File gpu_overcommit_guard.ps1 -EnableRestart
.EXAMPLE
  # 常驻模式（推荐；由 start_all.ps1 隐藏拉起）
  powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File gpu_overcommit_guard.ps1 -EnableRestart -Watch

.EXAMPLE
  # 手动单次检查（不进循环）
  powershell -NoProfile -ExecutionPolicy Bypass -File gpu_overcommit_guard.ps1 -ChecksPerRun 1 -DryRun
#>
[CmdletBinding()]
param(
    [double]$ThresholdRatio    = 0.995,
    [int]   $ConsecutiveChecks = 3,
    [double]$CooldownHours     = 0.5,
    [int]   $IntervalSec       = 10,
    [int]   $ChecksPerRun      = 5,
    [string]$WslDistro         = 'Ubuntu',
    [string]$RestartScript     = '/mnt/c/Users/administrat0r/restart_vllm.sh',
    [switch]$EnableRestart,
    [switch]$RequireIdle,
    [switch]$Watch,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$CfgDir   = 'C:\Users\administrat0r\monitoring_cfg'
$StateFi  = Join-Path $CfgDir 'gpu_guard_state.json'
$LogFi    = Join-Path $CfgDir 'gpu_guard.log'
$Exporter = 'http://127.0.0.1:9401/metrics'     # 主机内存 + D3D 显存
$GpuMet   = 'http://127.0.0.1:9400/metrics'     # NVML：功率 / 利用率 / 控制器
$VllmMet  = 'http://127.0.0.1:18020/metrics'
$PhysicalMiB = 24564

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

# 绕过代理的抓取（WSL 会往环境里塞 http_proxy/HTTP_PROXY，.NET 会因此报错）
function Fetch([string]$url, [int]$timeoutSec = 10) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Proxy = $null
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return $t
    } catch { return $null }
}

function Get-GpuMem {
    <# 返回 @{Dedicated;Shared;Committed;Physical;Source}（字节）。优先 9401，失败回退性能计数器 + nvidia-smi。 #>
    $txt = Fetch $Exporter
    if ($txt) {
        # 注意：这里**不能**用 -f 拼正则 —— 正则里的 { } 会被当成格式占位符。
        $pat = 'host_gpu_memory_%K%_bytes\{[^}]*hardware="NVIDIA GeForce RTX 4090"[^}]*\}\s+(\d+)'
        $d = [regex]::Match($txt, $pat.Replace('%K%', 'dedicated'))
        $s = [regex]::Match($txt, $pat.Replace('%K%', 'shared'))
        $c = [regex]::Match($txt, $pat.Replace('%K%', 'committed'))
        $p = [regex]::Match($txt, $pat.Replace('%K%', 'physical'))
        if ($d.Success -and $p.Success) {
            return @{
                Dedicated = [double]$d.Groups[1].Value
                Shared    = if ($s.Success) { [double]$s.Groups[1].Value } else { 0.0 }
                Committed = if ($c.Success) { [double]$c.Groups[1].Value }
                            else { [double]$d.Groups[1].Value + [double]$s.Groups[1].Value }
                Physical  = [double]$p.Groups[1].Value
                Source    = 'exporter:9401'
            }
        }
    }
    try {
        $c = Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage','\GPU Adapter Memory(*)\Shared Usage' -ErrorAction Stop
        $ded = 0.0; $shr = 0.0
        foreach ($s in $c.CounterSamples) {
            $kind = ($s.Path -split '\\')[4]
            if ($kind -match 'Dedicated') { if ($s.CookedValue -gt $ded) { $ded = $s.CookedValue } }
            else { if ($s.CookedValue -gt $shr) { $shr = $s.CookedValue } }
        }
        if ($ded -gt 0) {
            return @{
                Dedicated = $ded; Shared = $shr; Committed = $ded + $shr
                Physical  = $PhysicalMiB * 1MB
                Source    = 'perfcounter+fallback'
            }
        }
    } catch { }
    return $null
}

function Get-Vllm {
    <# 一次抓取，返回 @{Running;Waiting;Prompt;Gen;Kv}；取不到返回 $null #>
    $txt = Fetch $VllmMet 6
    if (-not $txt) { return $null }

    function _one([string]$pat) {
        $m = [regex]::Match($txt, $pat)
        if ($m.Success) { return [double]$m.Groups[1].Value }
        return $null
    }
    # 注意：这两个累计计数器在 /metrics 里**可能带多组 label**（model_name 等），
    # 必须**求和**而不是只取第一条 —— 只取第一条会因为 series 输出顺序变化
    # 而产生负增量（2026-09-12 实测出现 -980,591）。
    function _sum([string]$pat) {
        $ms = [regex]::Matches($txt, $pat)
        if ($ms.Count -eq 0) { return $null }
        $t = 0.0
        foreach ($m in $ms) { $t += [double]$m.Groups[1].Value }
        return $t
    }
    $r = _one 'vllm:num_requests_running\{[^}]*\}\s+([\d\.]+)'
    $p = _sum 'vllm:prompt_tokens_total\{[^}]*\}\s+([\d\.]+)'
    $g = _sum 'vllm:generation_tokens_total\{[^}]*\}\s+([\d\.]+)'
    if ($null -eq $r -and $null -eq $p) { return $null }
    return @{
        Running = $r
        Waiting = _one 'vllm:num_requests_waiting\{[^}]*\}\s+([\d\.]+)'
        Prompt  = $p
        Gen     = $g
        Kv      = _one 'vllm:kv_cache_usage_perc\{[^}]*\}\s+([\d\.]+)'
    }
}

function Get-GpuLive {
    <# 从 :9400（NVML）取功率与利用率；退化特征主要看 UtilGpu 高 + UtilMem 低 #>
    $txt = Fetch $GpuMet 5
    if (-not $txt) { return $null }

    function _one([string]$pat) {
        $m = [regex]::Match($txt, $pat)
        if ($m.Success) { return [double]$m.Groups[1].Value }
        return $null
    }
    $u = _one 'gpu_utilization_gpu_percent\{[^}]*\}\s+([\d\.]+)'
    if ($null -eq $u) { return $null }
    return @{
        Power   = _one 'gpu_power_watts\{[^}]*\}\s+([\d\.]+)'
        UtilGpu = $u
        UtilMem = _one 'gpu_utilization_memory_percent\{[^}]*\}\s+([\d\.]+)'
        MemUsed = _one 'gpu_memory_used_bytes\{[^}]*\}\s+([\d\.]+)'
    }
}

# TCP 层探测：端口是否有监听。用于区分两种"18020 无响应"。
function Test-Port([int]$port = 18020, [int]$timeoutMs = 1500) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $c.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($c) { try { $c.Close() } catch { } }
    }
}

function Read-State {
    if (Test-Path $StateFi) {
        try { return Get-Content $StateFi -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ Streak = 0; LastRestart = ''; LastNote = '';
                             LastPrompt = $null; LastGen = $null; LastTs = 0 }
}

function Save-State($o) {
    if ($DryRun) { return }
    try { ($o | ConvertTo-Json) | Set-Content $StateFi -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 主流程
foreach ($n in @('http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','no_proxy','NO_PROXY')) {
    if (Test-Path "Env:$n") { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
}

$state = Read-State

# 单实例锁：任务每 1 分钟触发一次，而一轮要跑约 50 秒；再加上手动 Start-ScheduledTask，
# 实测会出现两个实例并行（2026-09-12 观察到 PID 24884 与 11140 同时存在）。
# 并行本身不致命（判据是幂等的），但两个实例可能同时越过阈值 → 两次重启。
# 用命名互斥体：进程退出自动释放；若上一个实例异常死亡会抛 AbandonedMutex，
# 那种情况按"获得锁"处理。
$mtx = $null
$owned = $false
try {
    $mtx = New-Object System.Threading.Mutex($false, 'Local\GpuVramGuard')
    try { $owned = $mtx.WaitOne(0) } catch { $owned = $true }
} catch { $owned = $true }
if (-not $owned) {
    Write-Log '已有另一轮监测在运行，本轮跳过'
    exit 0
}

foreach ($f in @('Streak','LastRestart','LastNote','LastPrompt','LastGen','LastTs','LastOkTs')) {
    if (-not ($state.PSObject.Properties.Name -contains $f)) {
        $state | Add-Member -NotePropertyName $f -NotePropertyValue 0 -Force
    }
}
if ($null -eq $state.Streak) { $state.Streak = 0 }

# 常驻模式（2026-09-12）：计划任务已废弃 —— 它每分钟新建一个进程，
# Windows 会先给新进程创建 conhost 控制台，`-WindowStyle Hidden` 来不及拦住，
# 于是每分钟闪一次黑窗。现在改为由 start_all.ps1 以 -WindowStyle Hidden
# **只拉起一次**本进程，进程内部自己 Start-Sleep 循环。
$iterations = if ($Watch) { [int]::MaxValue } else { $ChecksPerRun }
$totTxt = if ($Watch) { '∞' } else { [string]$ChecksPerRun }
if ($Watch) {
    Write-Log ('常驻模式启动: 每 {0} 秒采样一次，连续 {1} 次命中即重启 vLLM（日志: {2}）' -f $IntervalSec, $ConsecutiveChecks, $LogFi)
}

$miB = 1MB
$restartReason = ''

for ($i = 1; $i -le $iterations; $i++) {
    $mem = Get-GpuMem
    if (-not $mem) {
        Write-Log '读不到显存数据（9401 与性能计数器都失败）—— 跳过本次检查'
        if (-not $Watch) { exit 0 }
        Start-Sleep -Seconds $IntervalSec
        continue
    }
    $v = Get-Vllm
    $portOpen = Test-Port 18020
    $live = Get-GpuLive
    $ratio = if ($mem.Physical -gt 0) { $mem.Committed / $mem.Physical } else { 0 }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # --- 三类判据 ---
    $over = $ratio -ge $ThresholdRatio

    # loopback 故障：端口在监听，但 127.0.0.1 上的 HTTP 完全无响应。
    # **必须排除"启动中"**：2026-09-12 16:56 实测，vLLM 启动接近尾声时端口
    # 已绑定、/metrics 还没开始服务，连续两次被记成"引擎无响应"
    # （ConsecutiveChecks=3 只差一次就会误重启刚起来的实例）。
    # 判据用**正向信号**：GPU 显存还没涨到加载基线（<20 GiB）= 模型仍在加载。
    # 不能用"最近是否抓到过 metrics" —— 刚重启完那个时间戳恰恰是新鲜的。
    $loading = $true
    if ($live -and ($null -ne $live.MemUsed)) { $loading = ($live.MemUsed -lt 20GB) }
    $loopbackDown = ($null -eq $v) -and $portOpen -and ($null -ne $live) -and (-not $loading)

    # 停滞：有请求在跑，但 token 计数零增长（与上次采样比），且呈现退化特征
    # 三个限定缺一不可，否则会误判正常的长 prefill（实测：正常 prefill 也是
    # token 增量 0 —— 缓存命中的 token 不计入 prompt_tokens_total —— 但它的
    # 功率是 340-440 W、显存控制器 43-47%；退化态则是 103-110 W、控制器 0-3%）
    $stalled = $false
    $dTok = $null
    if ($v -and ($null -ne $v.Prompt) -and ($null -ne $state.LastPrompt) -and ($null -ne $state.LastTs)) {
        $age = $now - [double]$state.LastTs
        if ($age -ge 2 -and $age -le 600) {
            $dTok = ($v.Prompt - [double]$state.LastPrompt) + ($v.Gen - [double]$state.LastGen)
            # 负增量 = 计数器被重置或标签组变化，属于噪声，不能当成"停滞"
            if ($dTok -lt 0) { $dTok = $null }
        }
    }
    if ($v -and ($null -ne $dTok)) {
        $utilOk    = ($null -eq $live) -or ($live.UtilGpu -ge 80)
        $lowMemCtl = ($null -eq $live) -or ($live.UtilMem -le 10)
        $lowPower  = ($null -eq $live) -or ($null -eq $live.Power) -or ($live.Power -le 200)
        if (($v.Running -gt 0) -and ($dTok -le 0) -and $utilOk -and $lowMemCtl -and $lowPower) {
            $stalled = $true
        }
    }
    if ($v) { $state.LastPrompt = $v.Prompt; $state.LastGen = $v.Gen; $state.LastTs = $now; $state.LastOkTs = $now }

    $hit = $over -or $loopbackDown -or $stalled
    if (($null -eq $v) -and $portOpen -and $loading) {
        Write-Log '    (端口已监听但模型仍在加载 —— 判定为启动中，不计命中)'
    }

    $utilTxt = if ($live) { ' | GPU 功率 {0:N0} W 利用率 {1:N0}% 控制器 {2:N0}%' -f $live.Power, $live.UtilGpu, $live.UtilMem } else { '' }
    $vTxt = if ($v) { ' | 引擎 running={0:N0} waiting={1:N0} KV={2:N1}% 增量token={3}' -f $v.Running, $v.Waiting, ($v.Kv * 100), $(if ($null -eq $dTok) { 'n/a' } else { '{0:N0}' -f $dTok }) } else { ' | 引擎无响应' }
    Write-Log ('[{0}/{1}] committed {2:N0}/{3:N0} MiB ({4:N2}%){5}{6}' -f `
        $i, $totTxt, ($mem.Committed/$miB), ($mem.Physical/$miB), ($ratio*100), $vTxt, $utilTxt)

    if ($hit) {
        $state.Streak = [int]$state.Streak + 1
        $what = @()
        if ($over)         { $what += ('显存超配 {0:N2}%' -f ($ratio*100)) }
        if ($loopbackDown) { $what += 'loopback 条目失效' }
        if ($stalled)      { $what += '引擎停滞（token 零增长）' }
        $restartReason = ($what -join ' + ')
        Write-Log ('    ⚠ 命中 {0}/{1}：{2}' -f $state.Streak, $ConsecutiveChecks, $restartReason)
    } else {
        if ($state.Streak -ne 0) { Write-Log ('    恢复正常，连续计数清零（原 {0}）' -f $state.Streak) }
        $state.Streak = 0
    }
    Save-State $state

    if ($state.Streak -ge $ConsecutiveChecks) {
        Write-Log ('>>> 连续 {0} 次命中（{1}）—— 判定需要重启 vLLM' -f $state.Streak, $restartReason)

        # 用 $decision 收敛而不是在各处 exit：常驻模式（-Watch）下不能退出进程，
        # 只能"跳过本轮"。这样也顺带避免了 exit 在循环里中断常驻监控。
        $decision = 'restart'

        if ((-not $loopbackDown) -and (-not $stalled) -and ($null -eq $v)) {
            # 引擎压根没在跑（端口都没监听）就不动作：那不是 guard 的职责
            Write-Log '    18020 未监听（引擎未运行）—— 跳过。要启动请用 start_all.bat。'
            $decision = 'skip'
        } else {
            if ($state.LastRestart) {
                $last = $null
                try { $last = [datetime]::Parse($state.LastRestart) } catch { }
                if ($last -and (((Get-Date) - $last).TotalHours -lt $CooldownHours)) {
                    Write-Log ('    仍在冷却期（上次重启 {0:N1} 小时前 < {1} 小时），暂不动作。' -f ((Get-Date) - $last).TotalHours, $CooldownHours)
                    $decision = 'skip'
                }
            }
            if (($decision -eq 'restart') -and $RequireIdle -and (-not $loopbackDown) -and (-not $stalled) -and $v -and ($v.Running -gt 0)) {
                Write-Log ('    有 {0:N0} 个请求在跑 —— -RequireIdle 模式，等下一轮。' -f $v.Running)
                $decision = 'skip'
            }
            if (($decision -eq 'restart') -and (-not $EnableRestart)) {
                Write-Log '    【安全模式】需要重启，但未加 -EnableRestart，只告警不执行。'
                Write-Log ('    → 手动重启: wsl -d {0} -- bash {1} --force' -f $WslDistro, $RestartScript)
                $decision = 'skip'
            }
            if (($decision -eq 'restart') -and $DryRun) {
                Write-Log '    【DryRun】判定需要重启，但 DryRun 模式不执行。'
                $decision = 'dryrun'
            }
        }

        if ($decision -eq 'restart') {
            Write-Log '    执行自动重启（restart_vllm.sh --force；约 2-6 分钟）...'
            $out = & wsl.exe -d $WslDistro -- bash $RestartScript --force 2>&1
            foreach ($ln in $out) { Write-Log ('      ' + $ln.ToString()) }
            $state.LastRestart = (Get-Date).ToString('o')
            $state.LastNote = $restartReason
        }

        if ($decision -ne 'dryrun') {
            $state.Streak = 0
            Save-State $state
        }
        if (-not $Watch) { exit 0 }
    }

    if ($i -lt $iterations) { Start-Sleep -Seconds $IntervalSec }
}

Save-State $state
exit 0
