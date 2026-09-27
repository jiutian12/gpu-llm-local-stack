#!/bin/bash
# ============================================================
#  start_wsl_services_vllmbonsai.sh —— WSL 侧一键拉起【vLLM + Bonsai 2 27B PTQ1_0】
#
#  由 Windows 侧 start_all.ps1 -Backend vllm-bonsai 调用。
#  与 start_wsl_services_bonsai.sh 的区别：模型后端从
#  PrismML llama.cpp fork 换成 **vLLM + prism_ternary 插件**，
#  权重仍是同一份 Bonsai 2 27B ternary 2-bit（PTQ1_0）打包。
#
#  服务链（按依赖顺序）:
#      [1] PostgreSQL             5432
#      [2] vLLM 模型后端           18020  ← Bonsai 2 27B PTQ1_0 (prism_ternary)
#      [3] litellm 统一入口        1234   ← api_base 不用改（同端口同别名）
#      [4] 监控                   9090 / 3000 / 9400 / 9410
#
#  ⚠️ 前置条件：Windows 侧显存守护必须已停（二者抢同一张 24G 卡）。
#  ⚠️ vLLM 与 llama.cpp 不能共存：本脚本会先停掉 llama-server。
#
#  幂等: 已在运行的服务会跳过，可反复执行
#  注意: 刻意不写 set -e —— 单个组件失败不应中断后续启动
# ============================================================
#
#  ============ 实测基线（2026-09-25，RTX 4090 24GB，单卡独占）============
#
#  checkpoint : /home/administrat0r/bonsai_vllm_vl （**带视觉**版本）
#               由 vis_convert.py 生成：文本权重沿用 bonsai_vllm（model.* -> 
#               model.language_model.*，prism_ternary 的 .scales 一并保留），
#               视觉塔+投影器从 Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf 解出（Q8_0 -> bf16）
#               落成 model.visual.*；4 shard / 1585 张量（1250 LLM + 333 视觉 + lm_head）
#               config: Qwen3_5ForConditionalGeneration + 嵌套 vision_config
#               ⚠️ 全 333 个视觉张量已对拍原版 W4A16 HF 权重（Qwen3.8-27B-W4A16-AutoRound）
#                  cosine = 1.0000；mmproj 的权重矩阵**是 reshape 不是转置**（见 vis_convert.py）
#  旧纯文本 checkpoint 仍保留在 /home/administrat0r/bonsai_vllm（回滚用）
#  回滚: VLLM_BONSAI_CKPT=/home/administrat0r/bonsai_vllm bash 本脚本
#  视觉自检: 真实照片应能答出物体；判"图是否真进模型"看 prompt_tokens 增量
#            （+66 = 64 图像 token + vision 起止符）——合成纯色/棋盘图 ViT 会看错，别当判据
#  插件       : prism_ternary（fraserprice/bonsai-vllm），装在 qwen-serving/venv
#
#  单流 decode（流式，TTFT 与 decode 分开）:
#       ~0    ctx : TTFT 0.36s   decode 86.8 t/s
#       ~2.5k ctx : TTFT 1.87s   decode 83.7 t/s
#       ~11k  ctx : TTFT 6.18s   decode 77.7 t/s
#       ~35k  ctx : TTFT 20.99s  decode 63.8 t/s
#      prefill ≈ 1500~1600 t/s（与 llama.cpp M4 同档）
#  并发: 4 路并行聚合 269.6 t/s（llama.cpp M4 3 路只有 100.7）
#
#  ⚠️ 三个必须注意的坑
#   1) **必须开 CUDA graph**（不要 --enforce-eager）。eager 下只有 ~9 t/s，
#      去掉后 7 倍到 ~70 t/s —— 小 batch 解码被 kernel 启动开销拖死。
#   2) **混合 GDN 模型开图捕获要求 max_num_seqs <= 可用 Mamba 块数**。
#      本配置下可用 170 块，所以 --max-num-seqs 必须 <=170（设 128）。
#      否则报 "max_num_seqs (256) exceeds available Mamba cache blocks (170)"。
#   3) **venv 自带 flashinfer 版本不匹配**（cubin 0.6.13 vs 0.6.16）会使启动直接
#      RuntimeError。用 VLLM_USE_FLASHINFER_SAMPLER=0 绕开，不需要改包。
#   4) torch 编译扩展需要 ninja，**venv 的 bin 必须在 PATH 上**，否则报
#      "Ninja is required to load C++ extensions"。同样 CUDA_HOME 要指向 /usr/local/cuda。
#
#  上下文与显存：vLLM 的 KV 是「全局池」而不是 llama.cpp 的「每槽独立」。本配置
#  max_model_len=65536 / max_num_seqs=128 时 KV 池 9.48 GiB。想吃更长上下文就
#  降 max_num_seqs 换单位长度的 KV（两者零和）。llama.cpp M4 的卖点是
#  3 路各 262144 的「在飞容量」，vLLM 的卖点是连续批处理 + Paged KV + 前缀缓存。
#
#  日志: tmux attach -t vllmbonsai   /   ~/vllmbonsai.log
#  停止: pkill -f '[v]llm serve'  （或 bash stop_all.bat 的 WSL 部分）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON=/home/administrat0r/monitoring
VENV=/home/administrat0r/qwen-serving/venv
CKPT="${VLLM_BONSAI_CKPT:-/home/administrat0r/bonsai_vllm_vl}"
LM_KEY="sk-lm-REPLACE_ME"
PORT_MODEL=18020
PORT_LITELLM=1234

# ---- 可调参数（环境变量覆盖）----
MAX_LEN="${VLLM_MAX_LEN:-262144}"
MAX_SEQS="${VLLM_MAX_SEQS:-128}"
# ⚠️ 本机启动时可用显存只有 22.45 / 23.99 GiB（桌面/驱动常驻约 1.54 GiB），
#    故 gpu_util 上限 ≈ 0.936 —— 0.94/0.95 会直接报 free memory 不足而拒绝启动。
GPU_UTIL="${VLLM_GPU_UTIL:-0.93}"
# 显式指定 KV 池字节数（vLLM --kv-cache-memory）。**留空 = 关闭该 flag**，回到自动 profiling。
#   ⚠️ 实测反直觉：显式值不一定更大。vLLM 日志建议的 7795443712（7.26 GiB）是保守估算，
#      自动档在 0.93 下实际分了 8.49 GiB（501,492 tok）；钉 7.26 GiB 只有 430,258 tok。
#   各档实测（0.93 / turboquant_4bit_nc / max_len 262144 / 单流 120 tok 解码）:
#      自动                  : 501,492 tok (1.91x)  空闲  469 MiB  (未测速)
#      7795443712 (7.26 GiB) : 430,258 tok (1.64x)  空闲 1022 MiB  77.7 t/s
#      8000000000 (7.45 GiB) : 441,655 tok (1.68x)  空闲  830 MiB  78.0 t/s  <- 当前定版
#      8500000000 (7.92 GiB) : 470,149 tok (1.79x)  空闲  440 MiB  52.0 t/s  ⚠️悬崖
#   ⚠️⚠️ **显存悬崖**：空闲 >=830 MiB 时满速 ~78 t/s；掉到 ~440 MiB 时解码塌到 52 t/s
#      （疑似 WDDM 部分超配，把部分页挪到主机内存走 PCIe）。本模式又没有
#      gpu_overcommit_guard 兜底，所以别贪那 30k token —— 8e9 是实测的性价比最优点。
#   注意：它与既有环境变量 VLLM_KV_DTYPE 是两回事（那是 KV 精度，这是 KV 容量）。
KV_MEM="${VLLM_KV_MEM-8000000000}"
ALIAS="${VLLM_ALIAS:-qwen3.8-27b}"     # 与 llama.cpp 的 --alias 同名 -> litellm 零改动
# KV 缓存精度（**定版 = kv4 / turboquant_4bit_nc**）。各档在 24G 卡上的实测:
#   bf16/auto      : 一路 256k 要 ~17.2 GiB -> 根本起不来
#   fp8            : 一路 256k 要  8.35 GiB -> 1 路 256k，深层解码 ~74 t/s（最快）
#   turboquant_4bit_nc（当前定版）: 4.42 GiB -> **2 路 256k**（512,890 tok / 1.96x），
#                       代价是深层解码掉到 ~28 t/s —— 它强制退回 FlashAttention 2，
#                       并且每步注意力都要把 KV 反量化（33k 上下文实测 27.7 vs fp8 的 74.1）
#   kvarn_k4v4_g128  : per-token 最省，但 KVARN 后端自己多吃 ~4.5 GiB -> 256k 反而起不来
KV_DTYPE="${VLLM_KV_DTYPE:-turboquant_4bit_nc}"
# 工具调用：不开的话，带 tools 的请求会被 vLLM 直接 400（BFCL 全灭）。
# 本 checkpoint 的 chat_template 出的是 Qwen XML 格式（<tool_call><function=NAME>...），
# 对应 vLLM 的 qwen3_xml 解析器（= Qwen3EngineToolParser）。
TOOL_PARSER="${VLLM_TOOL_PARSER:-qwen3_xml}"
# ⚠️⚠️ 长 prompt 的「并发 prefill」由下面两个参数决定，**不是**由 KV 池决定。
#   本模型是混合 GDN（mamba cache mode = "align"），attention block = 1568 token
#   （为与 mamba page 对齐，见启动日志）。而 `vllm serve` 在 24G 卡上
#   max_num_batched_tokens 默认只有 **2048**（arg_utils.py 里 OPENAI_API_SERVER 的 else 分支）。
#   调度器每步是「贪心」的：第一个请求拿走 min(剩余, 整个预算)，而
#   _mamba_block_aligned_split 又把 chunk 向下对齐到 1568 的整数倍，于是剩余零头
#   （<1568）会让第二个长请求的 chunk 被 floor 成 0、整步落选 →
#   **多个长 prompt 的 prefill 会退化成串行**（实测 2×130k：TTFT 81s / 162s，非并行；
#     短 prompt（<=2048）不受影响，仍可几十路并发）。
#   要让两个长 prompt 在同一个 step 各拿一个 chunk，需同时满足：
#     (a) --long-prefill-token-threshold 1568  ：把每个请求的 chunk 上限压到一个 block
#     (b) --max-num-batched-tokens >= 2*1568=3136：留得出第二个 block 的预算
#   (b) 会多吃激活显存、KV 池变小（8192 时 256k 直接起不来），所以要配套降 max_model_len。
#   默认保持 vLLM 原生值（2048 / 0），以保住「1 路 256k」这个定版能力；要「双并发」用：
#     VLLM_MAX_LEN=256000 VLLM_BATCH_TOKENS=3136 VLLM_LONG_PREFILL=1568 bash 本脚本
BATCH_TOKENS="${VLLM_BATCH_TOKENS:-2048}"
LONG_PREFILL="${VLLM_LONG_PREFILL:-0}"      # 0 = 不传该 flag（保持 vLLM 默认关闭）
LOG=/home/administrat0r/vllmbonsai.log

hr() { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " WSL 侧服务启动【vLLM + Bonsai 2 27B PTQ1_0】  $(date '+%Y-%m-%d %H:%M:%S')"
echo " 模型=$CKPT  max_len=$MAX_LEN  max_seqs=$MAX_SEQS  batch_tokens=$BATCH_TOKENS  gpu_util=$GPU_UTIL  kv_cache_mem=${KV_MEM:-auto}"
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
echo "[2/4] vLLM / Bonsai 2 27B PTQ1_0 (${PORT_MODEL})..."
model_ready() {
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT_MODEL}/health 2>/dev/null)" = "200" ]
}

# 不能只看端口活着：要确认跑的是 vLLM（不是 llama-server）且参数一致
need_restart=0
if model_ready; then
  CUR_ARGS=$(ps -eo args | grep '[v]llm serve' | head -1)
  if [ -z "$CUR_ARGS" ]; then
    echo "      ⚠️ 端口在但不是 vLLM（可能是 llama-server），需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "$CKPT"; then
    echo "      ⚠️ 当前 vLLM 的模型不是 $CKPT，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--max-num-seqs $MAX_SEQS"; then
    echo "      ⚠️ 当前 max-num-seqs 不是 $MAX_SEQS，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--max-model-len $MAX_LEN"; then
    echo "      ⚠️ 当前 max-model-len 不是 $MAX_LEN，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--kv-cache-dtype $KV_DTYPE"; then
    echo "      ⚠️ 当前 kv-cache-dtype 不是 $KV_DTYPE，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--max-num-batched-tokens $BATCH_TOKENS"; then
    echo "      ⚠️ 当前 max-num-batched-tokens 不是 $BATCH_TOKENS，需要重启"; need_restart=1
  elif [ "${LONG_PREFILL:-0}" -gt 0 ] 2>/dev/null && \
       ! echo "$CUR_ARGS" | grep -q -- "--long-prefill-token-threshold $LONG_PREFILL"; then
    echo "      ⚠️ 当前 long-prefill-token-threshold 不是 $LONG_PREFILL，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--gpu-memory-utilization $GPU_UTIL"; then
    echo "      ⚠️ 当前 gpu-memory-utilization 不是 $GPU_UTIL，需要重启"; need_restart=1
  elif [ -n "${KV_MEM:-}" ] && ! echo "$CUR_ARGS" | grep -q -- "--kv-cache-memory $KV_MEM"; then
    echo "      ⚠️ 当前 kv-cache-memory 不是 $KV_MEM，需要重启"; need_restart=1
  elif ! echo "$CUR_ARGS" | grep -q -- "--tool-call-parser $TOOL_PARSER"; then
    echo "      ⚠️ 当前未启用工具调用解析（--tool-call-parser $TOOL_PARSER），需要重启"; need_restart=1
  else
    echo "      ✅ 已在运行且配置匹配，跳过启动"
  fi
fi

if [ "$need_restart" = "1" ]; then
  # 关键：15020 上"有东西在答 /health"不等于"答的是 vLLM"。llama-server 也会答 200，
  # 若只清 vllm serve，model_ready 会一直为真，下面的启动块被整段跳过 —— 后端永远切不过来。
  # 所以这里必须把占着 18020 的**两个**后端都停掉。
  echo "      停掉当前占用 18020 的后端（vLLM 与 llama-server 都清）..."
  tmux kill-session -t vllmbonsai 2>/dev/null || true
  tmux kill-session -t bonsai 2>/dev/null || true
  pkill -f '[v]llm serve' 2>/dev/null || true
  pkill -f '[l]lama-server' 2>/dev/null || true
  sleep 6
  pkill -9 -f '[v]llm serve' 2>/dev/null || true
  pkill -9 -f '[l]lama-server' 2>/dev/null || true
  # 必须等到 tmux 会话真的消失，否则下面的 new-session 只会打印
  # "duplicate session: vllmbonsai" 然后静默不启动 —— 看起来"已启动"，其实跑的还是旧进程。
  for i in 1 2 3 4 5 6 7 8 9 10; do
    tmux has-session -t vllmbonsai 2>/dev/null || break
    tmux kill-session -t vllmbonsai 2>/dev/null || true
    sleep 1
  done
  sleep 3
fi

if ! model_ready; then
  # vLLM 与 llama.cpp 抢同一张卡：先清掉 llama-server
  if pgrep -f '[l]lama-server' >/dev/null 2>&1; then
    echo "      检测到 llama-server 在跑，先停掉（两者不能共存）..."
    tmux kill-session -t bonsai 2>/dev/null || true
    pkill -f '[l]lama-server' 2>/dev/null || true
    sleep 5
    pkill -9 -f '[l]lama-server' 2>/dev/null || true
    sleep 3
  fi

  if [ ! -d "$CKPT" ]; then
    echo "      ❌ 找不到 checkpoint: $CKPT"
  elif [ ! -x "$VENV/bin/vllm" ]; then
    echo "      ❌ 找不到 vLLM: $VENV/bin/vllm"
  else
    # tmux 不继承调用者环境变量，env 必须写进命令串
    PREFLAG=""
    if [ "${LONG_PREFILL:-0}" -gt 0 ] 2>/dev/null; then
      PREFLAG="--long-prefill-token-threshold $LONG_PREFILL"
    fi
    KVFLAG=""
    if [ -n "${KV_MEM:-}" ]; then
      KVFLAG="--kv-cache-memory $KV_MEM"
    fi
    TMUX_CMD="CUDA_HOME=/usr/local/cuda PATH=$VENV/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin VLLM_USE_FLASHINFER_SAMPLER=0 FLASHINFER_DISABLE_VERSION_CHECK=1 $VENV/bin/vllm serve $CKPT --served-model-name $ALIAS --host 127.0.0.1 --port $PORT_MODEL --max-model-len $MAX_LEN --max-num-seqs $MAX_SEQS --max-num-batched-tokens $BATCH_TOKENS $PREFLAG --gpu-memory-utilization $GPU_UTIL $KVFLAG --dtype bfloat16 --kv-cache-dtype $KV_DTYPE --trust-remote-code --enable-auto-tool-choice --tool-call-parser $TOOL_PARSER"
    tmux new-session -d -s vllmbonsai "$TMUX_CMD 2>&1 | tee $LOG" 2>/tmp/.tmux_vllmbonsai_err || true
    if tmux has-session -t vllmbonsai 2>/dev/null; then
      echo "      已在 tmux session 'vllmbonsai' 中启动（日志: tmux attach -t vllmbonsai）"
    else
      echo "      ❌ tmux 会话创建失败: $(cat /tmp/.tmux_vllmbonsai_err 2>/dev/null)"
      echo "         —— 后端没有起来，不要被下面的“就绪”误导"
      tail -5 "$LOG" 2>/dev/null
    fi
    rm -f /tmp/.tmux_vllmbonsai_err

    echo "      等待就绪（载入 9.4GB + torch.compile + CUDA graph 捕获，约 2-4 分钟）..."
    OK=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80; do
      if model_ready; then OK=1; break; fi
      if ! pgrep -f '[v]llm serve' >/dev/null 2>&1 && [ "$i" -gt 3 ]; then
        echo "      ⚠️ vLLM 进程已退出，检查 $LOG"
        tail -25 "$LOG" 2>/dev/null
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
fi

if model_ready; then
  echo "      显存: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader)"
  echo "      生效: max_model_len=$MAX_LEN  max_num_seqs=$MAX_SEQS  alias=$ALIAS"
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
      "cd /mnt/c/Users/administrat0r && bash start_litellm.sh 2>&1 | tee /home/administrat0r/.litellm/litellm.log"
    echo "      已在 tmux session 'litellm' 中启动"
  else
    (cd /mnt/c/Users/administrat0r && nohup bash start_litellm.sh > /home/administrat0r/.litellm/litellm.log 2>&1 &)
    echo "      (未装 tmux，退回 nohup 启动)"
  fi
  LT_OK=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
           -H "Authorization: Bearer ${LM_KEY}" http://127.0.0.1:${PORT_LITELLM}/v1/models 2>/dev/null) || CODE=000
    if [ "$CODE" = "200" ]; then LT_OK=1; break; fi
    sleep 3
  done
  if [ "$LT_OK" = "1" ]; then
    echo "      ✅ litellm 就绪 (http://127.0.0.1:${PORT_LITELLM})"
    BASE=$(grep -m1 -oE "api_base: *http://[^ ]*" /mnt/c/Users/administrat0r/litellm_config.yaml 2>/dev/null | awk '{print $2}')
    [ -n "$BASE" ] && echo "      后端 api_base = ${BASE}"
  else
    echo "      ⚠️ litellm 未就绪，查看 /home/administrat0r/.litellm/litellm.log"
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
  for i in 1 2 3 4 5 6 7 8; do
    ss -tln 2>/dev/null | grep -q ":$P " && { POK=1; break; }
    sleep 2
  done
  [ "$POK" = "1" ] && echo "      ✅ :$P 监听" || echo "      ⚠️ :$P 未监听（见 ${MON}/start.log）"
done

# ------------------------------------------------------------
echo
hr
echo " WSL 侧汇总 (后端: vLLM + Bonsai 2 27B PTQ1_0)"
hr
printf "  %-8s %-26s %s\n" "端口" "服务" "状态"
for pair in "5432:PostgreSQL" "18020:vLLM Bonsai 2 27B" "1234:litellm 统一入口" \
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
echo "  日志: tmux attach -t vllmbonsai | tmux attach -t litellm"
hr
