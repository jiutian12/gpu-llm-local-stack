# ============================================================
#  stop_all.ps1 —— 停止整套服务（Windows 侧 + WSL 侧）
#
#  用法:
#    双击 stop_all.bat
#    或: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\administrat0r\stop_all.ps1
#
#  参数:
#    -WithPostgres  连 PostgreSQL(5432) 一起停（默认保留，用量数据在里面）
#    -KeepLhm       保留 LibreHardwareMonitor 不关（默认关闭）
#
#  幂等: 已停止的会跳过
# ============================================================
param(
    [switch]$WithPostgres,
    [switch]$KeepLhm,
    [string]$Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Continue'
$CFG_DIR = 'C:\Users\administrat0r\monitoring_cfg'

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ' GPU + LLM 全栈停止' -ForegroundColor Yellow
Write-Host " 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkGray

# ---------------- [1/3] Windows 侧 ----------------
Write-Host ''
Write-Host '[1/3] Windows 侧: 监控守护(常驻) / 主机指标 exporter(9401) / LHM(8085)' -ForegroundColor Cyan

# 常驻监控守护：按命令行匹配，只杀带 -Watch 的那一个（2026-09-12 起改为常驻进程）
# 两个守护都要停：
#   gpu_overcommit_guard.ps1  -> vLLM 链路
#   bonsai_guard.ps1          -> Bonsai 链路（服务掉了会自动把栈拉回来，不停它等于没停）
$gk = 0
try {
    # 三个条件都要：只按守护名匹配会误命中"命令文本里提到该字符串"的进程
    $gp = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
          Where-Object {
              ($_.CommandLine -like '*gpu_overcommit_guard*' -or $_.CommandLine -like '*bonsai_guard*') -and
              $_.CommandLine -like '*-EnableRestart*' -and $_.CommandLine -like '*-Watch*'
          }
    foreach ($p in $gp) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $gk++ } catch {}
    }
} catch { }
if ($gk -gt 0) { Write-Host "  [OK] 已停止常驻监控守护（$gk 个进程）" -ForegroundColor Green }
else { Write-Host '  - 常驻监控守护未在运行' -ForegroundColor DarkGray }

# 9401: 按命令行匹配 host_exporter_win.py，避免误杀其他 python
$killed = 0
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction Stop |
             Where-Object { $_.CommandLine -like '*host_exporter_win.py*' }
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
    }
} catch {
    # 退路: taskkill 按窗口标题/镜像名不可靠，这里只提示
    Write-Host "  [!] 枚举进程失败: $($_.Exception.Message)" -ForegroundColor Yellow
}
if ($killed -gt 0) { Write-Host "  [OK] 已停止主机指标 exporter（$killed 个进程）" -ForegroundColor Green }
else { Write-Host '  - 主机指标 exporter 未在运行' -ForegroundColor DarkGray }

# LHM
if ($KeepLhm) {
    Write-Host '  - 保留 LibreHardwareMonitor（-KeepLhm）' -ForegroundColor DarkGray
} else {
    $lhm = Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue
    if ($lhm) {
        try { $lhm | Stop-Process -Force -ErrorAction Stop; Write-Host '  [OK] 已关闭 LibreHardwareMonitor' -ForegroundColor Green } catch {}
    } else {
        Write-Host '  - LibreHardwareMonitor 未在运行' -ForegroundColor DarkGray
    }
}

# ---------------- [2/3] WSL 侧 ----------------
Write-Host ''
Write-Host '[2/3] WSL 侧: vLLM / litellm / 监控' -ForegroundColor Cyan

$wslOk = $false
try {
    $o = (& wsl.exe -d $Distro -- bash -lc 'echo WSL_OK; exit 0' 2>$null) | Out-String
    if ($o -match 'WSL_OK' -or $LASTEXITCODE -eq 0) { $wslOk = $true }
} catch {}

if (-not $wslOk) {
    $o = (& wsl.exe -- bash -lc 'echo WSL_OK; exit 0' 2>$null) | Out-String
    if ($o -match 'WSL_OK' -or $LASTEXITCODE -eq 0) { $wslOk = $true; $Distro = '' }
}

if ($wslOk) {
    # 注意: 不要给 $args 赋值 —— 它是 PowerShell 自动变量
    $cmd = 'bash /mnt/c/Users/administrat0r/stop_wsl_services.sh'
    if ($WithPostgres) { $cmd = $cmd + ' --with-pg' }
    $wargs = @()
    if ($Distro -ne '') { $wargs += @('-d', $Distro) }
    $wargs += @('--', 'bash', '-lc', $cmd)
    & wsl.exe @wargs
} else {
    Write-Host '  [!] 无法执行 WSL，跳过 WSL 侧' -ForegroundColor Yellow
}

# ---------------- [3/3] 端口检查 ----------------
Write-Host ''
Write-Host '[3/3] 端口释放检查' -ForegroundColor Cyan
$PORTS = @(
    @{ P = 9401;  N = '主机指标 exporter'; S = 'WIN' }
    @{ P = 8085;  N = 'LHM 传感器';        S = 'WIN' }
    @{ P = 18020; N = 'vLLM';             S = 'WSL' }
    @{ P = 1234;  N = 'litellm';          S = 'WSL' }
    @{ P = 9090;  N = 'Prometheus';       S = 'WSL' }
    @{ P = 3000;  N = 'Grafana';          S = 'WSL' }
    @{ P = 9400;  N = 'GPU exporter';     S = 'WSL' }
    @{ P = 9410;  N = 'LLM 瀑布流';        S = 'WSL' }
)
function Test-Port($p) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($r.AsyncWaitHandle.WaitOne(1000, $false) -and $c.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { if ($c -ne $null) { try { $c.Close() } catch {} } }
}
foreach ($x in $PORTS) {
    if (Test-Port $x.P) { Write-Host ("  {0,-6} {1,-20} 仍占用" -f $x.P, $x.N) -ForegroundColor Yellow }
    else { Write-Host ("  {0,-6} {1,-20} 已释放" -f $x.P, $x.N) -ForegroundColor Green }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host '  已停止。重新启动请双击 start_all.bat' -ForegroundColor Green
if (-not $WithPostgres) {
    Write-Host '  注: PostgreSQL(5432) 默认保留。要一并停止: stop_all.bat -WithPostgres' -ForegroundColor DarkGray
}
Write-Host '============================================================' -ForegroundColor DarkGray
