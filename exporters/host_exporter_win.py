#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Windows 主机指标 Prometheus exporter —— 监听 0.0.0.0:9401

采集：CPU 使用率 / CPU 温度 / 内存 / 提交内存(页面文件) / 各逻辑磁盘
  * CPU / 内存 / 磁盘：psutil（本机原生，无子进程开销）
  * 温度：多源探测 + 可靠性判定（2026-09-07 改）
      1) LibreHardwareMonitor 的 Remote Web Server（http://127.0.0.1:8085/data.json）
         —— 未运行时自动跳过；装了它并开启 web server 后自动生效，能拿到真实 CPU 温度
      2) WMI Win32_PerfRawData_Counters_ThermalZoneInformation / MSAcpi_ThermalZoneTemperature
         —— 实测（管理员权限下）：华硕 Z590-E + i7-11700K 上这两个源都恒为 27.85C，
            是 ACPI 固定占位值 → 会被判定为不可靠，**不再作为 CPU 温度输出**
    可靠性判定：连续采样 3 次，值完全相同即判为固定占位值（结果缓存 10 分钟）
    指标：
      host_cpu_temperature_celsius  仅在可靠时输出（不可靠时不输出，避免假曲线）
      host_cpu_temperature_reliable 1=可信 0=不可用/固定占位值
      host_cpu_temperature_source_info 常驻 1，标签描述当前数据源与原因

启动：
    python host_exporter_win.py
"""
import json
import subprocess
import sys
import time
import threading
import http.server
import socketserver

import psutil

PORT = 9401
CACHE_TTL = 5          # psutil 数据很便宜，5s 缓存足够
TEMP_TTL = 15          # 温度后台线程刷新间隔
LHM_URL = "http://127.0.0.1:8085/data.json"   # LibreHardwareMonitor web server（可选）

PS_SCRIPT = (
    "$ErrorActionPreference='SilentlyContinue';"
    "$z=@(Get-CimInstance Win32_PerfRawData_Counters_ThermalZoneInformation |"
    " ForEach-Object { @{n=$_.Name; hp=[double]$_.HighPrecisionTemperature} });"
    "$z | ConvertTo-Json -Compress"
)

_state = {"ts": 0.0, "body": "", "temp_ts": 0.0, "temp": [],
          "temp_src": "unknown", "temp_reliable": None, "temp_note": "not_probed_yet",
          "hw": [], "hw_ts": 0.0, "err": ""}
_lock = threading.Lock()


def read_temp_wmi():
    """ACPI 热区温度（多数主板返回固定占位值，需配合可靠性判定使用）"""
    p = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", PS_SCRIPT],
        capture_output=True, text=True, timeout=25,
    )
    if p.returncode != 0 or not p.stdout.strip():
        raise RuntimeError("rc=%s %s" % (p.returncode, p.stderr.strip()[:160]))
    raw = json.loads(p.stdout.strip())
    if isinstance(raw, dict):
        raw = [raw]
    out = []
    for z in raw:
        hp = z.get("hp")
        if hp:
            name = str(z.get("n") or "").replace("\\", "").split(".")[-1] or "TZ"
            out.append((name, hp / 10.0 - 273.15))
    return out


# LHM 分组名 -> (指标名, 单位后缀裁剪)
LHM_GROUPS = {
    "temperatures": ("host_hw_temperature_celsius", "celsius"),
    "fans":         ("host_hw_fan_rpm", "rotrpm"),
    "powers":       ("host_hw_power_watt", "watt"),
    "clocks":       ("host_hw_clock_megahertz", "mhz"),
    "loads":        ("host_hw_load_percent", "percent"),
    "controls":     ("host_hw_control_percent", "percent"),
    # voltages 基数太大（100+），默认不采集
}
HW_TTL = 15

# LHM 里 GPU 显存节点（Text 小写）-> (指标名, 单位换算 MiB->B)
#
# 为什么单独处理：这些节点位于 "<GPU 名>/Data/..." 与 "<GPU 名>/Load/..." 下，
# 不属于 LHM_GROUPS 的任何传感器分组（那些靠 "temperatures"/"Loads" 这类分组名匹配），
# 漏掉的话就看不到 WDDM 的显存去向。
#
# 2026-09-12 背景：RTX 4090 可用显存只剩几百 MiB，WSL2/WDDM 会把一部分显存
# 兜底放到**主机内存**里（Shared），全程无日志、无报错，但推理会静默变慢
# （实测：主机内存里的显存 ~400 MiB 时 76 tok/s，涨到 ~850 MiB 以上掉到 9 tok/s）。
# 之前只能靠手动跑 PowerShell Get-Counter 才看得到，现在直接导出成指标。
#
# 单位说明：LHM 显示的 "MB" 实为 MiB（已与 Get-Counter 的 Total Committed 交叉验证，
# 两者数值一致），故换算用 1024*1024。
LHM_MEM_ITEMS = {
    "d3d dedicated memory used": ("host_gpu_memory_dedicated_bytes", 1048576.0),
    "d3d shared memory used":    ("host_gpu_memory_shared_bytes",    1048576.0),
    "gpu memory total":          ("host_gpu_memory_physical_bytes",  1048576.0),
    "gpu memory used":           ("host_gpu_memory_used_bytes",      1048576.0),
    "gpu memory free":           ("host_gpu_memory_free_bytes",      1048576.0),
    # 显存控制器利用率：退化诊断的关键指标（健康 66-73%，退化时只剩 1-9%）
    "gpu memory controller":     ("host_gpu_memory_controller_percent", 1.0),
}


def _num(v):
    """'62.0 °C' -> 62.0 ; '1,218 RPM' -> 1218.0"""
    try:
        return float(str(v).strip().replace(",", "").split()[0])
    except Exception:
        return None


def read_lhm():
    """拉取 LibreHardwareMonitor 的传感器树，返回 [(group_key, hardware, sensor, value)]"""
    import urllib.request
    # 必须绕过系统代理：Windows 上 urllib 默认走 WinINet 代理，访问 127.0.0.1 会被代理
    # 拦成 502，导致误判 LHM 不可用
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(LHM_URL, headers={"User-Agent": "host-exporter"})
    with opener.open(req, timeout=3) as r:
        data = json.loads(r.read().decode("utf-8", "ignore"))

    out = []

    def walk(node, parts):
        if not isinstance(node, dict):
            return
        text = str(node.get("Text") or "")
        val = node.get("Value")
        cur = parts + [text]
        if val not in (None, "", "Value") and len(cur) >= 4:
            low = [p.lower() for p in cur]
            hardware = cur[2] if len(cur) > 2 else "unknown"
            for key in LHM_GROUPS:
                if key in low:
                    v = _num(val)
                    if v is not None:
                        out.append((key, hardware, text, v))
                    break
            else:
                # 不属于任何传感器分组时，再看是不是 GPU 显存节点。
                # 用 group_key="gpumem" 标记，build() 里单独输出。
                item = LHM_MEM_ITEMS.get(text.lower())
                if item is not None:
                    v = _num(val)
                    if v is not None:
                        out.append(("gpumem", hardware, item[0], v * item[1]))
        for ch in (node.get("Children") or []):
            walk(ch, cur)

    walk(data, [])
    return out


def pick_cpu_temp(rows):
    """从 LHM 温度里挑最合适的 CPU 温度: Core Max / Package / Tctl / Tdie > 主板 CPU Core"""
    temps = [(h, s, v) for g, h, s, v in rows if g == "temperatures"]
    if not temps:
        return []
    # 优先 CPU 自身的封装/核心温度
    for key in ("core max", "package", "tctl", "tdie", "cpu total", "total"):
        for h, s, v in temps:
            if key in s.lower():
                return [(s, v)]
    for h, s, v in temps:
        if "cpu" in s.lower() or "cpu" in h.lower():
            return [(s, v)]
    return [(temps[0][1], temps[0][2])]


# 可靠性判定缓存（ACPI 固定值只需判定一次，10 分钟内复用）
_rel = {"ts": 0.0, "reliable": None, "note": ""}


def wmi_reliability():
    """连续采样 3 次，完全相同 -> 判定为固定占位值"""
    now = time.time()
    if _rel["reliable"] is not None and now - _rel["ts"] < 600:
        return _rel["reliable"], _rel["note"]
    samples = []
    for _ in range(3):
        try:
            samples.append(tuple(round(c, 2) for _, c in read_temp_wmi()))
        except Exception:
            break
        time.sleep(2)
    if not samples:
        rel, note = 0, "unavailable"
    elif len(samples) >= 2 and len(set(samples)) == 1:
        rel, note = 0, "fixed_placeholder_value"
    else:
        rel, note = 1, ""
    _rel.update(ts=now, reliable=rel, note=note)
    return rel, note


def detect_temp():
    """返回 (source, zones, reliable, note, hw_rows)"""
    try:
        rows = read_lhm()
        if rows:
            return "librehardwaremonitor", pick_cpu_temp(rows), 1, "", rows
    except Exception:
        pass
    try:
        z = read_temp_wmi()
    except Exception:
        return "none", [], 0, "unavailable", []
    rel, note = wmi_reliability()
    return "acpi_thermal_zone", z, rel, note, []


def temp_worker():
    while True:
        try:
            src, zones, rel, note, rows = detect_temp()
            with _lock:
                _state["temp_src"] = src
                _state["temp"] = zones
                _state["temp_reliable"] = rel
                _state["temp_note"] = note
                _state["hw"] = rows
                _state["hw_ts"] = time.time()
        except Exception as e:
            with _lock:
                _state["err"] = str(e)
        time.sleep(TEMP_TTL)


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def build():
    t0 = time.time()
    L = []
    a = L.append
    H = 'host="windows"'

    # ---------------- CPU ----------------
    cpu = psutil.cpu_percent(interval=0.3)
    a("# HELP host_cpu_usage_percent Windows host CPU utilization percentage")
    a("# TYPE host_cpu_usage_percent gauge")
    a("host_cpu_usage_percent{%s} %s" % (H, cpu))

    a("# HELP host_cpu_logical_cores Windows host logical CPU cores")
    a("# TYPE host_cpu_logical_cores gauge")
    a("host_cpu_logical_cores{%s} %s" % (H, psutil.cpu_count(logical=True) or 0))

    a("# HELP host_cpu_usage_per_core_percent Windows host per-core CPU utilization")
    a("# TYPE host_cpu_usage_per_core_percent gauge")
    for i, v in enumerate(psutil.cpu_percent(interval=None, percpu=True)):
        a('host_cpu_usage_per_core_percent{%s,cpu="%d"} %s' % (H, i, v))

    # ---------------- 温度 ----------------
    # 只在数据源可靠时输出温度值；不可靠（ACPI 固定占位值）时不输出假曲线，
    # 改为输出 reliable=0 与 source_info，由 Grafana 面板显示"不可用"
    src = _state["temp_src"]
    rel = 1 if _state["temp_reliable"] else 0
    note = _state["temp_note"] or ""
    a("# HELP host_cpu_temperature_celsius CPU temperature in celsius (only when source is reliable)")
    a("# TYPE host_cpu_temperature_celsius gauge")
    if rel:
        for name, c in _state["temp"]:
            a('host_cpu_temperature_celsius{%s,zone="%s",source="%s"} %.1f'
              % (H, esc(name), src, c))
    a("# HELP host_cpu_temperature_reliable 1 if a trustworthy CPU temperature source is available")
    a("# TYPE host_cpu_temperature_reliable gauge")
    a("host_cpu_temperature_reliable{%s} %s" % (H, rel))
    a("# HELP host_cpu_temperature_source_info Always 1; labels describe the current temperature source")
    a("# TYPE host_cpu_temperature_source_info gauge")
    a('host_cpu_temperature_source_info{%s,source="%s",reliable="%s",note="%s"} 1'
      % (H, esc(src), rel, esc(note)))

    # ---------------- LibreHardwareMonitor 硬件传感器 ----------------
    # 温度 / 风扇 / 功耗 / 频率 / 占用 / 风扇占空比，标签带 hardware + sensor
    agg = {}
    for g, hwname, sensor, v in (_state.get("hw") or []):
        m = LHM_GROUPS.get(g)
        if not m:
            continue
        agg.setdefault(m[0], []).append((hwname, sensor, v))
    for metric in sorted(agg):
        a("# HELP %s Hardware sensor from LibreHardwareMonitor" % metric)
        a("# TYPE %s gauge" % metric)
        for hwname, sensor, v in agg[metric]:
            a('%s{%s,hardware="%s",sensor="%s"} %s'
              % (metric, H, esc(hwname), esc(sensor), v))

    # ---------------- GPU 显存（WDDM 口径）----------------
    # dedicated = 真在 VRAM 里；shared = 被兜底到主机内存的那部分（访问要走 PCIe，慢得多）。
    # 判据用 committed 对 physical，而不是"shared 有多大"—— 因为 shared 会随负载波动，
    # 空闲时仍居高不下才是真退化（需要重启进程回收）。
    gmem = {}
    for g, hwname, metric, v in (_state.get("hw") or []):
        if g == "gpumem":
            gmem.setdefault(metric, []).append((hwname, v))
    for metric in sorted(gmem):
        a("# HELP %s GPU memory metric from LibreHardwareMonitor (WDDM counters)" % metric)
        a("# TYPE %s gauge" % metric)
        for hwname, v in gmem[metric]:
            if metric.endswith("_percent"):
                a('%s{%s,hardware="%s"} %.1f' % (metric, H, esc(hwname), v))
            else:
                a('%s{%s,hardware="%s"} %.0f' % (metric, H, esc(hwname), v))

    ded = dict((h, v) for h, v in gmem.get("host_gpu_memory_dedicated_bytes", []))
    shr = dict((h, v) for h, v in gmem.get("host_gpu_memory_shared_bytes", []))
    if ded or shr:
        a("# HELP host_gpu_memory_committed_bytes Dedicated + Shared = WDDM Total Committed; "
          "compare with host_gpu_memory_physical_bytes to spot overcommit")
        a("# TYPE host_gpu_memory_committed_bytes gauge")
        for h in sorted(set(ded) | set(shr)):
            a('host_gpu_memory_committed_bytes{%s,hardware="%s"} %.0f'
              % (H, esc(h), ded.get(h, 0.0) + shr.get(h, 0.0)))

    # ---------------- 内存 ----------------
    vm = psutil.virtual_memory()
    a("# HELP host_memory_total_bytes Physical memory total bytes")
    a("# TYPE host_memory_total_bytes gauge")
    a("host_memory_total_bytes{%s} %s" % (H, vm.total))
    a("# HELP host_memory_used_bytes Physical memory used bytes")
    a("# TYPE host_memory_used_bytes gauge")
    a("host_memory_used_bytes{%s} %s" % (H, vm.used))
    a("# HELP host_memory_free_bytes Physical memory available bytes")
    a("# TYPE host_memory_free_bytes gauge")
    a("host_memory_free_bytes{%s} %s" % (H, vm.available))
    a("# HELP host_memory_usage_percent Physical memory usage percentage")
    a("# TYPE host_memory_usage_percent gauge")
    a("host_memory_usage_percent{%s} %.2f" % (H, vm.percent))

    sw = psutil.swap_memory()
    a("# HELP host_commit_total_bytes Commit/pagefile limit bytes")
    a("# TYPE host_commit_total_bytes gauge")
    a("host_commit_total_bytes{%s} %s" % (H, sw.total))
    a("# HELP host_commit_used_bytes Commit/pagefile used bytes")
    a("# TYPE host_commit_used_bytes gauge")
    a("host_commit_used_bytes{%s} %s" % (H, sw.used))
    a("# HELP host_commit_usage_percent Commit/pagefile usage percentage")
    a("# TYPE host_commit_usage_percent gauge")
    a("host_commit_usage_percent{%s} %.2f" % (H, sw.percent))

    # ---------------- 磁盘 ----------------
    names = ["host_disk_total_bytes", "host_disk_used_bytes",
             "host_disk_free_bytes", "host_disk_usage_percent"]
    helps = ["Logical disk total bytes", "Logical disk used bytes",
             "Logical disk free bytes", "Logical disk usage percentage"]
    for n, h in zip(names, helps):
        a("# HELP %s %s" % (n, h))
        a("# TYPE %s gauge" % n)
    seen = set()
    for part in psutil.disk_partitions(all=False):
        dev = (part.device or "").rstrip("\\")
        if dev in seen or "cdrom" in (part.opts or "").lower():
            continue
        try:
            u = psutil.disk_usage(part.mountpoint)
        except Exception:
            continue
        if u.total <= 0:
            continue
        seen.add(dev)
        l = '%s,device="%s",mountpoint="%s"' % (H, esc(dev), esc(part.mountpoint))
        a("host_disk_total_bytes{%s} %s" % (l, u.total))
        a("host_disk_used_bytes{%s} %s" % (l, u.used))
        a("host_disk_free_bytes{%s} %s" % (l, u.free))
        a("host_disk_usage_percent{%s} %.2f" % (l, u.percent))

    a("# HELP host_exporter_scrape_seconds Cost of one collection")
    a("# TYPE host_exporter_scrape_seconds gauge")
    a("host_exporter_scrape_seconds{%s} %.3f" % (H, time.time() - t0))
    return "\n".join(L) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with _lock:
            now = time.time()
            # 温度由后台线程 temp_worker 负责刷新，这里不再同步阻塞（否则每次抓取多等数秒）
            if now - _state["ts"] > CACHE_TTL:
                try:
                    _state["body"] = build()
                except Exception as e:
                    _state["err"] = str(e)
                    _state["body"] = ""
                _state["ts"] = now
            body = _state["body"] or ("# ERROR %s\n" % _state["err"])
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    if "--test" in sys.argv:
        with _lock:
            src, zones, rel, note, rows = detect_temp()
            _state["temp_src"] = src
            _state["temp"] = zones
            _state["temp_reliable"] = rel
            _state["temp_note"] = note
            _state["hw"] = rows
            print(build())
        sys.exit(0)
    threading.Thread(target=temp_worker, daemon=True).start()
    print("host_exporter_win listening on 0.0.0.0:%d" % PORT, flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
