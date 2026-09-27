#!/bin/bash
# ============================================================
#  stop_wsl_services.sh —— 停止 WSL 侧全部服务
#
#  由 stop_all.ps1 调用（也可单独执行）:
#      bash /mnt/c/Users/administrat0r/stop_wsl_services.sh [--with-pg]
#
#  默认保留 PostgreSQL（litellm 的用量数据在里面，重启不值当）。
#  加 --with-pg 才一并停掉。
#
#  幂等: 已停止的会跳过；可反复执行
# ============================================================
set -u

WITH_PG=0
for a in "$@"; do [ "$a" = "--with-pg" ] && WITH_PG=1; done

MON=/home/administrat0r/monitoring
hr() { echo "------------------------------------------------------------"; }

# 精确匹配杀进程，避免误杀调用链自身（用 [c] 字符类规避自匹配）
stop_proc() {
  local pat="$1" mode="$2" name="$3"
  if pgrep $mode "$pat" >/dev/null 2>&1; then
    echo "      停止 $name ..."
    pkill $mode "$pat" 2>/dev/null || true
    for i in 1 2 3 4 5; do pgrep $mode "$pat" >/dev/null 2>&1 || break; sleep 1; done
    pkill -9 $mode "$pat" 2>/dev/null || true
    echo "      ✅ $name 已停止"
  else
    echo "      - $name 未在运行"
  fi
}

echo "============================================================"
echo " WSL 侧服务停止   $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

echo "[1/4] litellm (1234)..."
if command -v tmux >/dev/null 2>&1 && tmux has-session -t litellm 2>/dev/null; then
  tmux kill-session -t litellm 2>/dev/null && echo "      已结束 tmux session 'litellm'"
fi
stop_proc "[l]itellm --config" -f "litellm"

echo "[2/4] 模型后端 (18020)..."
# 三个后端各用各自的 tmux 会话名（vllm / vllmbonsai / bonsai），一律清掉
for SESS in vllm vllmbonsai bonsai; do
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t $SESS 2>/dev/null; then
    tmux kill-session -t $SESS 2>/dev/null && echo "      已结束 tmux session '$SESS'"
  fi
done
stop_proc "[v]llm serve" -f "vLLM"
stop_proc "[l]lama-server" -f "llama-server"
# vLLM 的子进程（EngineCore / APIServer）随父进程退出，等一会儿再兜底清一遍
sleep 3
stop_proc "[V]LLM::EngineCore" -f "vLLM EngineCore"

echo "[3/4] 监控组件 (9090/3000/9400/9410)..."
stop_proc prometheus -x "Prometheus"
stop_proc grafana-server -x "Grafana"
stop_proc "monitoring/gpu_exporter.py" -f "GPU exporter"
stop_proc "monitoring/llm_trace_api.py" -f "LLM 瀑布流"

echo "[4/4] PostgreSQL (5432)..."
if [ "$WITH_PG" = "1" ]; then
  if pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    pg_ctlcluster 18 main stop 2>/dev/null || service postgresql stop 2>/dev/null || true
    sleep 2
    echo "      ✅ 已停止"
  else
    echo "      - 未在运行"
  fi
else
  echo "      - 保留运行（要一并停止请加 --with-pg）"
fi

# 清理 vLLM 可能残留的 offload 共享内存段
for f in /dev/shm/vllm_offload_*.mmap; do
  [ -e "$f" ] || continue
  grep -lqs "$f" /proc/[0-9]*/maps 2>/dev/null || rm -f "$f"
done

sleep 3
echo
hr
echo " 端口释放情况"
hr
for pair in "18020:vLLM" "1234:litellm" "9090:Prometheus" "3000:Grafana" "9400:GPU exporter" "9410:LLM 瀑布流" "5432:PostgreSQL"; do
  P=${pair%%:*}; N=${pair#*:}
  if ss -tln 2>/dev/null | grep -q ":$P "; then
    printf "  %-8s %-16s 仍占用\n" "$P" "$N"
  else
    printf "  %-8s %-16s 已释放\n" "$P" "$N"
  fi
done
echo
echo "  残留 tmux 会话: $(tmux ls 2>/dev/null | tr '\n' ' ' || echo '无')"
hr
