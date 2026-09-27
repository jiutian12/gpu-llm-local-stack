#!/usr/bin/env python3
"""GPU Prometheus exporter: 采样 nvidia-smi 输出为 Prometheus 指标 (端口 9400)"""
import subprocess, time, http.server, threading, re

PORT = 9400
CACHE_TTL = 3  # 秒，缓存采样结果

QUERY = ('index,name,utilization.gpu,utilization.memory,memory.used,memory.total,'
         'temperature.gpu,power.draw,fan.speed,clocks.sm,clocks.mem,'
         'pcie.link.gen.current,pcie.link.width.current,driver_version')

_cache = {'ts': 0, 'body': ''}
_lock = threading.Lock()

def sanitize(s):
    return re.sub(r'[^a-zA-Z0-9_:]', '_', s).replace(' ', '_')

def collect():
    try:
        out = subprocess.run(
            ['nvidia-smi', '--query-gpu=' + QUERY, '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=5).stdout
        dver = ''
        lines = []
        for line in out.strip().splitlines():
            p = [x.strip() for x in line.split(',')]
            if len(p) < 12:
                continue
            idx, name = p[0], p[1]
            util_gpu, util_mem = p[2], p[3]
            mem_used, mem_total = p[4], p[5]
            temp = p[6]
            power = p[7]
            fan = p[8]
            clk_sm, clk_mem = p[9], p[10]
            pcie_gen, pcie_w = p[11], p[12]
            dver = p[13] if len(p) > 13 else ''
            g = 'gpu="%s",name="%s"' % (idx, name)
            lines.append('# HELP gpu_utilization_gpu_percent GPU utilization %%')
            lines.append('# TYPE gpu_utilization_gpu_percent gauge')
            lines.append('gpu_utilization_gpu_percent{%s} %s' % (g, util_gpu))
            lines.append('# HELP gpu_utilization_memory_percent GPU memory bandwidth utilization %%')
            lines.append('# TYPE gpu_utilization_memory_percent gauge')
            lines.append('gpu_utilization_memory_percent{%s} %s' % (g, util_mem))
            lines.append('# HELP gpu_memory_used_bytes GPU memory used bytes')
            lines.append('# TYPE gpu_memory_used_bytes gauge')
            lines.append('gpu_memory_used_bytes{%s} %s' % (g, float(mem_used) * 1024 * 1024))
            lines.append('# HELP gpu_memory_total_bytes GPU memory total bytes')
            lines.append('# TYPE gpu_memory_total_bytes gauge')
            lines.append('gpu_memory_total_bytes{%s} %s' % (g, float(mem_total) * 1024 * 1024))
            lines.append('# HELP gpu_memory_free_bytes GPU memory free bytes')
            lines.append('# TYPE gpu_memory_free_bytes gauge')
            lines.append('gpu_memory_free_bytes{%s} %s' % (g, (float(mem_total) - float(mem_used)) * 1024 * 1024))
            lines.append('# HELP gpu_temperature_celsius GPU temperature')
            lines.append('# TYPE gpu_temperature_celsius gauge')
            lines.append('gpu_temperature_celsius{%s} %s' % (g, temp))
            lines.append('# HELP gpu_power_watts GPU power draw')
            lines.append('# TYPE gpu_power_watts gauge')
            lines.append('gpu_power_watts{%s} %s' % (g, power))
            lines.append('# HELP gpu_fan_speed_percent GPU fan speed')
            lines.append('# TYPE gpu_fan_speed_percent gauge')
            lines.append('gpu_fan_speed_percent{%s} %s' % (g, fan))
            lines.append('# HELP gpu_clock_sm_mhz GPU SM clock')
            lines.append('# TYPE gpu_clock_sm_mhz gauge')
            lines.append('gpu_clock_sm_mhz{%s} %s' % (g, clk_sm))
            lines.append('# HELP gpu_clock_mem_mhz GPU memory clock')
            lines.append('# TYPE gpu_clock_mem_mhz gauge')
            lines.append('gpu_clock_mem_mhz{%s} %s' % (g, clk_mem))
            lines.append('# HELP gpu_pcie_link_gen GPU PCIe link gen')
            lines.append('# TYPE gpu_pcie_link_gen gauge')
            lines.append('gpu_pcie_link_gen{%s} %s' % (g, pcie_gen))
            lines.append('# HELP gpu_pcie_link_width GPU PCIe link width')
            lines.append('# TYPE gpu_pcie_link_width gauge')
            lines.append('gpu_pcie_link_width{%s} %s' % (g, pcie_w))
        if dver:
            lines.append('# HELP gpu_driver_version GPU driver version (1)')
            lines.append('# TYPE gpu_driver_version gauge')
            lines.append('gpu_driver_version{version="%s"} 1' % sanitize(dver))
        return '\n'.join(lines)
    except Exception as e:
        return '# ERROR %s' % e


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?')[0] != '/metrics':
            self.send_response(404)
            self.end_headers()
            return
        with _lock:
            if time.time() - _cache['ts'] > CACHE_TTL:
                _cache['body'] = collect()
                _cache['ts'] = time.time()
            body = _cache['body']
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
