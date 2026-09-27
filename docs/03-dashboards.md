# 03 · 仪表盘逐面板说明

两张仪表盘，JSON 在 [`../dashboards/`](../dashboards/)，Grafana 里直接
**Import → Upload JSON** 即可（导入后需重新绑定数据源）。

| 仪表盘 | UID | 分组 | 面板 | 刷新 | 默认区间 |
|---|---|---|---|---|---|
| 本地 GPU + LLM 全监控 | `gpu-llm-full-monitor` | 10 | 115 | 10 s | now-1h |
| LiteLLM Prod v2 | `be059pwgrlg5cf` | 3 | 7 | — | now-6h |

## 0. 数据源与模板变量

| 数据源 | 类型 | 地址 | 用途 |
|---|---|---|---|
| `Prometheus`（默认） | prometheus | `http://127.0.0.1:9090` | 全部时序指标 |
| `LiteLLM-PG` | grafana-postgresql-datasource | `127.0.0.1:5432/litellm` | 瀑布流表格（直读 `LiteLLM_SpendLogs`） |

> Grafana 侧连的是 PG 的 `litellm` 库、用户 `litellm`、`sslmode=disable`、
> `postgresVersion=1200`。这个是**独立于 Prometheus** 的第二条路 ——
> 原文（prompt / thinking / output）不适合做成指标，只能查表。

**模板变量**（顶部筛选器）：

| 变量 | 类型 | 取值 | 作用 |
|---|---|---|---|
| `tier` | custom | `0.5` 空闲 5 折 / `1` 高峰原价 / `0.65` 均摊 6.5 折 | 费用面板的价格档位系数 |
| `trace_hours` | custom | 1 / 3 / 6 / 12 / 24 / 72 | 瀑布流表格的时间窗口 |

---

## 1. 分组一：实时输入输出 · 瀑布流

| 面板 | 类型 | 说明 |
|---|---|---|
| 输入 / 输出瀑布流（最近 `${trace_hours}` 小时） | table | 直读 PG，列：模型 / 输入 tok / 输出 tok / 时长 / 首 token / 输入原文 / 思考过程 / 输出原文 |
| 瀑布流数据来源与字段说明 | text | 口径说明，见下 |

SQL 骨架：

```sql
SELECT "startTime" AS "time",
       coalesce(nullif(model_group,''), model, '') AS "模型",
       prompt_tokens AS "输入tok", completion_tokens AS "输出tok",
       round("request_duration_ms"::numeric/1000, 2) ...
FROM "LiteLLM_SpendLogs" ...
```

字段口径（面板里也写着，很容易踩）：

- **输入** = `proxy_server_request → messages` 里**最后一条消息的最后一段 text**。
  Claude Code 会把整段 transcript 塞进 content 数组的前几个元素，
  **真正的新增输入永远在最后一个元素里** —— 取错位置会看到重复的整段历史。
- **思考过程** = `response → choices[0].message.reasoning_content`
  （Qwen3 / DeepSeek-R1 类推理模型在这里；非推理模型为空）。
- **输出** = `response → choices[0].message.content`。
  **刻意不回退到思考过程** —— 若为空显示"(正文为空 — 见「思考过程」列)"，
  避免正文与思考内容重复显示。
- **时区**：库里存 UTC，交由 Grafana 按浏览器时区换算成北京时间。
  **SQL 里不能再手工 +8**，否则会多算 8 小时。
- 表格里文本被截断（输入 1200 字 / 输出 1600 字）。
  要看完整内容、思考过程折叠、关键词过滤 → 打开独立网页
  <http://127.0.0.1:9410/>（`llm_trace_api.py`，跑在 tmux `llmtrace`）。

> 表格为空时：确认 `trace_hours` 覆盖到了有请求的时段，或执行
> `select count(*) from "LiteLLM_SpendLogs" where length(response::text) > 20;`
>
> 前提：`litellm_config.yaml` 的 `general_settings` 下有
> `store_prompts_in_spend_logs: true`，改完要重启 litellm。

---

## 2. 分组二：主机 (Windows) — CPU / 温度 / 内存 / 磁盘

**Stat（6 个）**

| 面板 | 单位 | PromQL |
|---|---|---|
| CPU 使用率 | % | `host_cpu_usage_percent` |
| CPU 温度 | ℃ | `host_cpu_temperature_celsius` |
| 内存使用率 | % | `host_memory_usage_percent` |
| 内存用量 | B | `host_memory_used_bytes` |
| 提交内存 | % | `host_commit_usage_percent` |
| 逻辑核心 | — | `host_cpu_logical_cores` |

**Timeseries（5 个）**：CPU 使用率(%)、CPU 温度(℃)、内存使用率(%)、
磁盘使用率(%)（`host_disk_usage_percent`）、磁盘已用容量(B)（`host_disk_used_bytes`）。

> 「提交内存」（commit）指的是**页面文件口径**的已提交内存，不是物理内存使用量。
> Windows 上它比物理内存更能反映"还能不能再塞一个进程"。
> 这也是判断 WSL 里 vLLM 到底吃多少显存/内存的旁证。

---

## 3. 分组三：GPU 总览 (RTX 4090)

**Stat（6 个）**：GPU 利用率、显存使用(%)、显存用量(B)、GPU 温度、功耗(W)、风扇转速(%)。

```
显存使用(%) = gpu_memory_used_bytes / gpu_memory_total_bytes * 100
```

**Timeseries（7 个）**

| 面板 | 单位 | PromQL |
|---|---|---|
| 显存使用 (趋势) | B | `gpu_memory_used_bytes` |
| GPU 利用率 (趋势) | % | `gpu_utilization_gpu_percent` |
| 温度 (趋势) | ℃ | `gpu_temperature_celsius` |
| 功耗 (趋势) | W | `gpu_power_watts` |
| SM 时钟 | MHz | `gpu_clock_sm_mhz` |
| 显存时钟 | MHz | `gpu_clock_mem_mhz` |
| PCIe 链路 (gen×width) | — | `gpu_pcie_link_gen * gpu_pcie_link_width` |

> **功耗是这套看板里最被低估的一条曲线**。它和利用率的组合能一眼分辨三种状态：
>
> | 状态 | 利用率 | 功耗 | 判断 |
> |---|---|---|---|
> | 正常解码 | ~99% | 230–300 W | 健康 |
> | 正常 prefill | ~99% | ~400 W | 健康，可到 402 W 峰值 |
> | 空闲 | 0–5% | 6–8 W | 健康 |
> | **WDDM 超配** | **99%** | **96 W** | ⚠️ 慢 20 倍，无报错 |
>
> PCIe 链路的用途：`gen×width` 掉档（例如 x16 Gen4 → x4）会让显存/主机内存
> 之间的搬运成为瓶颈 —— 超配时这条路就是"卡"的物理原因。

---

## 4. 分组四：Token 用量与速率

**Stat（6 个）**

| 面板 | PromQL |
|---|---|
| 输出速率 (t/s) | `sum(rate(litellm_output_tokens_metric_total[1m]))` |
| 输入速率 (t/s) | `sum(rate(litellm_input_tokens_metric_total[1m]))` |
| 缓存占比 | `sum(litellm_input_cached_tokens_metric_total) / sum(litellm_input_tokens_metric_total) * 100` |
| 输出累计 (K) | `sum(litellm_output_tokens_metric_total) / 1000` |
| 输入累计 (M) | `sum(litellm_input_tokens_metric_total) / 1000000` |
| 缓存命中累计 (M) | `(sum(litellm_input_cached_tokens_metric_total) or vector(0)) / 1000000` |

**Timeseries（5 个）**：输出/输入/缓存命中速率（均 `sum by (model)`）、
缓存占比趋势、Token 累计量。

> **缓存命中率是这套栈的"性价比核心"**。多轮 agent 负载下前缀复用完全生效：
> 30k 上下文的第 2 轮起 `prompt_n` 只有 44~46 token、缓存命中 ~30k，
> 单轮耗时从 23.6 s 降到 **1.4~2.0 s**。
> 所以"长 prompt 的每轮真实成本几乎全在解码，不在 prefill" ——
> 这句话决定了权重档位怎么选（见 README 第 2 节）。

---

## 5. 分组五：并发与排队（Little's Law 校准）

用 `L = λ · W` 从 litellm 的两个计数器反推**真实在飞请求数**，
和 litellm 自报的 gauge 对照 —— 后者在小样本/丢采样时会失真。

**Stat（6 个）**

| 面板 | 单位 | PromQL |
|---|---|---|
| 平均并发 L | — | `sum(rate(litellm_request_total_latency_metric_sum[5m]))` |
| 峰值并发 (30m) | — | `max_over_time(sum(rate(litellm_request_total_latency_metric_sum[5m]))[30m:1m])` |
| 请求速率 λ (QPS) | — | `sum(rate(litellm_request_total_latency_metric_count[5m]))` |
| 平均请求耗时 W | s | `sum(rate(..._sum[5m])) / clamp_min(sum(rate(..._count[5m])), 0.0001)` |
| 排队等待 p95 | s | `histogram_quantile(0.95, sum by (le) (increase(litellm_request_queue_time_seconds_bucket[30m])))` |
| litellm 原始 gauge (对照) | — | `sum(litellm_in_flight_requests)` |

**Timeseries（5 个）**：并发趋势（校准值 vs 原始 gauge 两条线）、排队等待时长、
按调用模型并发、按调用模型 QPS、并发 vs 输出吞吐（双轴）。

```
平均并发 L ≈ sum(rate(request_total_latency_sum[5m]))
```
因为 `rate(sum)` 的量纲就是"请求数 × 秒/秒" = 在飞请求数 ——
这就是 Little's Law 在计数器上的直接用法，**不需要额外埋点**。

> 为什么不用 `litellm_in_flight_requests` 当主指标：它是**采样瞬间的 gauge**，
> Prometheus 15 s 抓一次，短请求很容易整个被采样跳过；
> 而 `rate(sum)` 是积分量，不丢。

---

## 6. 分组六：请求与延迟

| 面板 | 单位 | PromQL |
|---|---|---|
| QPS | req/s | `sum(rate(litellm_deployment_total_requests_total[1m]))` |
| 失败请求 | — | `sum(litellm_deployment_failure_responses_total)` |
| 进行中请求 (校准 L=λ·W) | — | 同"平均并发 L" |
| 每 token 延迟 (ms) | ms | `(litellm_deployment_latency_per_output_token_sum / ..._count) * 1000` |
| 请求速率 (QPS) | req/s | `sum by (model) (rate(litellm_deployment_total_requests_total[1m]))` |
| 失败请求速率 | req/s | `sum by (model) (rate(litellm_deployment_failure_responses_total[1m]))` |
| 每输出 token 延迟 (ms) | ms | `sum(rate(..._per_output_token_sum[30m])) / clamp_min(sum(rate(..._count[30m])), 0.0001) * 1000` |
| TTFT p95 (ms) | ms | `histogram_quantile(0.95, sum by (le, model) (increase(litellm_llm_api_time_to_first_token_metric_bucket[30m]))) * 1000` |

> 所有分位/均值都用了 `clamp_min(..., 1e-9)` 或 `0.0001` 兜底 ——
> 否则分母为 0 时面板会变成 `NaN` 空白，而不是 0。

---

## 7. 分组七：成本计费（按 DeepSeek 官方价折算）

把**本地 Qwen3-27B 消耗的 token** 按 DeepSeek `deepseek-v4-flash` 官方价折算成
"如果用云端 API 要花多少钱"。价格表：

| 项目 | 空闲时段 | 高峰时段 |
|---|---|---|
| 输入 · 缓存命中 | ¥0.05 / 1M | ¥0.10 / 1M |
| 输入 · 缓存未命中 | ¥1.5 / 1M | ¥3.0 / 1M |
| 输出 | ¥4.5 / 1M | ¥9.0 / 1M |

高峰时段＝北京时间 09:00–12:00、14:00–18:00，其余为空闲（空闲价＝高峰价 5 折）。
`${tier}` 变量：0.5 / 1 / 0.65。

```
费用 = (缓存命中输入 × 缓存价 + (输入 − 缓存命中输入) × 输入价 + 输出 × 输出价)
       / 1,000,000 × 档位系数
```

`litellm_input_cached_tokens_metric_total` 是 `litellm_input_tokens_metric_total`
的**子集**，所以未命中部分 = 输入 − 缓存命中。

| 面板 | 类型 | 内容 |
|---|---|---|
| 本区间费用 (¥) | stat | 区间内 `increase(...)` 折算 |
| 累计费用 (¥) | stat | 自进程启动至今 |
| 费用速率 (¥/h) | stat | `rate(...)` 折算 |
| 缓存已省 (¥) | stat | `cached * (3.0 - 0.1) / 1e6 * ${tier}` |
| 费用速率分解 (¥/h) | timeseries | 缓存/输入/输出三条分开 |
| 累计费用 (¥) | timeseries | 趋势 |
| 费用构成 (累计) | stat | 三段构成 |
| 按调用模型累计费用 (¥) | barchart | `topk(8, sum by (requested_model) ...)` |

> ⚠️ 计数器在 **LiteLLM 重启后归零**，所以"累计"= 自上次启动至今，
> 不是月度账单。要长期账得看 PG 或做 `increase` 持久化。

---

## 8. 分组八：硬件传感器（LibreHardwareMonitor）

**Timeseries（5 个）**

| 面板 | PromQL |
|---|---|
| CPU 温度 · 每核 / 封装 | `host_hw_temperature_celsius{hardware=~".*i7.*",sensor=~"Core Max\|Core Average\|CPU Core #.*"}` |
| 主板温度 (ASUS Z590-E / NCT6798D) | `host_hw_temperature_celsius{hardware=~".*Z590.*"}` |
| 风扇转速 | `host_hw_fan_rpm` |
| CPU 功耗 | `host_hw_power_watt{hardware=~".*i7.*"}` |
| CPU 频率 · 每核 | `host_hw_clock_megahertz{hardware=~".*i7.*",sensor=~"CPU Core #.*\|Bus Speed"}` |

**Table**：`{__name__=~"host_hw_.*"}` —— 所有传感器当前值一屏列全。

**Stat（4 个）**：CPU 温度源状态（`host_cpu_temperature_reliable`）、
CPU 封装温度、CPU 功耗(Package)（`sensor="CPU Package"`）、
CPU 频率(最高核)（`max(host_hw_clock_megahertz{sensor=~"CPU Core #.*"})`）。

> **为什么要有"温度源状态"这个 stat**：
> 华硕 Z590-E 上 WMI 的 ACPI 热区（`Win32_PerfRawData_Counters_ThermalZoneInformation`）
> **恒为 27.85 ℃**，是固定占位值。exporter 的处理是：连续采样 3 次值完全相同
> → 判定为不可靠 → **不输出 `host_cpu_temperature_celsius`**（避免假曲线），
> 只把 `host_cpu_temperature_reliable=0` 和 source_info 打出来。
> 可靠 CPU 温度**只能**来自 LibreHardwareMonitor。
> 所以看到 27.85 ℃ 平线时，先看这个 stat 是不是 0。

---

## 9. 分组九：vLLM 引擎 · Qwen3.8-27B

**只在 vLLM 类后端有数据**（llama.cpp 不产 `vllm:*` 指标），
Prometheus 抓 `127.0.0.1:18020/metrics`（vLLM 单用户模式自带，413 条）。

| 面板 | 单位 | PromQL |
|---|---|---|
| KV 缓存占用 | % | `vllm:kv_cache_usage_perc * 100` |
| 解码速度 | t/s | `sum(rate(vllm:generation_tokens_total)) / sum(rate(vllm:inter_token_latency_seconds_sum))` |
| 每步产出 token | — | `sum(rate(generation_tokens_total)) / clamp_min(sum(rate(inter_token_latency_seconds_count)), 1e-9)` |
| 投机接受率 | % | `sum(rate(spec_decode_num_accepted_tokens_total)) / clamp_min(sum(rate(spec_decode_num_draft_tokens_total)), 1e-9)` |
| 输出速度(瞬时) | t/s | `sum(irate(vllm:generation_tokens_total[1m]))` |
| 运行中请求 | — | `vllm:num_requests_running` |
| 排队中请求 | — | `vllm:num_requests_waiting` |
| Token 吞吐 | t/s | `sum(rate(vllm:generation_tokens_total))` |
| litellm 侧 每输出 token 延迟 | s | `rate(litellm_..._per_output_token_sum) / clamp_min(rate(..._count), 1e-9)` |
| 首 token 延迟 TTFT 分位 | s | `histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket)) by (le))` |
| 端到端延迟分位 | s | `histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket)) by (le))` |
| 请求结束原因 速率 | req/s | `sum(rate(vllm:request_success_total)) by (finished_reason)` |
| 缓存命中率 | % | `sum(rate(vllm:prefix_cache_hits_total)) / clamp_min(sum(rate(vllm:prefix_cache_queries_total)), 1e-9) * 100` |

两个值得单独说的设计：

**「解码速度」的分母是 `inter_token_latency_seconds_sum`**：
它不是"总 token / 总墙钟"，而是**每步间隔的累加** ——
于是排除了排队等待，只反映引擎真正的解码速率，
和 litellm 侧看到的"端到端慢"可以分离定位：是引擎慢，还是排队长。

**「每步产出 token」= `generation_tokens / inter_token_latency_count`**：
这就是连续批处理下的**平均 batch 大小**。
短上下文并发时它上不去（batch 小），长上下文时它被 KV 限制 ——
是判断"批处理有没有真正发挥作用"最直接的一条。

---

## 10. 分组十：DFlash2 投机解码 (k=7) — 草稿命中与浪费

| 面板 | 单位 | PromQL / 含义 |
|---|---|---|
| 累计接受率 (自启动) | % | `sum(vllm:spec_decode_num_accepted_tokens_total) / clamp_min(sum(vllm:spec_decode_num_draft_tokens_total), 1e-9) * 100` |
| 草稿浪费率 | % | `(1 − 上式) * 100` |
| 每步草稿 token 数 (配置自检) | — | `sum(rate(draft_tokens_total)) / clamp_min(sum(rate(spec_decode_num_drafts_total)), 1e-9)` |
| 输出中草稿命中占比 | % | `sum(rate(accepted_tokens_total)) / clamp_min(sum(rate(generation_tokens_total)), 1e-9) * 100` |
| 逐位接受率 (位置 0-6) | % | `sum by (position) (rate(vllm:spec_decode_num_accepted_tokens_per_pos_total)) / ...` |
| 逐位接受率 · 当前 | bargauge | 同上，累计值 |
| 草稿吞吐 vs 接受吞吐 | t/s | `rate(draft_tokens_total)` vs `rate(accepted_tokens_total)` |

**逐位接受率是投机解码唯一的调参依据**：位置 0 的接受率应该明显高于位置 6，
如果整条曲线都很平/都很低，说明草稿模型（或 ngram）和目标模型分布不匹配。

> **判定"投机到底有没有在跑"**：看 API 响应里的
> `timings.draft_n` / `draft_n_accepted`。**`draft_n` 缺失或为 0 = 没生效**，
> 看板上"每步草稿 token 数"也会是 0。
>
> 这套栈的实测结论是**不加投机**：
> - MTP 头不在权重里（Bonsai 2 无 nextn 张量）；
> - DFlash2 草稿模型是**目标专用**的，跨代无效；
> - 官方 SPECULATIVE.md 明说这条路的代价是
>   **禁用跨请求前缀缓存 + 强制 `-np 1`** —— 按本机实测，
>   那会把每轮成本从 1.4~2.0 s 变成全量重算（200k 历史 ≈ 240 s），
>   换 1.8~2.4× 解码，对多轮 agent 负载是**净亏**；
> - `ngram-cache` 实测产出 `draft_n=254` 但**接受 0**，
>   轮 1 从 21.7 s 涨到 53.2 s、并发聚合 97.2 → 58.6 t/s。

---

## 11. 分组十一：GPU 显存超配 — 主机内存兜底 (WDDM)

**这一组是整张看板里最有价值的一组** —— 它看得见一个**没有任何日志和报错**的故障。

| 面板 | 单位 | PromQL |
|---|---|---|
| 超配余量 (物理 − committed) | B | `host_gpu_memory_physical_bytes − host_gpu_memory_committed_bytes` |
| committed / 物理 | % | `host_gpu_memory_committed_bytes / host_gpu_memory_physical_bytes * 100` |
| 主机内存里的显存 (Shared) | B | `host_gpu_memory_shared_bytes` |
| committed vs 物理上限 | B | `host_gpu_memory_physical_bytes` / `..._committed_bytes` |
| Dedicated(真 VRAM) vs Shared(主机内存) | B | `host_gpu_memory_dedicated_bytes` / `..._shared_bytes` |
| 显存控制器利用率（退化指示器） | % | `host_gpu_memory_controller_percent` |

全部带 `hardware=~".*RTX 4090.*"` 过滤。

**机制**：物理显存不够时，WDDM 把一部分显存兜底放到**主机内存**（走 PCIe）。
过程中不报错、不告警。但推理会静默变慢：

| Shared（主机内存里的显存） | 实测解码 |
|---|---|
| ~400 MiB | 76 t/s |
| ≥ ~850 MiB | **9 t/s** |

**「显存控制器利用率」是退化指示器**：健康时 66–73%，
一旦掉到 1–9% 就说明显存访问被 PCIe 拖住了 ——
比看 `memory.used` 更早、更准确。

> 这个指标之所以能拿到，是因为 `host_exporter_win.py` 里**专门**处理了
> LHM 的 GPU 显存节点（`d3d dedicated memory used` / `d3d shared memory used` /
> `gpu memory total` / `gpu memory used` / `gpu memory free` /
> `gpu memory controller`）。这些节点不在 LHM 的任何常规传感器分组下
> （它们靠 `temperatures`/`Loads` 这类分组名匹配），
> 漏掉的话就完全看不到 WDDM 把显存挪去了哪里。
>
> LHM 显示的 "MB" 实际是 **MiB**（已与 `Get-Counter` 的 Total Committed 交叉验证），
> 所以换算用 `1024*1024`。

---

## 12. 第二张盘：LiteLLM Prod v2

官方模板，7 个面板、3 个分组，区间 now-6h，无自动刷新。
值得留着的理由是它**不依赖本机埋点**，可以当"对照组"。

| 分组 | 面板 | PromQL |
|---|---|---|
| Proxy Level Metrics | Requests per second (success + failure) | `sum(rate(litellm_proxy_total_requests_metric_total[2m]))` |
| | Failure Responses / Second by Exception Class | `sum(rate(litellm_proxy_failed_requests_metric_total[2m])) by (exception_class)` |
| | Average & Median Response Latency (s) | `sum(rate(request_total_latency_sum[2m])) / sum(rate(request_total_latency_count[2m]))` |
| LLM API Metrics | `x-ratelimit-remaining-requests` | `topk(5, sort(litellm_remaining_requests))` |
| | `x-ratelimit-remaining-tokens` | `topk(5, sort(litellm_remaining_tokens))` |
| by Virtual Key / Team | Requests per second by Key Alias | `sum(rate(litellm_proxy_total_requests_metric_total[2m])) by (api_key_alias)` |
| | Requests per second by Team Alias | 同上 `by (team_alias)` |

> `by (exception_class)` / `by (api_key_alias)` 这两条在本地单用户场景下用处不大
> （只有一个 key / 一类异常），但如果把 1234 端口经 portproxy 开放给局域网其他设备，
> 这两条立刻变成"谁在用、谁在报错"的主要依据。

---

## 13. 导入与重建

```bash
# 导出（从运行中的 Grafana）
curl -u admin:admin http://127.0.0.1:3000/api/dashboards/uid/gpu-llm-full-monitor > dash.json

# 导入
curl -u admin:admin -X POST http://127.0.0.1:3000/api/dashboards/db \
  -H 'Content-Type: application/json' \
  -d '{"dashboard": <dash.json 的 dashboard 字段>, "overwrite": true}'
```

仓库里的两个 JSON 是**从运行实例导出的当前版本**，
已把 `bearer_token` / `master_key` 一类字符串替换为 `sk-lm-REPLACE_ME`；
导入后请确认数据源 UID 指向你自己的 Prometheus 与 PostgreSQL。
