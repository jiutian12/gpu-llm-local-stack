#!/bin/bash
# ============================================================
#  start_wsl_services.sh —— 一键拉起 WSL 侧全部服务
#
#  由 Windows 侧 start_all.ps1 调用（也可在 WSL 内单独执行）:
#      bash $WINHOME/start_wsl_services.sh
#
#  服务链（按依赖顺序）:
#      [1] PostgreSQL            5432
#      [2] vLLM 单用户模式        18020   ← 模型后端（Qwen3.8-27B + DFlash2）
#      [3] litellm 统一入口        1234    ← OpenAI + Anthropic 双格式，写用量到 PG
#      [4] 监控                   9090 Prometheus / 3000 Grafana
#                                 9400 GPU exporter / 9410 LLM 瀑布流
#
#  ⚠️ 为什么没有 llama-server(1235) / vision_guard(1237):
#     它们和 vLLM 争抢同一张 24G 显存，无法共存。本脚本已彻底移除这两个组件。
#     要回退到旧的 llama.cpp 链路（200k 上下文、多模态 mmproj），
#     请用 setup/07_start.sh.bak-fast-20260910 那套，并把 litellm_config.yaml 的
#     api_base 改回 http://127.0.0.1:1237/v1。
#
#  幂等: 已在运行的服务会跳过，可反复执行
#  注意: 刻意不写 set -e —— 单个组件失败不应中断后续启动
# ============================================================

# ============================================================
#  ⚠️ 运行约束与已知坑（2026-09-11 实测；改动任何参数前先读这一节）
#
#  1) 显存超配是这台机器的头号杀手。判据是「Total Committed vs 物理显存」，
#     不是"共享显存有多大"。物理显存 24,564 MiB，当前定版（MAX_LEN=200000）committed 23,782 MiB，余量 782 MiB（占用 96.8%）。
#     余量掉到 1% 以下即开始退化、越过物理上限必崩，WDDM 会把显存挪到主机内存，性能当场塌约 10 倍：
#        MAX_SEQS=4 -> 总提交 24,921 MiB（超物理 357 MiB）-> 1 路只剩 9.1 tok/s
#        MAX_SEQS=5 -> 总提交 24,810 MiB（超物理 246 MiB）-> 4.6~11.7 tok/s
#     塌陷特征：GPU 利用率 97-99% 但**显存控制器只剩 3-9%**、功耗仅 105-130W
#     （SM 在等 PCIe，不是算不动）。健康时显存控制器 66-73%、功耗 208-240W。
#
#  2) 因此 MAX_SEQS 上限是 2，不要再调大。要提并发必须先让总提交降下来：
#       关图像 VISION=0   省约 0.86 GiB（代价：失去读图）
#       降 KV_MEM          池须 >=245,760 token，最多省约 0.35 GiB
#     注意：CTX=long 与 CTX=fast 的 KV_MEM 是 5.20 GiB，比 CTX=huge 的 4.90 GiB **更大**，
#     换档位只会更糟；KV CPU 卸载也不减少 GPU 占用（它只是把缓存延伸到内存）。
#
#  3) GPU_UTIL 在本配置下是空操作。KV_MEM 被钉住时 vLLM 会 "skipped memory profiling"，
#     GPU_UTIL 不参与任何尺寸计算。实测 0.88 与 0.93 的占用与速度完全一致
#     （23,502 MiB / 可用 637 MiB）。0.93 是该档位原生值，故用 0.93；
#     也不要往上调（start_qwen.sh 注释：MTP 的 DeltaNet workspace 会超出 profiling 估算）。
#
#  4) 启动日志里 `WARNING [envs.py] Unknown vLLM environment variable detected: XXX`
#     是**误报**，不要据此删变量。本仓库有 3 个"报警但有效"的变量，补丁代码直接读
#     os.environ，只是 envs.py 没登记：
#        VLLM_V2_CUDAGRAPH_MEM_MIB  -> v1/worker/gpu/model_runner.py
#        VLLM_DFLASH2_LOOKUP        -> cudagraph_utils.py / dflash/speculator.py
#        VLLM_SPEC_DECODE_ATTN_QMAX -> attention/backends/flash_attn.py
#     判定一个 VLLM_* 变量是否真死，必须 grep 整个 venv，不能只查 envs.py。
#
#  5) 健康基线（用来判断"是不是又退化了"）:
#       1 路解码 76 tok/s / 2 路聚合 146 tok/s / 2.72 与 1.62 J/token
#     非解码负载的功耗参考：大 prefill 峰值 411W、图像编码峰值 313W、
#     空闲 7.5W。上限 450W —— 文本解码到不了 400W 是带宽受限，不是被限住。
#
#  6) 复核命令:
#     PowerShell : Get-Counter '\GPU Adapter Memory(*)\Shared Usage','\GPU Adapter Memory(*)\Total Committed'
#     LHM        : curl -s http://127.0.0.1:8085/data.json | grep -o '"Text":"D3D [^"]*"[^}]*'
#     纯解码速率 : rate(vllm:generation_tokens_total[2m]) /
#                  rate(vllm:inter_token_latency_seconds_sum[2m])
#                  ↑ 不受客户端空闲稀释（单用 rate() 会被思考间隙拉低，别踩这个坑）
#
#  当前定版参数（07_start.sh 的默认值）:
#     CTX=huge  MAX_SEQS=2  MAX_LEN=200000  KV_MEM=4.4 GiB  GPU_UTIL=0.93
#               VISION=1  SPEC=dflash2
#     200k 上下文 / KV 池 209,059 token（300 块 x 2176）/ 注意力块 2176 / mamba 块 128
#     ⚠️ 240k（MAX_LEN=245760 + KV_MEM=5,261,334,938 -> 池 268,169）已于 2026-09-12
#        降配到 200k 档，见 07_start.sh:75-115 的注释。看到 268,169 即为过时文档，
#        一律以引擎 /metrics 的 cache_config_info{kv_cache_size_tokens} 为准。
#        回退到 240k: MAX_LEN=245760 KV_MEM=5261334938 bash setup/07_start.sh
#
#  7) 前缀缓存修复（2026-09-14 实测，改动前先读，别顺手删）:
#     export VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0   ← 写在 setup/07_start.sh
#
#     症状：auto mode 的分类器（~28k prompt、无 tools、max_tokens=64）夹在两次主会话
#           请求之间时，主会话 prefix cache 命中**塌到恰好 0**，每轮多花约 99 秒重算。
#           实测状态转移：分类器之后的主请求 89.1% 是 0 命中，基线只有 23.7%。
#
#     根因：默认(None = dense)会在**每个块边界**都留一份 mamba 状态快照，使每个缓存
#           上下文实际占用 ≈2.5–2.9× 其 token 数（docs/MR-DRAFT.md §5）。两个上下文挤
#           不下池，交错时互相把对方的快照赶走。设为 0 只保留 reachable 边界（prompt
#           末尾的 replay 边界），保留税降下来后两者可以同时热着。
#
#     实测（池 209,059）: MAIN after interleave 命中 0,0,0 → 58,752 ×5/5；
#           单轮 28.3s → 1.3–1.7s；池峰值 54.5% → 45.5%（反而更低）；池大小不变。
#
#     ⚠️ 别用这两个仪表判断：启动横幅高估热容量、kv% 低估风险，都不能用来调 MAX_SEQS。
#     ⚠️ 别用 proxy_server_request 的长度推断分类器规模 —— 该列 payload 不完整（实测
#        10.4k 字符却报 28,261 token；把 payload 回放只得 826 token）。
#     回退（排查时）: VLLM_PREFIX_CACHE_RETENTION_INTERVAL= bash setup/07_start.sh
# ============================================================

# ---- 路径参数：Windows 侧用户目录在 WSL 里的挂载点 ----
# 默认取当前 WSL 用户名；若 Windows 用户名与之不同，请显式导出：
#   export WINHOME=/mnt/c/Users/<你的Windows用户名>
WINHOME="${WINHOME:-/mnt/c/Users/${USER:-YOURUSERNAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON=$HOME/monitoring
VLLM_DIR=$HOME/qwen-serving
LM_KEY="sk-lm-REPLACE_ME"
PORT_VLLM=18020
PORT_LITELLM=1234

hr() { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " WSL 侧服务启动   $(date '+%Y-%m-%d %H:%M:%S')"
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
echo "[2/4] vLLM 单用户模式 (${PORT_VLLM})..."
# 健康探测用 /health（不需要鉴权）
vllm_ready() {
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT_VLLM}/health 2>/dev/null)" = "200" ]
}
if vllm_ready; then
  echo "      ✅ 已在运行，跳过启动"
else
  # 用 tmux 而非裸 nohup：nohup 起的进程在 WSL 会话回收后会被一起带走，
  # 与 litellm 保持同一种存活策略，日志可 tmux attach -t vllm 实时看。
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t vllm 2>/dev/null || true
    tmux new-session -d -s vllm \
      "bash ${VLLM_DIR}/setup/07_start.sh 2>&1 | tee -a ${VLLM_DIR}/setup/logs/07_start.log"
    echo "      已在 tmux session 'vllm' 中启动（日志: tmux attach -t vllm）"
  else
    nohup bash "${VLLM_DIR}/setup/07_start.sh" > "${VLLM_DIR}/setup/logs/07_start.log" 2>&1 &
    echo "      (未装 tmux，退回 nohup 启动)"
  fi
  # 冷启动要加载 15 GiB 权重 + torch.compile + CUDA graph 捕获，约 4-6 分钟
  echo "      等待就绪（冷启动约 4-6 分钟，耐心等）..."
  VLLM_OK=0
  for i in $(seq 1 80); do
    if vllm_ready; then VLLM_OK=1; break; fi
    # 进程死了就别白等
    if ! pgrep -f "[v]llm serve" >/dev/null 2>&1 && [ "$i" -gt 3 ]; then
      echo "      ⚠️ vLLM 进程已退出，检查 ${VLLM_DIR}/setup/logs/07_start.log"
      break
    fi
    sleep 6
  done
  if [ "$VLLM_OK" = "1" ]; then
    echo "      ✅ vLLM 就绪 (http://127.0.0.1:${PORT_VLLM})"
  else
    echo "      ⚠️ vLLM 未就绪，后续 litellm 会启动但请求会 500"
    echo "         排查: tail -50 ${VLLM_DIR}/setup/logs/07_start.log"
  fi
fi
# 把生效的关键参数打出来 —— **必须从运行中的服务读，不能读日志文件**。
# 踩过的坑: 日志路径取决于调用方式（`bash 07_start.sh | tee xxx.log` 的 xxx 是调用方决定的），
# 读固定文件名会读到上一次启动的陈旧日志 —— 实测把 fast 档的 65536 当成当前值报了出来。
if vllm_ready; then
  MML=$(curl -s -m 8 -H "Authorization: Bearer ${LM_KEY}" \
        "http://127.0.0.1:${PORT_VLLM}/v1/models" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0].get('max_model_len','?'))" 2>/dev/null)
  curl -s -m 8 "http://127.0.0.1:${PORT_VLLM}/metrics" 2>/dev/null > /tmp/.vllm_cache_info.txt
  python3 - "$MML" <<'PY' 2>/dev/null
import re, sys
mml = sys.argv[1] if len(sys.argv) > 1 else '?'
try:
    txt = open('/tmp/.vllm_cache_info.txt', encoding='utf-8', errors='replace').read()
except OSError:
    txt = ''
m = re.search(r'^vllm:cache_config_info\{([^}]*)\}', txt, re.M)
if m:
    kv = dict(re.findall(r'([A-Za-z_]+)="([^"]*)"', m.group(1)))
    try:
        conc = '%.2fx' % float(kv.get('kv_cache_max_concurrency', '0'))
    except ValueError:
        conc = kv.get('kv_cache_max_concurrency', '?')
    pool = kv.get('kv_cache_size_tokens', '?')
    try:
        pool = '{:,}'.format(int(pool))
    except ValueError:
        pass
    print('      生效: 上下文={}  KV池={} token  满长并发={}  KV={}  block={}  前缀缓存={}'.format(
        mml, pool, conc, kv.get('cache_dtype', '?'), kv.get('block_size', '?'),
        kv.get('enable_prefix_caching', '?')))
PY
  rm -f /tmp/.vllm_cache_info.txt
fi

# ---- 前缀缓存修复自检（2026-09-14）----
# 必须从**运行进程的 environ** 读，不能读脚本、也不能读 /metrics。
# 踩的坑：EngineCore 是 spawn 出来的独立解释器，/proc/<pid>/environ 常常读不到内容，
#          所以只查 APIServer 进程；另外把 patch 改成代码默认开启后 env 会缺失，
#          那种情况下这句会报 "未注入"，但补丁其实还在生效 —— 见 docs/gotchas.md。
# 这条自检的唯一目的：防止哪天脚本被覆盖/重建，retention 静默退回 dense 而没人发现。
if pgrep -f "[v]llm serve" >/dev/null 2>&1; then
  VP=$(pgrep -f "[v]llm serve" | head -1)
  RET=$(tr "\0" "\n" < /proc/${VP}/environ 2>/dev/null | grep -m1 "^VLLM_PREFIX_CACHE_RETENTION_INTERVAL=" || true)
  KCP=$(tr "\0" "\n" < /proc/${VP}/environ 2>/dev/null | grep -m1 "^VLLM_MAMBA_ALIGN_KEEP_CHECKPOINTS=" || true)
  if [ "$RET" = "VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0" ]; then
    echo "      ✅ 前缀缓存保留策略: sparse(=0)  —— 交错流量不再逐出主会话缓存"
  else
    echo "      ⚠️ VLLM_PREFIX_CACHE_RETENTION_INTERVAL 未注入（实测值: '${RET:-<空>}'）"
    echo "         -> dense 模式，auto mode 分类器会让主会话每轮丢缓存、多花约 99 秒"
    echo "         -> 检查 ${VLLM_DIR}/setup/07_start.sh:148 是否还在"
  fi
  [ -n "$KCP" ] && echo "      ℹ️  ${KCP}（历史遗留，已实测对该问题无效，待消融后可移除）"
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
    # 必须在 $WINHOME 下启动：start_litellm.sh 用 SCRIPT_DIR
    # 找同目录的 litellm_config.yaml，换目录会找不到配置
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
    # 顺带确认后端指向的是 vLLM 而不是旧的 vision_guard
    BASE=$(grep -m1 -oE "api_base: *http://[^ ]*" $WINHOME/litellm_config.yaml 2>/dev/null | awk '{print $2}')
    [ -n "$BASE" ] && echo "      后端 api_base = ${BASE}"
  else
    echo "      ⚠️ litellm 未就绪，查看 $HOME/.litellm/litellm.log"
  fi
fi

# ------------------------------------------------------------
echo "[4/4] 监控组件 (Prometheus:9090 / Grafana:3000 / GPU:9400 / 瀑布流:9410)..."
# 该脚本内部已 nohup 各组件，同步执行约 20 秒返回。
# 注意：它也会尝试拉起 9401（Windows 侧主机指标），但**从 WSL 调 powershell 启的
#      进程会被会话回收带走**，所以真正的 9401 由 Windows 侧的 start_all.ps1 负责。
if [ -f "${SCRIPT_DIR}/start_monitoring.sh" ]; then
  bash "${SCRIPT_DIR}/start_monitoring.sh" > "${MON}/start.log" 2>&1 || true
elif [ -f "${MON}/../start_monitoring.sh" ]; then
  bash "${MON}/../start_monitoring.sh" > "${MON}/start.log" 2>&1 || true
else
  echo "      ⚠️ 找不到 start_monitoring.sh，跳过"
fi
for P in 9090 3000 9400 9410; do
  OK=0
  for i in $(seq 1 8); do
    ss -tln 2>/dev/null | grep -q ":$P " && { OK=1; break; }
    sleep 2
  done
  [ "$OK" = "1" ] && echo "      ✅ :$P 监听" || echo "      ⚠️ :$P 未监听（见 ${MON}/start.log）"
done

# ------------------------------------------------------------
echo
hr
echo " WSL 侧汇总"
hr
printf "  %-8s %-24s %s\n" "端口" "服务" "状态"
for pair in "5432:PostgreSQL" "18020:vLLM 模型后端" "1234:litellm 统一入口" \
            "9090:Prometheus" "3000:Grafana" "9400:GPU exporter" "9410:LLM 瀑布流"; do
  P=${pair%%:*}; N=${pair#*:}
  if ss -tln 2>/dev/null | grep -q ":$P "; then
    printf "  %-8s %-24s ✅\n" "$P" "$N"
  else
    printf "  %-8s %-24s ❌\n" "$P" "$N"
  fi
done
echo
echo "  常驻 tmux 会话: $(tmux ls 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
echo "  日志: tmux attach -t vllm | tmux attach -t litellm"
hr
