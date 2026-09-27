# 02 · 一键启动：`start_all` 与 WSL 脚本

## 0. 一句话

```bat
start_all.bat                     :: 默认 = llama.cpp + Bonsai M4
start_all.bat -Backend vllm-bonsai
start_all.bat -Backend vllm
start_all.bat -Open               :: 起来后开浏览器
stop_all.bat
```

**不需要管理员权限**（LibreHardwareMonitor 可能单独弹一次 UAC）。

## 1. `start_all.bat` —— 只是壳

它做的事：`chcp 65001`（UTF-8，否则后面 PowerShell 输出中文全乱）→
切成 `.bat` 所在目录 → 调 `start_all.ps1` → `pause`。

参数原样透传；**无参数时显式补 `-Backend bonsai`**，
和 `.ps1` 的默认值保持一致（历史上有过两边不同步的坑）。

`.bat` 文件本身必须**纯 ASCII** —— `cmd.exe` 遇到 BOM 会报错，
所以中文说明一律放在 `.ps1` 里。

## 2. `start_all.ps1` —— 真正的编排（五步）

### 参数

| 参数 | 默认 | 作用 |
|---|---|---|
| `-Backend` | `bonsai` | `bonsai` / `vllm-bonsai` / `vllm` |
| `-Open` | 关 | 结束时打开 litellm UI |
| `-SkipWsl` | 关 | 只起 Windows 侧（9401 / 8085） |
| `-NoGuard` | 关 | 不起 vLLM 守护 |
| `-Distro` | `Ubuntu` | WSL 发行版名 |

其中 `-Backend` 只决定**两件事**：跑哪个 WSL 脚本、起哪个守护。

### `[1/5]` 检查 WSL 环境 —— 这里藏着两个大坑的自愈

顺序是：`wsl.exe` 能不能启动 → 发行版能不能执行 `bash` →
**`/mnt` 里能不能看到 Windows 文件系统**。

**(a) `/mnt/*` 静默失挂。** WSL 工具 VM 长时间不重启、而中途**只有发行版单独重启过**时，
drvfs 重挂会失败，`/mnt/c` `/mnt/d` `/mnt/e` 全变成**空目录**，
内核日志里是：

```
WSL (2 - init-systemd(Ubuntu)) ERROR: ConfigRemountDrvFsImpl:2256:
Non-Admin namespace already initialized
```

症状是 `wsl.exe` 刷一屏 `Failed to translate 'C:\...'`，
然后 WSL 脚本以 **127**（No such file or directory）死掉 ——
看起来像脚本找不到，其实是整个 `/mnt` 没了。

> ⚠️ **systemd 拉起的服务不受影响**：PostgreSQL 5432 照样活着。
> 所以**别把"5432 在"当成 WSL 健康**。

修法只有 `wsl --shutdown`（重建整个工具 VM）——
`wsl --terminate <发行版>` 不够，命名空间在 VM 层。
脚本检测到未挂载会**自动执行一次 `wsl --shutdown` 再重试**。

**(b) `wsl.exe` 被程序黑名单拦了。** 如果 `wsl.exe` 出现在
**安全中心 → 命令安全 → 程序黑名单**，任何从脚本/工具发起的调用都会失败
（`Access is denied` / `PROGRAM BLOCKED BY SECURITY POLICY`）。
此时**WSL 本体照常跑**（`wslservice` / `vmmemWSL` 还在），
之前起的服务仍占着端口 → 出现"5432 活着、其余全 DOWN"的**半死状态**，
极易误判成服务自身故障。

脚本会**把原始报错原文打出来**并明确告诉你是"程序被拦"而不是"发行版不可用"。
修法：把 `wsl.exe` 从那个黑名单里移除。

> 探测"程序能不能启动"时**不能**把 `$ErrorActionPreference` 提成 `Stop`：
> 程序正常往 stderr 写一行告警（`hostname.exe`、`wsl.exe` 的
> `Failed to translate`）也会变成终止性错误，从而误判成"启动失败"。
> 正确做法是保持 `Continue`、抓错误流原文、按特征词判定。

### `[2/5]` Windows 侧：LHM(8085) + 主机指标(9401)

- 若 LHM 进程已在跑但 8085 没监听 → 只提示"请去 LHM 窗口里
  Options → Remote Web Server → Run"，**不再启动第二个实例**。
- 9401：优先 `Start-Process` 拉起 `host_exporter_win.py`，失败则退回 WMI 方式。
  已监听就跳过。

### `[2.5/5]` Bonsai 模式：先停显存守护

**这一步的位置很关键**：必须在拉起模型**之前**，不能等到 `[4/5]`。
因为 `gpu_overcommit_guard.ps1 -EnableRestart -Watch` 会在 vLLM 消失后
调 `restart_vllm.sh --force` 把它拉回来抢显存 —— 30 秒内就会发生。

做两件事：`Disable-ScheduledTask GPU_VRAM_Overcommit_Guard`，
以及按命令行特征（必须同时含 `-File`/`-EnableRestart`/`-Watch`）找并停掉常驻守护进程。

> 只按 `gpu_overcommit_guard` 匹配会**误命中"命令文本里提到该字符串"的其他进程** ——
> 实测把自己的调试命令也判成了残留守护。所以特征词要够长。
> 同时脚本内部用字符串拼接构造匹配串（`'bonsai_' + 'guard.ps1'`），
> 避免脚本把自己的命令行也匹配上而自杀。

### `[3/5]` WSL 侧

```
wsl.exe -d Ubuntu -e bash -lc "/mnt/c/Users/administrat0r/start_wsl_services_bonsai.sh"
```

按 `-Backend` 选择：

| Backend | WSL 脚本 |
|---|---|
| `bonsai` | `start_wsl_services_bonsai.sh` |
| `vllm-bonsai` | `start_wsl_services_vllmbonsai.sh` |
| `vllm` | `start_wsl_services.sh` |

`-SkipWsl` 时跳过。

### `[4/5]` 按后端拉起对应的守护（两个互斥）

| Backend | 守护 | 说明 |
|---|---|---|
| `bonsai` | `bonsai_guard.ps1 -EnableRestart -Watch` | 显存空着才拉起 |
| `vllm-bonsai` | 同一个 `bonsai_guard.ps1`，多传 `-RestartScript .../start_wsl_services_vllmbonsai.sh` | 重启动作换成拉 vLLM |
| `vllm` | `gpu_overcommit_guard.ps1 -EnableRestart -Watch` | 顺带禁用旧的计划任务 |

切换时脚本会**先停掉"另一个后端"的守护**（靠 `-RestartScript` 里的
`vllmbonsai` 字样区分），因为两个守护会抢同一张卡重启。

**以隐藏常驻进程而不是计划任务**：历史教训（2026-09-12）是计划任务每分钟新建一个进程，
Windows 会先为它创建 conhost 控制台，`-WindowStyle Hidden` 来不及拦 →
**每分钟闪一次黑窗**。现在改成"常驻单进程、只创建一次"。

### `[5/5]` 端口健康检查 + 入口地址

对 9 个端口逐个 `Test-Port`，打 `[OK]` / `[DOWN]`，
最后列出 litellm UI / OpenAI API / 模型直连 / Grafana / Prometheus / 瀑布流地址。

## 3. WSL 侧脚本

### 3.1 `start_wsl_services_bonsai.sh`（默认后端）

```
[1/4] PostgreSQL 5432      pg_isready 探测，未起则 pg_ctlcluster/service
[2/4] llama.cpp Bonsai     18020
[3/4] litellm              1234
[4/4] 监控                 9090 / 3000 / 9400 / 9410
```

可调环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `BONSAI_NP` | `3` | 并发槽位数，每槽 262144 上下文 |
| `BONSAI_QUANT` | `PTQ1_0` | 权重档位（`PTQ1_0` / `PQ2_0`） |
| `BONSAI_MMPROJ` | `1` | 是否加载视觉塔（省 ~0.6 GiB） |
| `BONSAI_PER_CTX` | `262144` | 每槽上下文 |

**它做的最重要的一件事是"配置漂移检测"**：不只看端口是否活着，而是从
`ps -eo args` 里读出当前 `llama-server` 的 `-np` 与权重文件名，
和期望值比对，不一致就 `tmux kill-session` + `pkill` 重启。
所以"换后端/换档位"是幂等的。

启动前会**先清掉抢显存的 vLLM**（`[v]llm serve`，两者无法共存于 24 GB）。

模型在 `tmux session bonsai` 里跑，日志 `~/bonsai/logs/server_np<N>.log`。
> `tmux new-session` **不继承调用者的环境变量**，所以 `NP=… QUANT=…` 是写进命令串里的。

### 3.2 `start_wsl_services_vllmbonsai.sh`（vLLM + Bonsai）

同一份 Bonsai 2 27B 权重、换成 vLLM + `prism_ternary` 插件，
checkpoint 指向**带视觉**的 `~/bonsai_vllm_vl`。

| 变量 | 默认 | 说明 |
|---|---|---|
| `VLLM_MAX_LEN` | `262144` | `--max-model-len` |
| `VLLM_MAX_SEQS` | `128` | 混合 GDN 模型开 CUDA graph 时受 Mamba 块数限制（可用 170 块） |
| `VLLM_GPU_UTIL` | `0.93` | **上限 ≈0.936**，0.94/0.95 直接拒绝启动 |
| `VLLM_KV_MEM` | `8000000000` | `--kv-cache-memory`；**留空 = 自动** |
| `VLLM_BONSAI_CKPT` | `~/bonsai_vllm_vl` | 回滚纯文本版：`~/bonsai_vllm` |
| `VLLM_ALIAS` | `qwen3.8-27b` | 与 llama.cpp 同名，litellm 零改动 |

四个必须记住的坑（写在该脚本头部）：

1. **必须开 CUDA graph**，不要 `--enforce-eager`：eager 下只有 ~9 t/s，
   开了 7 倍到 ~70 t/s（小 batch 解码被 kernel 启动开销拖死）。
2. **`--max-num-seqs` 必须 ≤ 可用 Mamba 块数**（本配置 170，故设 128），
   否则报 `max_num_seqs (256) exceeds available Mamba cache blocks (170)`。
3. venv 自带 flashinfer 版本不匹配（cubin 0.6.13 vs 0.6.16）会让启动直接
   `RuntimeError`，用 `VLLM_USE_FLASHINFER_SAMPLER=0` 绕开。
4. torch 编译扩展要 `ninja`，**venv 的 bin 必须在 PATH 上**，
   `CUDA_HOME` 要指向 `/usr/local/cuda`。

实测基线（单流，TTFT 与 decode 分开）：

| 上下文 | TTFT | decode |
|---|---|---|
| ~0 | 0.36 s | **86.8 t/s** |
| ~2.5k | 1.87 s | 83.7 t/s |
| ~11k | 6.18 s | 77.7 t/s |
| ~35k | 20.99 s | 63.8 t/s |

prefill ≈ 1500~1600 t/s（与 llama.cpp M4 同档）；
4 路并行聚合 **269.6 t/s**（llama.cpp M4 3 路只有 100.7）。

**KV 显存悬崖（反直觉，必须实测）**：`--kv-cache-memory` 不是越大越好。

| KV_MEM | KV token | 262k 并发 | 空闲显存 | 单流解码 |
|---|---|---|---|---|
| 自动 | 501,492 | 1.91× | 469 MiB | 未测 |
| 7,795,443,712 | 430,258 | 1.64× | 1022 MiB | 77.7 t/s |
| **8,000,000,000（定版）** | **441,655** | **1.68×** | **830 MiB** | **78.0 t/s** |
| 8,500,000,000 | 470,149 | 1.79× | 440 MiB | **52.0 t/s** ⚠️ |

空闲 ≥830 MiB 满速；掉到 ~440 MiB 就塌到 52 t/s（连测 3 次稳定）。
这是 WDDM 部分超配，且**只掉 1/3，比"直接崩"隐蔽得多**。

### 3.3 `start_monitoring.sh` —— 监控四件套

```
[1/4] GPU exporter      9400
[2/4] Prometheus        9090
[3/4] Grafana           3000
[4/5] LLM 瀑布流         9410
[5/5] 探测 Windows 侧 9401
```

三个细节值得抄：

- **Prometheus 必须显式排除本机代理**：
  `export no_proxy="127.0.0.1,localhost,0.0.0.0"`。
  Prometheus 的 Go http client 默认跟随环境变量代理，
  抓 `127.0.0.1` 会被代理拦成 `context deadline exceeded` ——
  看着像端口不通，其实是走了代理。
- **9410 幂等**：端口已在监听（例如跑在 tmux `llmtrace` 里）就不再拉起，
  否则新进程 bind 失败、日志里一堆 `Address already in use`。
- **9401 只探测不启动**：WSL 常驻进程调 Windows 可执行文件会
  `UtilAcceptVsock` 超时挂死，必须由 Windows 侧先起。

## 4. 停止

```bat
stop_all.bat                  :: 停 Windows 侧 9401/8085 + WSL 侧全套 + 两个守护
stop_all.bat -WithPostgres    :: 连 PostgreSQL 一起停
stop_all.bat -KeepLhm         :: 保留 LibreHardwareMonitor
```

PostgreSQL 默认**保留**，因为 litellm 的用量记录存在里面。

WSL 侧单独停：`stop_wsl_services.sh`；
只停 litellm：`stop_litellm.sh`；
只停 Bonsai：`bash ~/stop_bonsai.sh`。

## 5. 常见"看起来坏了其实没坏"

| 现象 | 真相 |
|---|---|
| 第一条请求比后面慢一倍 | llama.cpp 冷启动预热惩罚，~2.3×，正常 |
| `5432` 在但别的端口全 DOWN | 先查 `wsl.exe` 是否被程序黑名单拦了（WSL 本体没死） |
| WSL 脚本报 127 且刷 `Failed to translate` | `/mnt` 失挂，`wsl --shutdown` |
| litellm 端口不通、日志无报错 | litellm 会静默消失，先 `bash ~/restart_litellm.sh` |
| 端口在监听但 127.0.0.1 不通 | WSL loopback 失效，属 guard 的判据之一 |
