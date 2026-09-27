#!/bin/bash
# 停止 LiteLLM Proxy
set -e
if pgrep -f "[l]itellm --config" >/dev/null; then
  echo "[INFO] 停止 litellm..."
  pkill -f "[l]itellm --config"
  sleep 2
  echo "[INFO] 已停止"
else
  echo "[INFO] litellm 未在运行"
fi
