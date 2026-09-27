#!/bin/bash
# 一键启动监控组件（WSL 侧 + Windows 侧）
#   WSL 侧    : GPU exporter(9400) + Prometheus(9090) + Grafana(3000) + 瀑布流(9410)
#   Windows 侧: 主机指标 exporter(9401, CPU/温度/内存/磁盘)
# 依赖: /home/administrat0r/monitoring/ 下已解压的 prometheus/grafana 与 gpu_exporter.py
# 注意: 不要 set -e —— 单个组件失败不应中断后续启动
MON=/home/administrat0r/monitoring
CFG=/mnt/c/Users/administrat0r/monitoring_cfg
PROM_BIN=$MON/prometheus-2.54.1.linux-amd64/prometheus
GRAFANA_HOME=$MON/grafana-v11.5.2

# --- 杀旧进程（精确匹配，避免误杀调用链） ---
stop_proc() {
  local pat="$1" mode="$2"
  if pgrep $mode "$pat" >/dev/null 2>&1; then
    echo "[INFO] 停止旧进程: $pat ..."
    pkill $mode "$pat" 2>/dev/null || true
    for i in 1 2 3 4 5; do pgrep $mode "$pat" >/dev/null 2>&1 || break; sleep 1; done
    pkill -9 $mode "$pat" 2>/dev/null || true
  fi
}
stop_proc prometheus -x
stop_proc grafana-server -x
stop_proc "monitoring/gpu_exporter.py" -f
stop_proc "monitoring/llm_trace_api.py" -f
sleep 2

# --- 等待端口释放（防 bind 失败） ---
for P in 9090 3000 9400 9410; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ss -tln 2>/dev/null | grep -q ":$P " || break
    sleep 1
  done
done

echo "[1/4] 启动 GPU exporter (端口 9400)..."
nohup python3 "$MON/gpu_exporter.py" > "$MON/gpu_exporter.log" 2>&1 &

echo "[2/4] 启动 Prometheus (端口 9090)..."
# Prometheus 的 Go http client 默认跟随环境变量代理，抓 127.0.0.1 会被代理拦成
# "context deadline exceeded"（看着像端口不通，其实是走了代理）—— 必须显式排除本机
export no_proxy="127.0.0.1,localhost,0.0.0.0${no_proxy:+,$no_proxy}"
export NO_PROXY="$no_proxy"
nohup "$PROM_BIN" --config.file="$CFG/prometheus.yml" \
  --storage.tsdb.path="$MON/prometheus-data" \
  --web.listen-address=0.0.0.0:9090 > "$MON/prometheus.log" 2>&1 &

echo "[3/4] 启动 Grafana (端口 3000, 默认账号 admin/admin)..."
nohup "$GRAFANA_HOME/bin/grafana-server" \
  --homepath="$GRAFANA_HOME" \
  --config="$GRAFANA_HOME/conf/defaults.ini" \
  web > "$MON/grafana.log" 2>&1 &

echo "[4/5] 启动 LLM 瀑布流服务 (端口 9410)..."
# 幂等：端口已被占用（例如跑在 tmux session llmtrace 里）则不再重复拉起，
# 否则新进程 bind 失败、日志里留一堆 Address already in use
if ss -tln 2>/dev/null | grep -q ":9410 "; then
  echo "      ✅ 9410 已在监听，跳过启动"
else
  nohup python3 "$MON/llm_trace_api.py" --port 9410 > "$MON/llm_trace_api.log" 2>&1 &
fi

echo "[5/5] Windows 主机指标 exporter (端口 9401, CPU/温度/内存/磁盘)..."
# ⚠️ 9401 必须由 Windows 侧拉起，WSL 内不再尝试调 powershell.exe：
#    WSL 常驻进程调 Windows 可执行文件会 UtilAcceptVsock 超时挂死（实测 3 分钟只成功 1 次）。
#    一键启动入口: 双击 C:\Users\administrat0r\start_all.bat
#                (或 PowerShell: start_all.ps1)，由 Windows 侧先起 9401 再拉起本脚本。
# WSL 是镜像网络，Windows 进程 bind 9401 后 WSL 的 127.0.0.1:9401 直接可达，这里只做探测。
if curl -s -m 6 --noproxy '*' -o /dev/null "http://127.0.0.1:9401/metrics"; then
  echo "      ✅ 9401 已在监听 (Windows 侧)"
else
  echo "      ⚠️ 9401 未监听。请在 Windows 侧执行: 双击 C:\\Users\\administrat0r\\start_all.bat"
  echo "         （或 PowerShell: powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\administrat0r\\start_all.ps1）"
  echo "         （或单独拉起: C:\\Users\\administrat0r\\monitoring_cfg\\start_host_exporter.bat）"
fi

sleep 6
for P in 9400 9090 3000 9410 9401; do
  if ss -tln 2>/dev/null | grep -q ":$P "; then
    echo "  ✅ :$P 监听"
  elif [ "$P" = "9401" ] && curl -s -m 5 --noproxy '*' -o /dev/null "http://127.0.0.1:9401/metrics"; then
    echo "  ✅ :$P 监听 (Windows 侧，ss 不可见)"
  else
    echo "  ⚠️ :$P 未监听（查看 $MON/*.log）"
  fi
done
echo "GPU exporter: http://127.0.0.1:9400/metrics"
echo "主机指标    : http://127.0.0.1:9401/metrics  (Windows 侧, CPU/温度/内存/磁盘)"
echo "Prometheus  : http://127.0.0.1:9090"
echo "Grafana     : http://127.0.0.1:3000  (admin / admin)"
echo "瀑布流网页  : http://127.0.0.1:9410/  (LLM 实时输入/输出/思考过程，数据源 LiteLLM_SpendLogs)"
