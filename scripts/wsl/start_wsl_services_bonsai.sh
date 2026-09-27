#!/bin/bash
# ============================================================
#  start_wsl_services_bonsai.sh —— WSL 侧一键拉起【Bonsai 2 27B】后端全套
#
#  由 Windows 侧 start_all.ps1 -Backend bonsai 调用（默认后端）。
#  与 start_wsl_services.sh 的区别：模型后端从 vLLM 换成
#  PrismML llama.cpp fork + Bonsai 2 27B (ternary 2-bit GGUF)。
#
#  服务链（按依赖顺序）:
#      [1] PostgreSQL             5432
#      [2] llama.cpp 模型后端      18020  ← Bonsai 2 27B PTQ1_0 + KV q4_0
#      [3] litellm 统一入口        1234   ← OpenAI + Anthropic 双格式，写用量到 PG
#      [4] 监控                   9090 Prometheus / 3000 Grafana
#                                 9400 GPU exporter / 9410 LLM 瀑布流
#
#  ⚠️ 前置条件：Windows 侧的显存守护进程必须已停。
#     gpu_overcommit_guard.ps1 -Watch -EnableRestart 会在 vLLM 消失后
#     调 restart_vllm.sh --force 把它拉回来抢显存。start_all.ps1 -Backend bonsai
#     已内置"先停守护"这一步，单独跑本脚本前请确认守护已停。
#
#  幂等: 已在运行的服务会跳过，可反复执行
#  注意: 刻意不写 set -e —— 单个组件失败不应中断后续启动
# ============================================================
#
#  ============ 运行约束与实测基线（2026-09-19，RTX 4090 24GB）============
#
#  1) 权重档位（2026-09-19 同 NP=2 口径实测，单路 cache_prompt=false）
#
#       depth     PTQ1_0 prefill   PQ2_0 prefill   PTQ1_0 decode   PQ2_0 decode
#       32k          1530.0 t/s       2726.1 t/s       69.1 t/s       65.1 t/s
#       100k         1328.9 t/s       1649.8 t/s       51.7 t/s       46.3 t/s
#       200k          943.3 t/s        912.4 t/s       36.5 t/s       23.5 t/s
#       250k          831.8 t/s        729.1 t/s       32.3 t/s       18.3 t/s
#       2 路各 250k 并发: PTQ1_0 wall 500.0s / 单路 decode 15.9 t/s / prefill 748/路
#                         PQ2_0  wall 617.2s / 单路 decode  9.5 t/s / prefill 591/路
#
#     ⚠️ 交叉点约在 150k：浅中深度 PQ2_0 的 prefill 明显更快，但 200k 以上
#        PTQ1_0 在 prefill 和解码上双双反超，且解码差距随深度越拉越大。
#     ⚠️ 「吃长 prompt」不等于该选 PQ2_0 —— 实测多轮前缀复用完全生效
#        （30k 上下文，第 2 轮起 prompt_n 只有 44~46 token，缓存命中 ~30k，
#          单轮总耗时从 23.6s 降到 1.4~2.0s，且插入分类器小请求也不会逐出），
#        所以**每轮的真实成本几乎全在解码**，而 PTQ1_0 解码全面更快。
#     ⚠️ PTQ1_0 还多一个优势：体积小 1.26 GB，每路满 256k 时能开 3 路
#        （PQ2_0 下 NP=3 未实测，空闲就 23892 MiB，余量仅 672 MiB，判定为不可靠）。
#     结论：默认 PTQ1_0。只有当你的负载是"浅深度 + 大量冷启动一次性长 prompt"
#           （例如批量文档问答，几乎不吃多轮缓存）时，才用 BONSAI_QUANT=PQ2_0。
#     切换：BONSAI_QUANT=PQ2_0 BONSAI_NP=2 bash start_wsl_services_bonsai.sh
#
#  2) KV 缓存必须压到 q4_0
#       FP16 KV 每 262144 token 要约 16 GiB，24 GB 卡装不下。
#       q4_0 约 4.5 GiB / 256k，实测可用。
#
#  3) 并发上限（每路都要满 262144 时）
#       NP=3 是实测上限。NP=4 能加载、空闲显存也只多 546 MiB，但真填上下文时
#       prefill 从 ~1500 t/s 崩到 16 t/s、板卡功耗 297W→96W（GPU 利用率仍 99%），
#       是典型的 WDDM 显存超配。**判定这类问题最快的单一指标就是板卡功耗。**
#       健康基线：prefill 期功耗 ~400W，解码期 ~230-300W，空闲 6-8W。
#
#  4) 速率基线（PTQ1_0，单路，cache_prompt=false）
#       深度 0     -> 解码 79.9 t/s
#       32k        -> prefill 1512.7 t/s / 解码 66.3 t/s
#       100k       -> prefill 1314.4 t/s / 解码 50.0 t/s
#       200k       -> prefill 1077.9 t/s / 解码 36.5 t/s
#       250k       -> prefill  986.0 t/s / 解码 32.1 t/s
#       NP=3 三路各 245k 并发：12m34s 跑通，峰值 401.81W，显存 24112 MiB
#
#  5) litellm 接线零改动
#       llama-server 用 --alias qwen3.8-27b 监听 18020，与 vLLM 同端口同模型名，
#       litellm_config.yaml 的 api_base 不用动。
#
#  6) 日志: tmux attach -t bonsai   /   ~/bonsai/logs/server_np<N>.log
#     停止: bash ~/stop_bonsai.sh
# ============================================================

# ---- 路径参数：Windows 侧用户目录在 WSL 里的挂载点 ----
# 默认取当前 WSL 用户名；若 Windows 用户名与之不同，请显式导出：
#   export WINHOME=/mnt/c/Users/<你的Windows用户名>
WINHOME="${WINHOME:-/mnt/c/Users/${USER:-YOURUSERNAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON=$HOME/monitoring
BONSAI_ROOT=$HOME/bonsai
LM_KEY="sk-lm-REPLACE_ME"
PORT_MODEL=18020
PORT_LITELLM=1234

# ---- 可调参数（用环境变量覆盖）----
NP="${BONSAI_NP:-3}"                  # 并发槽位数，每槽 262144 上下文
DEFAULT_QUANT="${BONSAI_QUANT:-PTQ1_0}"
MMPROJ="${BONSAI_MMPROJ:-1}"          # 1=加载视觉塔，0=省约 0.6 GiB
PER_CTX="${BONSAI_PER_CTX:-262144}"

hr() { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " WSL 侧服务启动【Bonsai 2 27B / llama.cpp】  $(date '+%Y-%m-%d %H:%M:%S')"
echo " 权重=$DEFAULT_QUANT  并发=$NP 路 x 每路 $PER_CTX  视觉=$MMPROJ"
echo "============================================================"

# ------------------------------------------------------------
echo "[1/4] PostgreSQL (5432)..."
if pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
  echo "      ✅ 已在运行"
else
  pg_ctlcluster 18 main start 2>/dev/null || service postgresql start 2>/dev/null || true
  sleep 3
  if pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    echo "      ✅ 已启动"
  else
    echo "      ⚠️ 未就绪；litellm 的用量记录会失败（其余功能不受影响）"
  fi
fi

# ------------------------------------------------------------
echo "[2/4] llama.cpp / Bonsai 2 27B (${PORT_MODEL})..."
model_ready() {
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT_MODEL}/health 2>/dev/null)" = "200" ]
}

# 检查当前跑的到底是不是我们想要的配置，不能只看"端口活着"
need_restart=0
if model_ready; then
  CUR_ARGS=$(ps -eo args | grep '[l]lama-server' | head -1)
  if [ -z "$CUR_ARGS" ]; then
    need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "-np $NP "; then
    echo "      ⚠️ 当前进程 NP 不是 $NP，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q "$DEFAULT_QUANT.gguf"; then
    echo "      ⚠️ 当前进程权重不是 $DEFAULT_QUANT，需要重启"; need_restart=1
  else
    echo "      ✅ 已在运行且配置匹配，跳过启动"
  fi
fi

if [ "$need_restart" = "1" ]; then
  tmux kill-session -t bonsai 2>/dev/null || true
  pkill -f '[l]lama-server' 2>/dev/null || true
  sleep 3
fi

if ! model_ready; then
  # 先把抢显存的 vLLM 清掉（vLLM 与 Bonsai 无法共存于一张 24G 卡）
  if pgrep -f '[v]llm serve' >/dev/null 2>&1; then
    echo "      检测到 vLLM 在跑，先停掉（两者不能共存）..."
    tmux kill-session -t vllm 2>/dev/null || true
    pkill -f '[v]llm serve' 2>/dev/null || true
    sleep 6
    pkill -9 -f '[v]llm serve' 2>/dev/null || true
    sleep 3
  fi

  mkdir -p "${BONSAI_ROOT}/logs"
  LOG="${BONSAI_ROOT}/logs/server_np${NP}.log"
  # tmux new-session 不继承调用者环境变量，env 必须写进命令串
  tmux new-session -d -s bonsai \
    "NP=$NP PER_CTX=$PER_CTX QUANT=$DEFAULT_QUANT KV4=1 MMPROJ=$MMPROJ PORT=$PORT_MODEL \
     bash $HOME/bonsai_start.sh 2>&1 | tee $LOG"
  echo "      已在 tmux session 'bonsai' 中启动（日志: tmux attach -t bonsai）"

  echo "      等待就绪（llama.cpp 加载 5.9 GB + KV 分配，约 10-30 秒）..."
  OK=0
  for i in $(seq 1 60); do
    if model_ready; then OK=1; break; fi
    if ! pgrep -f '[l]lama-server' >/dev/null 2>&1 && [ "$i" -gt 3 ]; then
      echo "      ⚠️ llama-server 进程已退出，检查 $LOG"
      tail -20 "$LOG" 2>/dev/null
      break
    fi
    sleep 3
  done
  if [ "$OK" = "1" ]; then
    echo "      ✅ 模型就绪 (http://127.0.0.1:${PORT_MODEL})"
  else
    echo "      ⚠️ 模型未就绪，litellm 接下来会启动但请求会 500"
  fi
fi

# 生效参数汇总（一律从运行中的服务读）
if model_ready; then
  curl -s -m 8 "http://127.0.0.1:${PORT_MODEL}/slots" > /tmp/.bonsai_slots.json 2>/dev/null
  python3 - <<'PY' 2>/dev/null
import json
try:
    d = json.load(open('/tmp/.bonsai_slots.json'))
    print('      生效: {} 个 slot，每个 n_ctx={}'.format(len(d), d[0].get('n_ctx') if d else '?'))
    busy = sum(1 for s in d if s.get('is_processing'))
    print('      当前占用: {}/{}'.format(busy, len(d)))
except Exception:
    pass
PY
  rm -f /tmp/.bonsai_slots.json
  echo "      显存: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader)"
fi

# ------------------------------------------------------------
echo "[3/4] litellm 统一入口 (${PORT_LITELLM})..."
CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' \
       -H "Authorization: Bearer ${LM_KEY}" http://127.0.0.1:${PORT_LITELLM}/v1/models 2>/dev/null) || CODE=000
if [ "$CODE" = "200" ]; then
  echo "      ✅ 已在运行，跳过启动"
else
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t litellm 2>/dev/null || true
    tmux new-session -d -s litellm \
      "cd $WINHOME && bash start_litellm.sh 2>&1 | tee $HOME/.litellm/litellm.log"
    echo "      已在 tmux session 'litellm' 中启动"
  else
    (cd $WINHOME && nohup bash start_litellm.sh > $HOME/.litellm/litellm.log 2>&1 &)
    echo "      (未装 tmux，退回 nohup 启动)"
  fi
  LT_OK=0
  for i in $(seq 1 40); do
    CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
           -H "Authorization: Bearer ${LM_KEY}" http://127.0.0.1:${PORT_LITELLM}/v1/models 2>/dev/null) || CODE=000
    if [ "$CODE" = "200" ]; then LT_OK=1; break; fi
    sleep 3
  done
  if [ "$LT_OK" = "1" ]; then
    echo "      ✅ litellm 就绪 (http://127.0.0.1:${PORT_LITELLM})"
    BASE=$(grep -m1 -oE "api_base: *http://[^ ]*" $WINHOME/litellm_config.yaml 2>/dev/null | awk '{print $2}')
    [ -n "$BASE" ] && echo "      后端 api_base = ${BASE}"
  else
    echo "      ⚠️ litellm 未就绪，查看 $HOME/.litellm/litellm.log"
  fi
fi

# ------------------------------------------------------------
echo "[4/4] 监控组件 (Prometheus:9090 / Grafana:3000 / GPU:9400 / 瀑布流:9410)..."
if [ -f "${SCRIPT_DIR}/start_monitoring.sh" ]; then
  bash "${SCRIPT_DIR}/start_monitoring.sh" > "${MON}/start.log" 2>&1 || true
elif [ -f "${MON}/../start_monitoring.sh" ]; then
  bash "${MON}/../start_monitoring.sh" > "${MON}/start.log" 2>&1 || true
else
  echo "      ⚠️ 找不到 start_monitoring.sh，跳过"
fi
for P in 9090 3000 9400 9410; do
  POK=0
  for i in $(seq 1 8); do
    ss -tln 2>/dev/null | grep -q ":$P " && { POK=1; break; }
    sleep 2
  done
  [ "$POK" = "1" ] && echo "      ✅ :$P 监听" || echo "      ⚠️ :$P 未监听（见 ${MON}/start.log）"
done

# ------------------------------------------------------------
echo
hr
echo " WSL 侧汇总 (后端: Bonsai 2 27B / llama.cpp)"
hr
printf "  %-8s %-26s %s\n" "端口" "服务" "状态"
for pair in "5432:PostgreSQL" "18020:llama.cpp Bonsai 2 27B" "1234:litellm 统一入口" \
            "9090:Prometheus" "3000:Grafana" "9400:GPU exporter" "9410:LLM 瀑布流"; do
  P=${pair%%:*}; N=${pair#*:}
  if ss -tln 2>/dev/null | grep -q ":$P "; then
    printf "  %-8s %-26s ✅\n" "$P" "$N"
  else
    printf "  %-8s %-26s ❌\n" "$P" "$N"
  fi
done
echo
echo "  常驻 tmux 会话: $(tmux ls 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
echo "  日志: tmux attach -t bonsai | tmux attach -t litellm"
hr
