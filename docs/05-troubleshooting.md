# 05 · 排障清单（现场踩过的坑）

按"症状 → 真因 → 修法"排列。**加粗的是最容易被误判的那几条。**

## A. WSL 与进程

### A1. WSL 脚本报 127，`wsl.exe` 刷一屏 `Failed to translate 'C:\...'`

**真因**：WSL 工具 VM 长时间不重启、而中途**只有发行版单独重启过**时，
drvfs 重挂失败 —— `/mnt/c` `/mnt/d` `/mnt/e` 全变成**空目录**，`/mnt` 里什么都看不到。
内核日志：

```
WSL (2 - init-systemd(Ubuntu)) ERROR: ConfigRemountDrvFsImpl:2256:
Non-Admin namespace already initialized
```

**修法**：`wsl --shutdown`（重建整个工具 VM）。
`wsl --terminate <发行版>` **不够** —— 命名空间在 VM 层。

> ⚠️ **systemd 拉起的服务不受影响**：PostgreSQL 5432 照样活着。
> 所以别把"5432 在"当 WSL 健康。`start_all.ps1` 的 `[1/5]` 步已内置检查 + 自动重建。

### A2. 只有部分端口活着（"半死状态"）

**真因**：`wsl.exe` 被加进了 **安全中心 → 命令安全 → 程序黑名单**。
任何从脚本/编辑器发起的 `wsl.exe` 调用都会失败：

```
Access is denied / PROGRAM BLOCKED BY SECURITY POLICY
```

而 **WSL 本体照常跑**（`wslservice` / `vmmemWSL` 还在），之前起的服务仍占着端口。
于是出现"5432 活着、其余全 DOWN"，极易误判成服务自身故障。

**修法**：把 `wsl.exe` 从那个黑名单里移除。

> ⚠️ **别把它报成"发行版不可用"** —— 那是早期版本误导人的说法。
> `start_all.ps1` 现在会把原始报错原文打出来，并明说是"程序被拦"。

### A3. 探测"程序能不能启动"时误判成失败

**真因**：把 `$ErrorActionPreference` 提成 `Stop`。
程序**正常**往 stderr 写一行告警（`hostname.exe`、`wsl.exe` 的
`Failed to translate`）也会变成终止性错误。

**修法**：保持 `Continue`、抓错误流原文、按特征词判定，**并把原文一并报出来**。

### A4. `pkill`/`pgrep` 把自己杀了

**真因**：匹配串出现在自己的命令行里（`bash -lc "... pgrep -f 'litellm --config'"`）。
2026-09-18 实测：重启命令把自己 kill 掉，旧进程已停、新进程没起，服务直接消失。

**修法**：用括号规避（`[l]itellm`、`[v]llm`），PowerShell 里用字符串拼接
（`'bonsai_' + 'guard.ps1'`）。**匹配特征词还要够长** ——
只按 `gpu_overcommit_guard` 匹配会误命中"命令文本里提到该字符串"的其他进程。

### A5. `tmux new-session` 里环境变量丢了

**真因**：tmux 不继承调用者的环境。

**修法**：env 写进命令串：`tmux new-session -d -s bonsai "NP=3 QUANT=PTQ1_0 bash start.sh"`。

### A6. litellm 会**静默消失**

**真因**：无报错日志，进程就是没了。

**修法**：发现 1234 不通先 `bash ~/restart_litellm.sh`，再排查别的。

## B. 编码与文件

### B1. PowerShell 调 WSL，中文输出全乱码

症状：`侧服务启动` → `渚ф湇鍔″惎鍔`。

**真因**：PowerShell 用控制台 OEM 码页（本机 gb2312）解码子进程 stdout。

**修法**：必须在**调用 `wsl.exe` 之前**同时做两件事，**只改一处不够**：

```powershell
& "$env:SystemRoot\System32\chcp.com" 65001
[Console]::OutputEncoding = [Text.Encoding]::UTF8
```

**验证时防"二次解码"假象**：外层 PowerShell 若是 gb2312，
会把你已修好的 UTF-8 再解码成乱码，让人误判没修好。验证时外层也要先设 UTF-8。

### B2. 手写的 `.sh` 在 WSL 里执行报语法错

**真因**：Windows 写的文件带 CRLF。

**修法**：`.sh` 必须 LF、`.ps1` 必须带 **UTF-8 BOM**、`.bat` 必须纯 ASCII。
经 `/mnt/c` 被 WSL 读的 `.sh` 改完要 `bash -n` 验语法 + 查 CRLF 计数。

### B3. 没有 BOM 的 `.ps1` 会报一堆"缺少终止符"

**真因**：PowerShell 5.1 对无 BOM 的 `.ps1` 按系统 ANSI 码页（GBK）解析，
中文注释变乱码，乱码字节吞掉引号。

症状：语法检查报 10+ 个错，错误行号分散、信息莫名其妙。

**修法**：

```powershell
[System.IO.File]::WriteAllText($p,$s,(New-Object System.Text.UTF8Encoding $true))
```

### B4. 带中文的路径在 PowerShell 命令行里被搞坏

**真因**：编码问题，实测 exit code 1、连日志都没写出来。

**修法**：中文路径的文件操作一律走 Python 的 `os.rename` / `os.remove`。

### B5. Bash 工具会改写传给 WSL 的绝对路径

**真因**（2026-09-26）：命令串里出现的 `/home/...`、`~/...`、`/mnt/c/E:` 会被工具层
改写成 Windows 路径，表现为"文件明明存在却 open 失败/读成垃圾"。
`/mnt/e/...`（无盘符冒号）可正常透传。

**修法**：用 heredoc 喂 Python，脚本内部用 `os.environ["HOME"]` 拼路径：

```bash
wsl bash -lc 'exec $HOME/qwen-serving/venv/bin/python <<PY
import os
print(os.path.expanduser("~/bonsai"))
PY'
```

⚠️ 不要在 heredoc 里用 `$(...)` / 嵌套引号 —— 外层 Git Bash 会先做命令替换把串搞坏。

### B6. Bash 工具的 coreutils 残缺

`dirname` / `head` / `sed` / `seq` / `which` 时常 not found（PATH 被 shim 打断）。
**对策**：环境探测一律走 Python；要跑 shell 脚本就写成文件再 `bash file.sh`。

## C. 显存与性能

### C1. 推理突然慢 20 倍，**没有任何报错**

**真因**：**WDDM 显存超配**。物理显存不够时 WDDM 把一部分显存兜底到**主机内存**（走 PCIe）。
能加载、日志干净。

| Shared（主机内存里的显存） | 解码 |
|---|---|
| ~400 MiB | 76 t/s |
| ≥ ~850 MiB | **9 t/s** |

**判定**：看 `host_gpu_memory_shared_bytes`、`host_gpu_memory_committed_bytes`
vs `host_gpu_memory_physical_bytes`、`host_gpu_memory_controller_percent`（掉到 1–9% 即退化）。

**修法**：`gpu_overcommit_guard.ps1` 会自动检测并重启回收；
在 Bonsai / vLLM-Bonsai 模式下没有这个兜底，只能靠**不贪容量**。

### C2. 慢 1/3，看起来像"模型变慢了"

**真因**：同样是 WDDM，但只是**部分**超配 —— 比 C1 隐蔽得多。

实测（vLLM-Bonsai，120 token 解码）：

| `--kv-cache-memory` | KV token | 空闲显存 | 单流解码 |
|---|---|---|---|
| 7,795,443,712 | 430,258 | 1022 MiB | 77.7 t/s |
| **8,000,000,000** | 441,655 | **830 MiB** | **78.0 t/s** |
| 8,500,000,000 | 470,149 | **440 MiB** | **52.0 t/s** ⚠️ |

**判定**：同一请求连测 3 次 + 看 `nvidia-smi memory.used` 余量。
（三组数各测 3 次，结果稳定，不是抖动。）

**修法**：`--kv-cache-memory` 不是越大越好；**调这个参数必须实测解码速度**，
不能只看 KV token 数。

### C3. 板卡利用率 99% 但功耗只有 96 W

**真因**：典型 WDDM 超配。健康基线是 prefill ~400 W、解码 230–300 W、空闲 6–8 W。

**判定**：**板卡功耗是判定这类问题最快的单一指标**。

具体案例：Bonsai `NP=4` 能加载、空闲显存也只比 NP=3 多占 546 MiB，
但真填上下文时 prefill 从 ~1500 t/s 崩到 **16 t/s**、功耗 297 W → **96 W**。
**NP 上限就是 3。**

### C4. 同一基准连跑两次差 2 倍以上

**真因**：llama.cpp 首次请求有 **~2.3× 预热惩罚**（实测 33.2 / 75.9 t/s）。
疑似按 batch 形状惰性捕获 CUDA graph（`graphs reused` 在 9~126 间波动）。

**修法**：**测速必须预热 ≥3 次**，否则会低估一倍。
生产上冷启动第一条慢是正常的，不是退化。

### C5. 辛辛苦苦做的对比实验结论不成立

**真因**：不同口径。

- `NP` 本身就影响单路速率（PTQ1_0 @200k：NP=3 是 1077.9，NP=2 是 943.3，**差 12%**）。
- `timings.prompt_n` 受前缀缓存影响 —— **要全量 prefill 必须 `cache_prompt: false`**。

**修法**：对比实验必须同 NP、同 cache 口径。

### C6. 长上下文测速时"请求立刻结束"

**真因**：裸 `/completion` 遇到重复的填充文本会立即 EOS。

**修法**：走 chat 接口；且 chat 接口默认开前缀缓存，
`timings.prompt_n` 只报新评估量，**要全量必须 `cache_prompt: false`**。

### C7. `gpu_memory_utilization` 写 0.94 起不来

**真因**：本机启动时可用显存只有 **22.45 / 23.99 GiB**
（约 1.54 GiB 被桌面/驱动常驻占用），所以上限 ≈ **0.936**。

报错：`Free memory on device ... is less than desired GPU memory utilization`。

**修法**：**别超过 0.93**。

### C8. vLLM-Bonsai 起不来/慢得像没开 GPU

四个必查项（都写在脚本头部）：

1. **没开 CUDA graph**：`--enforce-eager` 下只有 ~9 t/s，开了 7 倍到 ~70 t/s。
2. `--max-num-seqs` 超过可用 Mamba 块数 → 报
   `max_num_seqs (256) exceeds available Mamba cache blocks (170)`。混合 GDN 模型开图捕获有硬限制。
3. venv 自带 flashinfer 版本不匹配（cubin 0.6.13 vs 0.6.16）→ 启动直接 `RuntimeError`。
   用 `VLLM_USE_FLASHINFER_SAMPLER=0` 绕开。
4. 缺 `ninja`（torch 编译扩展）→ `Ninja is required to load C++ extensions`；
   venv 的 bin 要在 PATH 上，`CUDA_HOME` 指向 `/usr/local/cuda`。

## D. 网络与代理

### D1. Prometheus 抓本机报 `context deadline exceeded`

**真因**：Go http client **默认跟随环境变量代理**，抓 `127.0.0.1` 被代理拦了。
看着像端口不通，其实是走了代理。

**修法**：

```bash
export no_proxy="127.0.0.1,localhost,0.0.0.0${no_proxy:+,$no_proxy}"
export NO_PROXY="$no_proxy"
```

### D2. 主机 exporter 报 LHM 不可用（502）

**真因**：Windows 上 Python 的 urllib 默认走 **WinINet 代理**，访问 `127.0.0.1:8085` 被拦。

**修法**：显式禁用代理：

```python
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
```

### D3. 大文件下载互相抢带宽

**真因**：代理 `socks5h://192.168.0.10:20170` 是**全局带宽上限**（~2–9 MB/s），
并行下载互相抢；HF 直连不通。

**修法**：串行续传（`curl -C -` + 反复重试直到字节数达标）。
且**下载用的 tmux 会话会静默消失**，长下载要确认会话还在。

### D4. 9401 从 WSL 起不来

**真因**：WSL 常驻进程调 Windows 可执行文件会 `UtilAcceptVsock` 超时挂死
（实测 3 分钟只成功 1 次）。

**修法**：9401 **必须由 Windows 侧**启动。WSL 的 `start_monitoring.sh` 只做 `curl` 探测。

## E. 运维纪律

### E1. 黑窗闪烁

**真因**：计划任务每分钟新建一个进程，Windows 会先为它创建 conhost 控制台，
`-WindowStyle Hidden` 来不及拦。

**修法**：改成"**常驻单进程、只创建一次**"（`Start-Process -WindowStyle Hidden` 一次，
之后进程内部自己 sleep 循环）。

### E2. 守护进程把服务搞坏

`gpu_overcommit_guard.ps1 -EnableRestart` 会**主动打断在飞请求**来重启 vLLM ——
它不等空闲（等空闲可能永远等不到）。这是设计意图，不是 bug，但要知情。

在 Bonsai / vLLM-Bonsai 模式下它**必须停掉**，
否则会把 vLLM 拉回来和 Bonsai 抢同一张卡。

### E3. 排障时不要用 `cmd.exe`

PowerShell 工具里 `cmd.exe` 被安全策略拦截；Bash 里也不要调 powershell
（`Invoking PowerShell from Bash bypasses PowerShell security checks`）。
需要 PowerShell 就用 PowerShell 工具。

### E4. 安全护栏会劫持删除

本机 safe-delete 护栏会把 `rm` / `Remove-Item` / `shutil.rmtree` 劫持成回收站，
常失败/卡住。

**对策**：对"覆盖即可"的场景用 `ffmpeg -y` 这类幂等覆盖，
别"先删旧文件再写新"；脚本内部删临时文件失败就**忽略**（同名覆盖即生效）。

### E5. PowerShell 工具在本机不回传 stdout

调用只得到 "Command completed with exit code 0"，**看不到任何输出**。

**对策**：确需看输出时用 `Start-Transcript -Path <log> -Force` 落文件，
再用 Read 工具读。（Bash 工具的 stdout 正常回传。）

## F. 模型与推理质量

### F1. 评测结果不可信，一堆题被截断

**真因**：忘了关 thinking。约 10% 的题会撞 `max_tokens` 被截断。

**修法**：**测能力前必须关 thinking**，用 non-thinking + `temperature=0`。

### F2. 想知道投机解码到底有没有生效

看 API 响应里的 `timings.draft_n` / `draft_n_accepted`。
**`draft_n` 缺失或为 0 = 没生效。** 仪表盘上"每步草稿 token 数"也会是 0。

### F3. 图像没进模型

判定"图是否真进模型"用 **token 增量**（+66 = 64 图像 token + vision 起止符），
**别只看回答**。合成纯色/棋盘格图 ViT 会看错，不能当验收判据 ——
要用真实照片（如红苹果 + 黄香蕉 + 白盘）验证。
