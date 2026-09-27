# 04 · 指标字典

四个 exporter 覆盖上百个指标族（单是 vLLM 引擎侧就有 413 个）。
下面按来源列全，并标注单位与坑。

## 1. GPU exporter —— `http://127.0.0.1:9400/metrics`

`gpu_exporter.py`，直接解析 `nvidia-smi --query-gpu=...` 的 CSV，
3 秒缓存。标签：`gpu="0"`, `name="NVIDIA GeForce RTX 4090"`。

| 指标 | 单位 | 来源字段 | 说明 |
|---|---|---|---|
| `gpu_utilization_gpu_percent` | % | `utilization.gpu` | SM 占用率 |
| `gpu_utilization_memory_percent` | % | `utilization.memory` | **显存带宽**利用率（不是容量） |
| `gpu_memory_used_bytes` | B | `memory.used` | 已用显存（MiB × 1024²） |
| `gpu_memory_total_bytes` | B | `memory.total` | 总显存 |
| `gpu_memory_free_bytes` | B | 计算 | total − used |
| `gpu_temperature_celsius` | ℃ | `temperature.gpu` | |
| `gpu_power_watts` | W | `power.draw` | **判超配最快的单一指标** |
| `gpu_fan_speed_percent` | % | `fan.speed` | |
| `gpu_clock_sm_mhz` | MHz | `clocks.sm` | |
| `gpu_clock_mem_mhz` | MHz | `clocks.mem` | |
| `gpu_pcie_link_gen` | — | `pcie.link.gen.current` | 与 width 组合 |
| `gpu_pcie_link_width` | — | `pcie.link.width.current` | 掉档是超配变慢的物理原因 |
| `gpu_driver_version` | — | `driver_version` | 值 1，版本在 label 上 |

> `gpu_memory_used_bytes` 是**驱动视角**的占用；
> 而 `host_gpu_memory_committed_bytes` 是 **WDDM 视角**的提交量。
> 两者不一致正是超配的信号 —— 所以显存要看**两个来源**。

## 2. 主机 exporter —— `http://127.0.0.1:9401/metrics`

`host_exporter_win.py`。psutil 数据 5 s 缓存，温度/传感器 15 s 后台线程刷新。
标签：`host="windows"`；传感器类另有 `hardware=` / `sensor=`。

### 2.1 CPU

| 指标 | 单位 | 说明 |
|---|---|---|
| `host_cpu_usage_percent` | % | 0.3 s 间隔采样 |
| `host_cpu_usage_per_core_percent` | % | 每逻辑核，label `core=` |
| `host_cpu_logical_cores` | — | 逻辑核数 |
| `host_cpu_temperature_celsius` | ℃ | **仅在来源可靠时输出** |
| `host_cpu_temperature_reliable` | 0/1 | 1=可信，0=不可用或固定占位值 |
| `host_cpu_temperature_source_info` | 1 | 常驻，label 描述当前数据源与原因 |

温度来源判定（**这是本 exporter 最有个性的部分**）：

1. 优先 **LibreHardwareMonitor** 的 `http://127.0.0.1:8085/data.json`；
   从中挑 `Core Max` / `Package` / `Tctl` / `Tdie` / `CPU Total`，
   再退到任何含 "CPU" 的传感器。
2. 退路是 WMI 的
   `Win32_PerfRawData_Counters_ThermalZoneInformation`（`HighPrecisionTemperature`，单位 0.1 K）。
   **实测在管理员权限下**，华硕 Z590-E + i7-11700K 上这个源**恒为 27.85 ℃** ——
   是 ACPI 固定占位值。
3. 可靠性判定：连续采样 3 次，值完全相同即判为固定占位值（结果缓存 10 分钟）。
   判定为不可靠时**不输出 `host_cpu_temperature_celsius`**，
   只把 `..._reliable=0` 与 `note` 挂到 `source_info` 的 label 上。

> 为什么要这么麻烦：**一条恒为 27.85 的假曲线比没有曲线更危险**，
> 它会让人以为散热正常。所以宁可缺数据，也不给假数据。

### 2.2 内存与提交内存

| 指标 | 单位 | 说明 |
|---|---|---|
| `host_memory_total_bytes` | B | 物理内存总量 |
| `host_memory_used_bytes` | B | 物理已用 |
| `host_memory_free_bytes` | B | **available**（不是 total−used） |
| `host_memory_usage_percent` | % | |
| `host_commit_total_bytes` | B | 提交/页面文件上限 |
| `host_commit_used_bytes` | B | 提交已用 |
| `host_commit_usage_percent` | % | |

「提交内存」= committed，Windows 的口径，比物理使用率更能反映
"还能不能再塞一个进程"。本机 32 GB 内存 + 常驻几个 IDE，
这条曲线是判断要不要关东西的依据。

### 2.3 磁盘

| 指标 | 单位 |
|---|---|
| `host_disk_total_bytes` / `host_disk_used_bytes` / `host_disk_free_bytes` | B |
| `host_disk_usage_percent` | % |

分盘（label `device=` / `mountpoint=`）。

### 2.4 硬件传感器（来自 LHM）

分组前缀 → 指标名映射写死在 `LHM_GROUPS` 里：

| LHM 分组 | 指标 | 单位 |
|---|---|---|
| `temperatures` | `host_hw_temperature_celsius` | ℃ |
| `fans` | `host_hw_fan_rpm` | RPM |
| `powers` | `host_hw_power_watt` | W |
| `clocks` | `host_hw_clock_megahertz` | MHz |
| `loads` | `host_hw_load_percent` | % |
| `controls` | `host_hw_control_percent` | % |
| （`voltages` 基数太大，默认不采） | | |

标签：`hardware="..."`（如 `Intel Core i7-11700K`）、`sensor="..."`（如 `CPU Package`）。

### 2.5 GPU 显存去向（WDDM）—— 单独处理的一组

这几个节点在 LHM 树里的位置是 `<GPU 名>/Data/...` 与 `<GPU 名>/Load/...`，
**不属于上面任何传感器分组**（那些靠分组名匹配），所以单独列了一张映射表。
漏掉它们就完全看不到 WDDM 把显存挪去了哪里。

| 指标 | 单位 | LHM 节点 | 说明 |
|---|---|---|---|
| `host_gpu_memory_dedicated_bytes` | B | `D3D Dedicated Memory Used` | 真·VRAM |
| `host_gpu_memory_shared_bytes` | B | `D3D Shared Memory Used` | **主机内存里的显存** |
| `host_gpu_memory_physical_bytes` | B | `GPU Memory Total` | 物理上限 |
| `host_gpu_memory_used_bytes` | B | `GPU Memory Used` | |
| `host_gpu_memory_free_bytes` | B | `GPU Memory Free` | |
| `host_gpu_memory_committed_bytes` | B | Dedicated + Shared | **WDDM Total Committed** |
| `host_gpu_memory_controller_percent` | % | `GPU Memory Controller` | **退化指示器：健康 66–73%，退化时 1–9%** |

> 单位坑：LHM 显示的 **"MB" 实际是 MiB**（已与 `Get-Counter` 的
> Total Committed 交叉验证，数值一致），所以换算用 `1024*1024`。

### 2.6 自身

| 指标 | 说明 |
|---|---|
| `host_exporter_scrape_seconds` | 一次采集耗时 |

## 3. litellm —— `http://127.0.0.1:1234/metrics`

需要 `Authorization: Bearer <master_key>`。实测 **73 个指标族**，其中业务相关的 28 个：

### 3.1 Token 与费用

| 指标 | 类型 | 说明 |
|---|---|---|
| `litellm_input_tokens_metric_total` | counter | 输入 token（含缓存命中部分） |
| `litellm_input_cached_tokens_metric_total` | counter | 其中**缓存命中**的输入 token |
| `litellm_output_tokens_metric_total` | counter | 输出 token |
| `litellm_output_reasoning_tokens_metric_total` | counter | 思维链 token |
| `litellm_total_tokens_metric_total` | counter | 输入+输出 |
| `litellm_provider_cache_read_input_tokens_metric_total` | counter | 上游报告读到的缓存 token |
| `litellm_cache_misses_metric_total` | counter | 缓存未命中 |
| `litellm_spend_metric_total` | counter | litellm 按自己价目表算的花费（我们不用它，按官方价另算） |
| `litellm_requests_metric_total` | counter | 请求数 |

> **`litellm_input_cached_tokens_metric_total` 是 `litellm_input_tokens_metric_total`
> 的子集** —— 算"未命中"要用减法，不能相加。

### 3.2 延迟与排队（直方图）

| 指标 | 类型 | 说明 |
|---|---|---|
| `litellm_request_total_latency_metric_{sum,count,bucket}` | histogram | 端到端总延迟。**`rate(sum)` 物理解释就是"在飞请求数"**（Little's Law） |
| `litellm_request_queue_time_seconds_{sum,count,bucket}` | histogram | 排队等待时长 |
| `litellm_llm_api_latency_metric_*` | histogram | 只算模型 API 那一段 |
| `litellm_llm_api_time_to_first_token_metric_*` | histogram | TTFT |
| `litellm_overhead_latency_metric_*` | histogram | litellm 自身开销 |
| `litellm_overhead_with_guardrails_latency_metric_*` | histogram | 含 guardrails 的开销 |
| `litellm_deployment_latency_per_output_token_{sum,count}` | summary | **每输出 token 延迟**（= 1/解码速度） |

> `litellm_request_total_latency_metric_sum` 这个用法很妙：
> `sum(rate(..._sum[5m]))` 的量纲是 `请求数 × 秒 / 秒` = 在飞请求数。
> 于是不用额外埋点就拿到了并发数，且**不受 15 s 采样影响**（相比 gauge）。

### 3.3 请求与失败

| 指标 | 说明 |
|---|---|
| `litellm_deployment_total_requests_total` | 按 model 的请求数 |
| `litellm_deployment_success_responses_total` | 成功 |
| `litellm_deployment_failure_responses_total` | 失败 |
| `litellm_proxy_total_requests_metric_total` | Proxy 层总请求（label 含 `api_key_alias` / `team_alias`） |
| `litellm_proxy_failed_requests_metric_total` | Proxy 层失败（label 含 `exception_class`） |
| `litellm_in_flight_requests` | **gauge**，采样瞬间的在飞请求（对照用，勿当主指标） |
| `litellm_deployment_state` | 部署健康状态 |

### 3.4 配额与用户

`litellm_remaining_requests` / `litellm_remaining_tokens`（官方盘用）、
`litellm_remaining_api_key_requests_for_model` / `..._tokens_for_model` /
`litellm_remaining_api_key_budget_metric` / `litellm_remaining_user_budget_metric`、
`litellm_active_users` / `litellm_total_users` / `litellm_teams_count`、
`litellm_check_batch_cost_jobs_polled` / `..._last_run_timestamp`。

另有 Go/Python 运行时的 `process_*` 6 个（CPU、fd、RSS、启动时间、虚拟内存）。

## 4. 模型后端 —— `http://127.0.0.1:18020/metrics`

**这一节有个很容易踩的前提：暴露哪套指标取决于当前跑的是哪个后端。**

| 后端 | 指标族 | 数量 |
|---|---|---|
| vLLM（`vllm` / `vllm-bonsai`） | `vllm:*` | **413 个**（单用户模式自带） |
| llama.cpp（`bonsai`） | `llamacpp:*` | **15 个** |

### 4.1 `vllm:*`（vLLM 后端，413 个，常用如下）

| 指标 | 说明 |
|---|---|
| `vllm:kv_cache_usage_perc` | KV 池占用比例 |
| `vllm:generation_tokens_total` | 生成的 token 数 |
| `vllm:inter_token_latency_seconds_{sum,count,bucket}` | **步间延迟**。`tokens/sum` = 纯解码速度（不含排队） |
| `vllm:time_to_first_token_seconds_*` | TTFT |
| `vllm:e2e_request_latency_seconds_*` | 端到端 |
| `vllm:prefix_cache_hits_total` / `vllm:prefix_cache_queries_total` | 前缀缓存命中/查询 |
| `vllm:request_success_total`（label `finished_reason`） | 结束原因分布 |
| `vllm:num_requests_running` / `vllm:num_requests_waiting` | 运行中/排队中 |
| `vllm:spec_decode_num_draft_tokens_total` / `..._accepted_tokens_total` / `..._drafts_total` | 投机解码 |
| `vllm:spec_decode_num_accepted_tokens_per_pos_total`（label `position`） | **逐位接受率** |

### 4.2 `llamacpp:*`（llama.cpp 后端，15 个）

当前默认后端（`bonsai`）暴露的**就是这一套**。仪表盘的 `vllm:*` 面板
在这种情况下会是空的 —— 这是已知的、符合预期的现象，不是故障。

| 指标 | 类型 | 说明 |
|---|---|---|
| `llamacpp:prompt_tokens_total` | counter | 处理的 prompt token |
| `llamacpp:prompt_tokens_cached_total` | counter | **前缀缓存命中的 prompt token** |
| `llamacpp:prompt_seconds_total` | counter | prefill 累计秒 |
| `llamacpp:prompt_tokens_seconds` | gauge | **prefill 速度** |
| `llamacpp:tokens_predicted_total` | counter | 生成 token |
| `llamacpp:tokens_predicted_seconds_total` | counter | 解码累计秒 |
| `llamacpp:predicted_tokens_seconds` | gauge | **解码速度** |
| `llamacpp:n_decode_total` | counter | 解码步数 |
| `llamacpp:n_busy_slots_per_decode` | gauge | 每步忙槽位数（≈ batch 大小） |
| `llamacpp:n_tokens_max` | gauge | 单槽最大 token |
| `llamacpp:requests_processing` / `llamacpp:requests_deferred` | gauge | 处理中 / 排队 |
| `llamacpp:spec_decode_num_draft_tokens_total` / `..._accepted_tokens_total` / `..._drafts_total` | counter | 投机解码（若开启） |

> **想让看板的"引擎"分组在 llama.cpp 后端也有数据**，
> 需要把 PromQL 的 `vllm:` 前缀换成 `llamacpp:`，
> 并注意语义差异：`llamacpp:predicted_tokens_seconds` 是 gauge（直接就是 t/s），
> 不像 vLLM 那样要用两个 counter 相除。
> Prometheus 的 `job_name` 已在 `prometheus.yml` 里配成 `vllm`（target 18020），
> 所以两套指标都能被同一个 job 抓到，只是指标名不同。

## 5. PostgreSQL —— 用量与原文

datasource：`LiteLLM-PG` @ `127.0.0.1:5432/litellm`。

| 表 | 用途 |
|---|---|
| `LiteLLM_SpendLogs` | **瀑布流与费用的原文来源**：`model` / `prompt_tokens` / `completion_tokens` / `startTime` / `request_duration_ms` / `proxy_server_request` / `response` |
| `LiteLLM_VerificationToken` | 虚拟 key / 别名（对应 `api_key_alias` 标签） |
| `LiteLLM_TeamTable` / `LiteLLM_UserTable` | team / 用户配额 |

关键字段取法（很容易取错，务必照抄）：

```
输入      = proxy_server_request -> messages[-1] 的最后一段 text
思考过程  = response -> choices[0].message.reasoning_content
输出      = response -> choices[0].message.content     （为空时不回退到思考过程）
时区      = 库里存 UTC，交给 Grafana 换算；SQL 里不要再 +8
```

前提：`litellm_config.yaml` 的 `general_settings` 下开
`store_prompts_in_spend_logs: true`，改完重启 litellm。

## 6. 抓取配置对照（`prometheus.yml`）

| job | target | 频率 | 备注 |
|---|---|---|---|
| `litellm` | `127.0.0.1:1234` | 10 s | `bearer_token` 需填 master key |
| `vllm` | `127.0.0.1:18020` | 10 s | 标签 `model="qwen3.8-27b"` |
| `gpu` | `127.0.0.1:9400` | 10 s | |
| `host` | `127.0.0.1:9401` | **15 s** | 单独调慢，因为采集里有 powershell 子进程 |

> Prometheus 必须显式 `export no_proxy="127.0.0.1,localhost,0.0.0.0"`，
> 否则 Go http client 会跟随环境变量代理，把本机抓取拦成
> `context deadline exceeded`（看着像端口不通）。
> 这是 `start_monitoring.sh` 里最容易被忽略、又最浪费时间的一行。
