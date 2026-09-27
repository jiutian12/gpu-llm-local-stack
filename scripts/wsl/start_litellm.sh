#!/bin/bash
# 启动 LiteLLM Proxy + UI (监控本地 llama-server 的 token 使用量)
# 可在任意目录执行:  bash start_litellm.sh
# UI 地址: http://localhost:1234/ui   (登录密码 = master_key)
# 用法:    启动= bash start_litellm.sh   停止= bash stop_litellm.sh
set -e

# 定位 litellm 可执行文件（兼容不同 home / 安装位置）
if [ -x "$HOME/litellm-env/bin/litellm" ]; then
  LITELLM_BIN="$HOME/litellm-env/bin/litellm"
else
  LITELLM_BIN="$(command -v litellm || true)"
fi
if [ -z "$LITELLM_BIN" ] || [ ! -x "$LITELLM_BIN" ]; then
  echo "[ERROR] 找不到 litellm。请先在 WSL 中安装:"
  echo "  python3 -m venv ~/litellm-env && ~/litellm-env/bin/pip install -U 'litellm[proxy]'"
  exit 1
fi

PORT=1234
# 单 worker 本地场景：隐藏"无 Redis"提示（如需限流/预算/多实例再装 Redis）
export LITELLM_DISABLE_NO_REDIS_WARNING=true
# Claude 端点(/v1/messages)走 chat/completions 而非 Responses API
# （llama.cpp 的 Responses 端点对 Qwen3 模板 system 位置处理有 bug）
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true
# 若端口已被占用，先停掉旧的 litellm
# 注意：这里必须锚定 venv 里的真实可执行文件路径。若只写 "[l]itellm --config"，
# 会误杀任何命令行恰好含该字面量的其他 shell —— 2026-09-18 踩过：调用方的
# bash -lc 字符串里带了这个字面量（例如结尾写了个 pgrep），结果重启命令把自己
# kill 掉，旧进程已停、新进程没起，服务直接消失。
if pgrep -f "[l]itellm-env/bin/litellm --config" >/dev/null; then
  echo "[INFO] 检测到已运行的 litellm，正在停止..."
  pkill -f "[l]itellm-env/bin/litellm --config"
fi

# 等端口真正释放（最多 10s），否则强制结束残留进程，避免新进程 bind 失败
for _ in $(seq 1 10); do
  ss -ltn 2>/dev/null | grep -q ":${PORT} " || break
  sleep 1
done
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "[WARN] 端口 ${PORT} 仍被占用，强制结束残留 litellm"
  pkill -9 -f "[l]itellm-env/bin/litellm --config" || true
  sleep 2
fi

# 配置文件与脚本同目录（/mnt/c/Users/administrat0r/）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 自定义回调 litellm_automode_fix.py 就在本目录，保证 litellm 能 import 到
export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

echo "[INFO] 启动 litellm -> http://localhost:${PORT}/ui  (master_key 登录)"
echo "[INFO] 监控指标 -> http://localhost:${PORT}/metrics"
exec "$LITELLM_BIN" \
  --config "${SCRIPT_DIR}/litellm_config.yaml" \
  --port "${PORT}" \
  --host 0.0.0.0
