# 01 · 架构与数据流

## 1. 为什么是"Windows 侧拉起 → WSL 内部服务"

这套栈横跨两个操作系统，但**入口只有一个**。原因很实际：

- **GPU 和真实传感器在 Windows 侧**：`nvidia-smi` 两个系统都能跑，
  但 CPU 温度/风扇/CPU 功耗只有 Windows 上的 LibreHardwareMonitor 拿得到
  （主板 ACPI 热区在华硕 Z590-E 上恒为 27.85 ℃，是固定占位值，不可用）。
- **WSL 侧跑服务更省事**：PostgreSQL / litellm / Prometheus / Grafana 在 Linux 下装上就跑，
  不用折腾 Windows 服务。
- 但 **9401 必须由 Windows 侧启动**：WSL 常驻进程去调 Windows 可执行文件
  会 `UtilAcceptVsock` 超时挂死（实测 3 分钟只成功 1 次）。
  所以顺序被固定成"Windows 先起自己的两个组件，再回头调 WSL"。

WSL 用的是**镜像网络**，Windows 进程 bind `0.0.0.0:9401` 后，
WSL 里的 `127.0.0.1:9401` 直接可达 —— 所以 Prometheus 抓 `127.0.0.1:9401` 是通的，
不需要 portproxy。`start_monitoring.sh` 只做一次 `curl` 探测来确认。

```
Windows                                  WSL (Ubuntu, mirrored network)
────────                                 ───────────────────────────────
LHM 0.0.0.0:8085  ◄────┐
  │ (data.json)        │
host_exporter 0.0.0.0:9401 ──────────►  Prometheus :9090 抓 127.0.0.1:9401
  │ (psutil + LHM)                       ▲    ▲    ▲
  └─ 显存去向/CPU/RAM/磁盘                 │    │    └── gpu_exporter :9400
                                          │    └─────── litellm :1234 /metrics
                                          │
                                    vLLM :18020 /metrics（仅 vLLM 类后端）
                                          │
                     Grafana :3000  ──────┘  数据源: Prometheus + PostgreSQL
                       │
PostgreSQL :5432 ◄─────┴──── llm_trace_api :9410（瀑布流网页，直读 PG）
   ▲
   └── litellm 写 LiteLLM_SpendLogs
```

## 2. 依赖顺序（不能随便换）

| 步 | 组件 | 为什么必须在这个位置 |
|---|---|---|
| 1 | PostgreSQL 5432 | litellm 启动时若连不上 DB 会退化（用量不落库），先起来最省事 |
| 2 | 模型后端 18020 | litellm 的 `/health` 会去探后端；后端没起就大量 500 |
| 3 | litellm 1234 | 它是 Prometheus 的抓取目标之一，也是瀑布流数据的生产者 |
| 4 | 监控四件套 | Prometheus/Grafana/9400/9410 只依赖前三个"已存在"，放最后 |
| — | Windows 侧 8085/9401 | 必须在 WSL 之前 —— WSL 脚本自己起不动 9401 |

各脚本都刻意**不写 `set -e`**：单个组件失败不应该中断后面的启动，
最后统一打一张"哪些端口在监听"的汇总表。

## 3. litellm 的位置：不是多余的中间层

有了 vLLM/llama.cpp 自带 OpenAI API，为什么还要 litellm？四个具体理由：

1. **Anthropic 格式兼容**：Claude Code 说的是 `/v1/messages`，
   由 litellm 翻译成 `/v1/chat/completions`
   （`LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true`；
   llama.cpp 自己的 Responses 端点对 Qwen3 模板的 system 位置处理有 bug）。
2. **用量落库**：每个请求的 token 数、延迟、prompt/response 原文写进 PG，
   这是瀑布流与"费用按官方价折算"面板的唯一数据源。
3. **能力元数据**：`max_input_tokens` / `max_tokens` / `supports_vision` /
   `supports_function_calling` 等写在配置里，客户端（Claude Code）据此决定能不能开 auto mode。
4. **多别名一个后端**：`qwen3-27b` / `claude-3-5-sonnet` / `claude-*` /
   `qwen/qwen3.8-27b` / `qwen3.8-27b` 五个别名全指向同一个 `api_base: http://127.0.0.1:18020/v1`。

## 4. "同端口同别名"的换后端设计

三个后端都 listen `18020`，都用 `--alias qwen3.8-27b`。
于是：

- `litellm_config.yaml` 永远不用改；
- WSL 启动脚本通过 `/slots`（llama.cpp）或 `/health` + `ps -eo args`
  判断当前 18020 上跑的**是不是**期望的引擎和配置（NP、权重档位），
  不匹配就直接 `tmux kill-session` + `pkill` 再拉起 —— 换后端 = 重跑一条命令。

`start_all.ps1` 的 `-Backend` 只影响两件事：
走哪个 WSL 脚本、以及起哪个守护（见第 6 节）。

## 5. 监控数据的三条来源（互补，不重叠）

| 来源 | 位置 | 回答什么问题 |
|---|---|---|
| **litellm `/metrics`** | 1234 | 每个请求/每个模型/每个 key 的**业务量**：token 数、费用、延迟、失败、排队 |
| **vLLM `/metrics`** | 18020 | **引擎内部**效率：KV 池占用、前缀缓存命中率、投机解码接受率、TTFT/TPOT 分位（413 条 `vllm:*`） |
| **GPU + 主机指标** | 9400/9401 | **硬件真相**：显存去向（Dedicated vs Shared）、板卡功耗、显存控制器利用率、CPU 温度 |

为什么三者都要：litellm 只知道"请求慢"，vLLM 只知道"KV 满了"，
**只有硬件指标能告诉你"显存被 WDDM 挪到主机内存了"** ——
而这个才是那个"无报错但慢 20 倍"的根因。

## 6. 两个守护：互斥，各管一条链路

| | `gpu_overcommit_guard.ps1` | `bonsai_guard.ps1` |
|---|---|---|
| 服务的是 | vLLM 原链路 | llama.cpp Bonsai / vLLM-Bonsai |
| 触发条件 | 显存超配（committed/物理 ≥ 99.5%）、WSL loopback 失效（端口在监听但 127.0.0.1 不通）、引擎停滞（有请求在跑但 token 零推进） | 服务不可用 **且** 显存确实空着 |
| 动作 | 重启 vLLM（`-EnableRestart`） | 调 WSL 启动脚本重新拉起整个 WSL 侧 |
| 判据 | 连续 3 次命中 = 30 s 异常 | `:18020 /health`=200 **且** `:1234` 通，连续 4 次（≈60 s）不通才动 |
| 关键闸门 | — | **`nvidia-smi memory.used <= 1000 MiB` 才启动** |
| 限流 | — | 冷却 10 min，每小时最多 3 次，启动后 180 s 宽限期内不动作 |

**为什么必须互斥**：`gpu_overcommit_guard -EnableRestart` 会把 vLLM 拉回来，
而 Bonsai 模式下 vLLM 就是那个"抢显存的人"。所以 `start_all.ps1` 在
**`[2.5/5]` 步（拉起模型之前）**就停掉它 —— 不能等到 `[4/5]`，
否则守护会在 30 秒内把 vLLM 拉回来。

**为什么 bonsai_guard 要加显存闸门**：24 GB 装不下两套。
如果服务掉了而显存还被别人占着，硬启会走进 WDDM 超配 ——
表现是**能加载、日志无任何报错**，但 prefill 从 ~1500 t/s 崩到 16 t/s、
板卡功耗 297 W → 96 W（GPU 利用率仍是 99%）。
所以显存不空时它**只记日志、不动作**。

守护的暂停方式：建一个空文件 `monitoring_cfg\bonsai_guard.pause`，
或者直接跑 `stop_all.bat`。

## 7. 三个后端各自的显存账（24 GB 卡）

| 后端 | 占用策略 | 实测空闲余量 | 结论 |
|---|---|---|---|
| llama.cpp Bonsai NP=3 | KV q4_0，每槽 262144 | 23,556 MiB（不带 mmproj）/ 24,094（带） | NP=3 是上限 |
| llama.cpp Bonsai NP=4 | 同上 | 只多 546 MiB | **陷阱**：真填上下文时 prefill → 16 t/s，功耗 → 96 W |
| vLLM-Bonsai | `gpu_util=0.93`，KV 显式 8e9 | 830 MiB @ KV 441,655 tok | 815 MiB 是悬崖边 |
| vLLM 原链路 | `MAX_SEQS=2`，KV 池 4.4 GiB | 782 MiB | 余量最紧 |

**本机常数**：启动时可用显存只有 **22.45 / 23.99 GiB**（约 1.54 GiB 被桌面/驱动常驻占用），
所以 `gpu_memory_utilization` **上限 ≈ 0.936**，写 0.94/0.95 会被 vLLM 直接拒绝启动。

> 判定"是不是显存超配"最快的单一指标是**板卡功耗**：
> 健康基线 prefill 期 ~400 W、解码期 230–300 W、空闲 6–8 W。
> 出现"利用率 99% 但功耗 <100 W"就基本可以定性了。

## 8. 对外暴露（可选）

局域网其他设备要访问时，用 `open_lan_ports.ps1` / `setup_portproxy.bat`
把 `1234`（litellm）等端口转发到 Windows 网卡（即本机的局域网地址，如 `192.168.x.x`）。
GPU 与主机指标的端口**不建议**外放。
