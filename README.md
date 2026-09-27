# 本地 GPU + LLM 全栈：一键启动与可观测性

一套跑在 **Windows + WSL2 + 单张 RTX 4090 24 GB** 上的本地大模型服务栈的
**启动脚本 + 监控大屏 + 现场笔记**。

> **TL;DR** — 双击 `start_all.bat`，一台机器上的 9 个组件按依赖顺序起来：
> PostgreSQL(5432) → 模型后端(18020) → litellm(1234) → Prometheus(9090) → Grafana(3000)
> → GPU exporter(9400) → LLM 瀑布流(9410) → 主机指标(9401) → 硬件传感器(8085)。
> 全部指标汇进 **一张 115 面板的 Grafana 大屏**：GPU/显存/功耗/温度、主机 CPU、
> token 用量与速率、并发与排队(Little's Law)、请求延迟、按 DeepSeek 官方价折算的费用、
> 以及 **WDDM 显存超配**这个"无日志、无报错、但推理静默掉 20 倍"的隐形杀手。
>
> 这个仓库只包含**脚本、配置与文档**，不含模型权重、不含任何 token。

---

## 1. 这个栈长什么样

```
┌──────────────────────── Windows 侧 ────────────────────────┐
│  start_all.bat ──► start_all.ps1                            │
│    [1/5] 检查 WSL 环境（含 /mnt 失挂自愈、wsl.exe 被拦检测） │
│    [2/5] LibreHardwareMonitor 8085  ← 真实 CPU 温度唯一来源  │
│           host_exporter_win.py 9401 ← psutil + LHM 传感器树  │
│    [2.5/5] Bonsai 模式：先停显存守护（否则它 30s 内抢回显存）│
│    [3/5] 调 WSL 侧的 start_wsl_services_*.sh                 │
│    [4/5] 按后端拉起对应守护（两个守护互斥）                  │
│    [5/5] 汇总                                              │
└────────────────────────────┬───────────────────────────────┘
                             │ wsl.exe
┌──────────────────────── WSL 侧 ────────────────────────────┐
│  [1] PostgreSQL          :5432   ← litellm 用量落库          │
│  [2] 模型后端            :18020  ← 三选一，见第 2 节          │
│  [3] litellm             :1234   ← OpenAI + Anthropic 双格式 │
│  [4] Prometheus          :9090   ← 抓 1234 / 18020 / 9400/9401│
│      Grafana             :3000   ← 2 张仪表盘 / 115 面板     │
│      gpu_exporter.py     :9400   ← nvidia-smi → 指标         │
│      llm_trace_api.py    :9410   ← LLM 输入/输出瀑布流网页   │
└────────────────────────────────────────────────────────────┘
```

| 端口 | 组件 | 位置 | 说明 |
|---|---|---|---|
| 8085 | LibreHardwareMonitor | Win | 真实 CPU 温度/风扇/功耗/频率的唯一可靠来源 |
| 9401 | 主机指标 exporter | Win | CPU/内存/提交内存/磁盘/温度/GPU 显存去向 |
| 5432 | PostgreSQL | WSL | `LiteLLM_SpendLogs` 等用量表 |
| 18020 | 模型后端 | WSL | 三个后端共用此端口、共用别名 `qwen3.8-27b` |
| 1234 | litellm | WSL | 统一入口，写用量入库，暴露 `/metrics` |
| 9090 | Prometheus | WSL | 4 个 job：litellm / vllm / gpu / host |
| 3000 | Grafana | WSL | 仪表盘，admin/admin |
| 9400 | gpu_exporter | WSL | 13 个 `gpu_*` 指标 |
| 9410 | llm_trace_api | WSL | 瀑布流网页，直读 PG |

**关键设计**：三个模型后端**同端口同别名**，所以切换后端时 `litellm_config.yaml`
里的 `api_base` 一个字都不用改。WSL 启动脚本还会检测 18020 上跑的是不是想要的引擎，
不是就重启它 —— 因此"换后端"就是一条命令。

## 2. 三个模型后端（共用 18020 / 别名 `qwen3.8-27b`）

| 后端 | 引擎 | 权重 | 上下文 | 显存策略 | 卖点 |
|---|---|---|---|---|---|
| **`bonsai`**（默认） | PrismML llama.cpp fork | Bonsai 2 27B PTQ1_0 | **每槽 262144 × NP=3** | KV q4_0 | **在飞容量 786,432 token**；长上下文解码最快 |
| `vllm-bonsai` | vLLM + `prism_ternary` 插件 | 同上（含视觉塔） | 262144 | KV turboquant_4bit_nc，`gpu_util=0.93` | 连续批处理 + Paged KV + 前缀缓存 + 工具调用 |
| `vllm` | vLLM | Qwen3.8-27B-W4A16 + DFlash2 | 200000 | `MAX_SEQS=2` | 原链路，短请求批处理最强 |

实测（RTX 4090，单卡独占）：

| | llama.cpp Bonsai (M4) | vLLM 原链路 |
|---|---|---|
| 在飞上下文容量 | **786,432 tok**（3 slot 各自 262144） | 209,059 tok（KV 池全局钉死） |
| ~100k 解码 | **51.7 t/s** | 17.0 t/s |
| ~240k 解码 | **32.3 t/s** | 3.8 t/s |
| 236k prefill | **832 t/s**（250.6 s） | 316 t/s（746.6 s） |
| 短上下文聚合吞吐 | 100.7 t/s（3 路） | **146.3 t/s**（2 路） |

三种后端**不能共存于一张 24 GB 卡**（都要抢 18020 和同一份显存）。

```bat
start_all.bat                        :: 默认 = llama.cpp + Bonsai
start_all.bat -Backend vllm-bonsai   :: vLLM + Bonsai（带视觉）
start_all.bat -Backend vllm          :: 回到 W4A16
start_all.bat -Open                  :: 默认 + 开浏览器
```

## 3. 监控大屏

两张仪表盘，JSON 都在 [`dashboards/`](dashboards/)，可以直接导入。

### 3.1 「本地 GPU + LLM 全监控」— 10 个分组 115 个面板，10 s 刷新

| 分组 | 面板数 | 看什么 |
|---|---|---|
| 实时输入输出 · 瀑布流 | 2 | 最近的 prompt / 思维链 / 输出原文（直读 PG） |
| 主机 (Windows) — CPU/温度/内存/磁盘 | 11 | 使用率、真实 CPU 温度、提交内存、各盘用量 |
| GPU 总览 (RTX 4090) | 13 | 利用率、显存、温度、功耗、SM/显存时钟、PCIe 链路 |
| Token 用量与速率 | 11 | 输入/输出/缓存命中速率与累计、缓存占比 |
| 并发与排队（Little's Law 校准） | 12 | L=λ·W 校准并发 vs litellm 原始 gauge、排队 p95 |
| 请求与延迟 | 8 | QPS、失败率、每 token 延迟、TTFT p95 |
| 成本计费（DeepSeek 官方价折算） | 9 | 本区间/累计费用、费用速率、缓存省了多少钱 |
| 硬件传感器 (LibreHardwareMonitor) | 10 | 每核温度、主板温度、风扇、CPU 功耗与频率 |
| vLLM 引擎 · Qwen3.8-27B | 15 | KV 占用、解码速度、TTFT/端到端分位、前缀缓存命中率 |
| DFlash2 投机解码 (k=7) | 7 | 逐位接受率、草稿浪费率、草稿吞吐 vs 接受吞吐 |
| GPU 显存超配 — 主机内存兜底 (WDDM) | 6 | committed vs 物理、Shared 显存、**显存控制器利用率** |

### 3.2 「LiteLLM Prod v2」— 7 个面板，官方模板

Proxy 请求速率、按异常类失败率、延迟均值/中位数、`x-ratelimit` 余量、
按虚拟 Key / Team 的请求速率。

详见 [`docs/03-dashboards.md`](docs/03-dashboards.md)（逐面板 + PromQL）。

## 4. 值得单独说的三个坑

这三条都是**没有任何报错**、只能靠指标看出来的问题：

1. **WDDM 显存超配**：物理显存不够时，WDDM 把一部分显存兜底到主机内存，走 PCIe。
   现象是"能加载、日志干净"，但推理从 ~80 t/s 掉到 **<1 t/s**（严重）
   或 **78 → 52 t/s**（部分超配，更隐蔽）。
   看板指标：`host_gpu_memory_committed_bytes` vs `host_gpu_memory_physical_bytes`、
   `host_gpu_memory_shared_bytes`、`host_gpu_memory_controller_percent`（健康 66–73%，退化时 1–9%）。
2. **llama.cpp 冷启动预热惩罚**：同一个基准连跑两次得 33.2 / 75.9 t/s，
   约 2.3× 差距，疑似按 batch 形状惰性捕获 CUDA graph。**测速必须预热 ≥3 次**。
3. **vLLM 显存悬崖**：KV 池不是"越大越好"。空闲 ≥830 MiB 满速 78 t/s，
   掉到 ~440 MiB 就塌到 52 t/s。**调 `--kv-cache-memory` 必须实测解码速度**。

排障清单（32 条）见 [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md)。

## 5. 目录

```
docs/
  01-architecture.md        服务链、数据流、端口、依赖顺序
  02-one-click-start.md     start_all.bat/ps1 五步 + WSL 脚本逐步说明
  03-dashboards.md          两张仪表盘逐面板说明 + 关键 PromQL
  04-metrics-reference.md   全部导出指标字典（gpu_ / host_ / litellm_ / vllm:）
  05-troubleshooting.md     现场排障清单（WSL / 编码 / 显存 / 代理 / 进程）
scripts/
  windows/  start_all.bat  start_all.ps1  stop_all.bat  stop_all.ps1
  wsl/      start_wsl_services*.sh  start_monitoring.sh  start_litellm.sh  stop_*.sh
  guards/   bonsai_guard.ps1  gpu_overcommit_guard.ps1
exporters/  gpu_exporter.py  host_exporter_win.py  llm_trace_api.py
config/     prometheus.yml  litellm_config.sample.yaml
dashboards/ gpu-llm-full-monitor.json  litellm-prod-v2.json
```

## 6. 用之前必须改的东西

这些脚本是从真实机器上直接拷出来的，**使用前请替换**：

| 位置 | 占位 | 改成 |
|---|---|---|
| `config/prometheus.yml` | `bearer_token: sk-lm-REPLACE_ME` | 你的 litellm master key |
| `config/litellm_config.sample.yaml` | `master_key: sk-lm-REPLACE_ME` | 你的 key；`database_url` 改成你的 PG |
| `scripts/wsl/start_wsl_services*.sh` | `LM_KEY="sk-lm-REPLACE_ME"` | 同上 |
| 所有脚本 | `/mnt/c/Users/administrat0r`、`C:\Users\administrat0r` | 你的用户目录 |
| `scripts/wsl/start_wsl_services*.sh` | `/home/administrat0r/bonsai`、`~/qwen-serving` 等 | 你的 WSL 路径与权重路径 |

另需自备（本仓库不含）：prometheus / grafana 发行包、litellm 的 venv、
模型权重（Bonsai 2 27B GGUF 或 Qwen3.8-27B W4A16）、LibreHardwareMonitor。

## 7. 运行环境

- Windows 10/11 + WSL2（Ubuntu，镜像网络）；本文假定 WSL 能直接访问
  `127.0.0.1` 上的 Windows 端口（`start_monitoring.sh` 依赖这点探测 9401）
- 单张 NVIDIA 卡（实测 RTX 4090 24 GB）；驱动 610.x 时代
- WSL 内：Python 3、prometheus、grafana、litellm（venv）、PostgreSQL 18
- Windows 内：Python 3 + `psutil`、LibreHardwareMonitor（.NET）

## 8. 实测数据出处

本仓库的数值来自同一台机器上的连续压测与能力基准（280 题固定子集：
GSM8K/MMLU/IFEval/BFCL 各 70，seed=42，non-thinking，temperature=0）。
五套部署的总分只差 2.5 个百分点（87.9% ~ 90.4%），**能力不构成选型理由**，
选型由容量与速度决定 —— 这也是把"在飞上下文容量"和"WDDM 超配"做成看板主指标的原因。

## License

MIT —— 见 [LICENSE](LICENSE)。
