@echo off
REM ============================================================
REM  start_all.bat -- One-Click Start for the whole local LLM stack
REM
REM   Windows side : LibreHardwareMonitor (8085, real CPU temp)
REM                  host metrics exporter (9401, CPU/temp/RAM/disk)
REM   WSL side     : PostgreSQL(5432) + model backend(18020, see -Backend)
REM                  + litellm(1234) + Prometheus(9090) + Grafana(3000)
REM                  + GPU exporter(9400) + LLM waterfall(9410)
REM
REM   USAGE: double-click this file.  Admin NOT required.
REM          (LHM may raise a UAC prompt separately)
REM   ARGS : -Backend  bonsai (DEFAULT) | vllm-bonsai | vllm
REM            vllm-bonsai = vLLM + prism_ternary plugin running Bonsai 2 27B
REM                          PTQ1_0 -- FINAL CONFIG (non-default). port 18020, alias
REM                          qwen3.8-27b (so litellm needs no change),
REM                          max_model_len 262144, KV fp8, max_num_seqs 128,
REM                          tool calling ON (--tool-call-parser qwen3_xml),
REM                          CUDA graphs ON (7x faster than --enforce-eager).
REM                          Measured: 86.8 tok/s @short, 74.1 @33k,
REM                          32-way aggregate 1027 tok/s, 88.2% on 280 tasks.
REM                          (the VRAM guard is stopped automatically)
REM            bonsai      = PrismML llama.cpp fork + the SAME Bonsai 2 27B
REM                          ternary 2-bit GGUF. port 18020, 262144 ctx per
REM                          slot, NP=3, KV q4_0
REM                          (the VRAM guard is stopped automatically)
REM            vllm        = original Qwen3.8-27B-W4A16 + DFlash2, 200k ctx
REM          -Open     open browser (default: browser is NOT opened)
REM          -SkipWsl  only start the Windows side (9401 / 8085)
REM          -NoGuard  skip ensuring the VRAM-overcommit guard task
REM
REM   EXAMPLES:
REM          start_all.bat                        -> llama.cpp + Bonsai (default)
REM          start_all.bat -Backend vllm-bonsai   -> vLLM + Bonsai
REM          start_all.bat -Backend bonsai        -> llama.cpp + Bonsai
REM          start_all.bat -Backend vllm          -> back to the W4A16 vLLM
REM          start_all.bat -Open                  -> default + open browser
REM
REM   GUARD: (vllm backend only) step [4/5] ensures a guard that restarts vLLM
REM          when it detects any of:
REM            (a) VRAM overcommit (committed/physical >= 99.5%)
REM            (b) WSL loopback entry failure (port listens, 127.0.0.1 dead)
REM            (c) engine stalled (requests running but zero token progress)
REM          3 consecutive hits = 30 s of abnormal -> restart. All three are
REM          silent in the logs and only recoverable by restarting vLLM;
REM          overcommit makes inference drop from ~80 tok/s to <1 tok/s.
REM          Do NOT wait for idle - it WILL interrupt in-flight requests.
REM          Disable: schtasks /Delete /TN GPU_VRAM_Overcommit_Guard /F
REM          NOTE: with -Backend bonsai the vLLM guard is stopped on purpose --
REM          it would pull vLLM back and fight Bonsai for the same 24 GB.
REM          Instead step [4/5] starts bonsai_guard.ps1, which does one thing:
REM          if the stack is down AND VRAM is essentially empty
REM          (nvidia-smi memory.used <= 1000 MiB), start it again through the
REM          WSL script. If VRAM is still held it only logs and waits --
REM          starting anyway would land in WDDM VRAM overcommit: it loads,
REM          logs no error, then prefill collapses from 1500 to 16 t/s at 96 W.
REM          Health = :18020 /health returns 200 AND :1234 reachable.
REM          4 misses in a row (~60 s) = act. Cooldown 10 min, max 3 per hour.
REM          Log : monitoring_cfg\bonsai_guard.log
REM          Pause: create an empty file monitoring_cfg\bonsai_guard.pause
REM          Optional: bonsai_guard.ps1 -CleanStale (untested) also kills
REM          leftover WSL llama-server/vllm when VRAM is held by an idle GPU.
REM   WSL MOUNT: if the WSL utility VM has been up for many hours and only the
REM          distro was restarted by itself, drvfs can silently fail to mount:
REM          /mnt/c /mnt/d /mnt/e become EMPTY dirs and WSL sees no Windows
REM          files at all. Kernel log shows:
REM            WSL (2 - init-systemd(Ubuntu)) ERROR: ConfigRemountDrvFsImpl:2256:
REM            Non-Admin namespace already initialized
REM          Symptoms: a wall of "Failed to translate 'C:\...'" from wsl.exe,
REM          then the WSL script dies with 127 (No such file or directory).
REM          Beware: systemd-launched services (e.g. PostgreSQL) stay alive,
REM          so "5432 is up" does NOT mean WSL is healthy.
REM          Fix: `wsl --shutdown` (rebuilds the whole VM). Restarting just the
REM          distro is NOT enough. start_all.ps1 now detects this at step [1/5]
REM          and runs wsl --shutdown automatically.
REM   WSL BLOCK: if wsl.exe is listed in Security Center > Command Security >
REM          Program Blacklist, NOTHING can start the WSL side -- neither this
REM          script nor any run started from the editor. Step [1/5] now reports
REM          it explicitly instead of the misleading "distro not available".
REM          Fix: remove wsl.exe from that blacklist.
REM          Note: WSL itself keeps running -- vmmemWSL / wslservice stay alive,
REM          so a service started earlier may still answer on its port. That is
REM          why "-SkipWsl" runs can look half-working.
REM   STOP : double-click stop_all.bat
REM
REM   NOTE : the three backends cannot coexist on one 24 GB GPU -- they all
REM          claim port 18020 (WSL side). Whichever backend is selected, the
REM          served alias is qwen3.8-27b, so litellm_config.yaml needs no
REM          change at all.
REM          vllm-bonsai / bonsai also serve on 18020 but with different
REM          engines (vLLM vs llama.cpp). The WSL start script detects a
REM          mismatched engine on 18020 and restarts it with the right one,
REM          so switching backends is just this one command.
REM ============================================================
chcp 65001 >nul
title GPU + LLM One-Click Start (Windows -^> WSL)
cd /d "%~dp0"

echo Launching start_all.ps1 from Windows side...
REM Default (no args) = llama.cpp Bonsai M4 (the 14:15 scheme, start_all.ps1
REM default also set to -Backend bonsai, so they stay in sync):
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_all.ps1" -Backend bonsai
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_all.ps1" %*
)

echo.
pause
