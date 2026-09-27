#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LLM 实时输入输出瀑布流 —— 数据服务 + 网页

数据源：LiteLLM 写入 PostgreSQL 的 LiteLLM_SpendLogs 表
  输入 = proxy_server_request -> 'messages'（完整请求 body）
  输出 = response -> choices[0].message.content / reasoning_content

用法：
    python3 llm_trace_api.py            # 监听 9410
    python3 llm_trace_api.py --port 9410

端点：
    GET /                      瀑布流网页（自刷新）
    GET /api/trace?hours=6&limit=60&kw=xxx
    GET /api/stats             概览统计
"""
import argparse
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PG = {
    "host": "127.0.0.1",
    "port": "5432",
    "user": "litellm",
    "password": "litellm",
    "db": "litellm",
}
LOCAL_TZ_HOURS = 8  # 数据库存 UTC，展示用北京时间

# SQL 由 build_trace_sql() / build_stats_sql() 构造（见下方）
def psql(sql):
    env = {"PGPASSWORD": PG["password"], "PATH": "/usr/bin:/bin:/usr/local/bin"}
    cmd = [
        "psql", "-h", PG["host"], "-p", PG["port"], "-U", PG["user"], "-d", PG["db"],
        "-t", "-A", "-c", sql,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:500])
    return out.stdout.strip()


def q_trace(hours=6, limit=60, kw="", chars=3000):
    raw = psql(build_trace_sql(hours, limit, chars))
    try:
        rows = json.loads(raw) if raw else []
    except Exception:
        rows = []
    if kw:
        k = kw.lower()
        rows = [r for r in rows
                if k in (r.get("input_text") or "").lower()
                or k in (r.get("output_text") or "").lower()
                or k in (r.get("reasoning_text") or "").lower()
                or k in (r.get("model") or "").lower()]
    return rows


def build_trace_sql(hours, limit, chars):
    """最近的 LLM 请求/响应。

    - ``{tz}`` 仅用于把库里的 UTC 时间换算成北京时间（展示用），是常量 8
    - ``{h}``  是查询窗口小时数，两者不可混用
    - 输入取「最后一条消息 content 的最后一段 text」：
      Claude Code 会把整段 transcript 塞进 content 数组的前面几个元素，
      真正的新增输入永远在最后一个元素里
    """
    return r"""
SELECT coalesce(json_agg(t), '[]'::json) FROM (
  SELECT
    to_char(("startTime" + interval '{tz} hours'), 'YYYY-MM-DD HH24:MI:SS') AS ts,
    request_id,
    coalesce(nullif(model_group, ''), model, '')                            AS model,
    coalesce(prompt_tokens, 0)                                              AS in_tok,
    coalesce(completion_tokens, 0)                                          AS out_tok,
    coalesce("request_duration_ms", 0)                                      AS dur_ms,
    CASE WHEN "completionStartTime" IS NULL THEN 0
         ELSE greatest((extract(epoch from ("completionStartTime" - "startTime")) * 1000)::int, 0)
    END                                                                     AS ttft_ms,
    CASE WHEN "completionStartTime" IS NULL OR "endTime" IS NULL THEN 0
         ELSE greatest((extract(epoch from ("endTime" - "completionStartTime")) * 1000)::int, 0)
    END                                                                     AS decode_ms,
    coalesce(status, '')                                                    AS status,
    left(coalesce(c.txt, ''), {c})                                          AS input_text,
    left(coalesce(
           nullif(response #>> '{{choices,0,message,content}}', ''),
           ''), {c})                                                   AS output_text,
    left(coalesce(response #>> '{{choices,0,message,reasoning_content}}', ''), 4000) AS reasoning_text
  FROM "LiteLLM_SpendLogs"
  LEFT JOIN LATERAL (
    SELECT CASE
      WHEN jsonb_typeof(proxy_server_request -> 'messages') = 'array'
           AND jsonb_array_length(proxy_server_request -> 'messages') > 0
      THEN proxy_server_request -> 'messages' ->
           (jsonb_array_length(proxy_server_request -> 'messages') - 1)
      ELSE NULL END AS msg
  ) m ON true
  LEFT JOIN LATERAL (
    SELECT CASE
      WHEN m.msg IS NULL THEN NULL
      WHEN jsonb_typeof(m.msg -> 'content') = 'array'
           AND jsonb_array_length(m.msg -> 'content') > 0
      THEN coalesce(
             (m.msg -> 'content' -> (jsonb_array_length(m.msg -> 'content') - 1)) ->> 'text',
             (m.msg -> 'content' -> (jsonb_array_length(m.msg -> 'content') - 1)) ->> 'content',
             (m.msg -> 'content' -> (jsonb_array_length(m.msg -> 'content') - 1))::text)
      ELSE coalesce(m.msg ->> 'content', (m.msg -> 'content')::text)
    END AS txt
  ) c ON true
  WHERE ("startTime" + interval '{tz} hours') > (now() at time zone 'utc') - interval '{h} hours'
    AND length(coalesce(response::text, '')) > 20
  ORDER BY "startTime" DESC
  LIMIT {n}
) t
""".format(tz=LOCAL_TZ_HOURS, h=int(hours), c=int(chars), n=int(limit))


def build_stats_sql(hours):
    return r"""
SELECT row_to_json(t) FROM (
  SELECT
    (SELECT count(*) FROM "LiteLLM_SpendLogs"
      WHERE "startTime" > (now() at time zone 'utc') - interval '{h} hours') AS cnt_window,
    (SELECT count(*) FROM "LiteLLM_SpendLogs")                                  AS cnt_total,
    (SELECT count(*) FROM "LiteLLM_SpendLogs" WHERE length(coalesce(response::text,'')) > 20) AS cnt_with_content,
    (SELECT coalesce(sum(prompt_tokens),0) FROM "LiteLLM_SpendLogs"
      WHERE "startTime" > (now() at time zone 'utc') - interval '{h} hours') AS tok_in,
    (SELECT coalesce(sum(completion_tokens),0) FROM "LiteLLM_SpendLogs"
      WHERE "startTime" > (now() at time zone 'utc') - interval '{h} hours') AS tok_out,
    (SELECT pg_size_pretty(pg_total_relation_size('"LiteLLM_SpendLogs"')))      AS table_size,
    (SELECT to_char(max("startTime" + interval '{tz} hours'), 'YYYY-MM-DD HH24:MI:SS')
       FROM "LiteLLM_SpendLogs")                                               AS last_at
) t
""".format(tz=LOCAL_TZ_HOURS, h=int(hours))


def q_stats(hours=6):
    raw = psql(build_stats_sql(hours))
    try:
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


# ------------------------------------------------------------------ HTML
HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LLM 实时输入输出 · 瀑布流</title>
<style>
  :root{
    --bg:#f6f7f9; --card:#fff; --bd:#e3e6ea; --tx:#1f2328; --muted:#6b7280;
    --in-bg:#eef4ff; --in-bd:#b9d0ff; --out-bg:#eefaf1; --out-bd:#a9dfbe;
    --think-bg:#fdf6e3; --think-bd:#e8d9a8; --accent:#2f6feb;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--tx);
       font:14px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",Roboto,sans-serif}
  header{position:sticky;top:0;z-index:10;background:#fff;border-bottom:1px solid var(--bd);
         padding:10px 16px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
  h1{font-size:16px;margin:0 8px 0 0;font-weight:600}
  .ctl{display:flex;gap:6px;align-items:center;font-size:13px;color:var(--muted)}
  select,input[type=text]{padding:5px 8px;border:1px solid var(--bd);border-radius:6px;
                         background:#fff;font-size:13px;color:var(--tx)}
  input[type=text]{min-width:180px}
  button{padding:5px 12px;border:1px solid var(--bd);border-radius:6px;background:#fff;
         cursor:pointer;font-size:13px}
  button:hover{background:#f0f2f5}
  button.on{background:var(--accent);color:#fff;border-color:var(--accent)}
  .spacer{flex:1}
  .stats{font-size:12px;color:var(--muted)}
  main{padding:14px 16px 60px;max-width:1400px;margin:0 auto}
  .item{background:var(--card);border:1px solid var(--bd);border-radius:10px;
        padding:12px 14px;margin-bottom:12px;animation:fade .35s ease}
  @keyframes fade{from{opacity:0;transform:translateY(-6px)}to{opacity:1;transform:none}}
  .meta{display:flex;gap:10px;align-items:center;flex-wrap:wrap;
        font-size:12px;color:var(--muted);margin-bottom:8px}
  .tag{background:#f0f2f5;border-radius:4px;padding:1px 7px;font-size:11px;color:#444}
  .tag.model{background:#eaf1ff;color:#1d4ed8}
  .tag.in{background:#eef4ff;color:#1e40af}
  .tag.out{background:#eefaf1;color:#166534}
  .rid{font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#9aa3af}
  .box{border-left:3px solid var(--in-bd);background:var(--in-bg);
       border-radius:0 6px 6px 0;padding:8px 10px;margin-bottom:6px;white-space:pre-wrap;
       word-break:break-word;font-family:ui-monospace,Consolas,"Cascadia Code",monospace;font-size:12.5px}
  .box.out{border-left-color:var(--out-bd);background:var(--out-bg)}
  .box.think{border-left-color:var(--think-bd);background:var(--think-bg);color:#6b5a1f;font-size:12px}
  .lbl{font-size:11px;font-weight:600;color:var(--muted);display:block;margin-bottom:3px;
       font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
  details summary{cursor:pointer;font-size:11px;color:var(--muted);user-select:none;margin-top:2px}
  .empty{text-align:center;color:var(--muted);padding:60px 0}
  .new-badge{background:#dcfce7;color:#166534;border-radius:10px;padding:0 6px;font-size:11px}
</style>
</head>
<body>
<header>
  <h1>LLM 实时输入输出 · 瀑布流</h1>
  <div class="ctl">窗口
    <select id="hours">
      <option value="1">近 1 小时</option>
      <option value="6" selected>近 6 小时</option>
      <option value="24">近 24 小时</option>
      <option value="72">近 3 天</option>
    </select>
  </div>
  <div class="ctl">刷新
    <select id="every">
      <option value="0">关闭</option>
      <option value="3">3 秒</option>
      <option value="5" selected>5 秒</option>
      <option value="15">15 秒</option>
      <option value="60">60 秒</option>
    </select>
  </div>
  <div class="ctl"><input type="text" id="kw" placeholder="关键词过滤…"></div>
  <button id="refresh">立即刷新</button>
  <button id="autoscroll" class="on">自动置顶</button>
  <button id="thinktoggle" class="on">思考过程：展开</button>
  <div class="spacer"></div>
  <div class="stats" id="stats">—</div>
</header>
<main id="list"><div class="empty">加载中…</div></main>
<script>
const $ = s => document.querySelector(s);
let seen = new Set(), timer = null;
let thinkOpen = true;   // 思考过程默认展开

function esc(s){return String(s==null?'':s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}

function card(r){
  const isNew = !seen.has(r.request_id);
  seen.add(r.request_id);
  const secs = (r.dur_ms||0)/1000;
  const ttft = (r.ttft_ms||0)/1000;
  // 解码速度必须只除以「纯解码时长」，不能除以总时长（后者含 prefill，
  // 长 prompt 时会把速度低估几十倍）。decode_ms 为 0 时退回总时长。
  const decMs = (r.decode_ms||0) > 0 ? r.decode_ms : (r.dur_ms||0);
  const tps = decMs > 0 ? (r.out_tok||0)/(decMs/1000) : 0;
  const e2e = secs > 0 ? (r.out_tok||0)/secs : 0;
  const think = (r.reasoning_text||'').trim();
  const out   = (r.output_text||'').trim();
  return `<div class="item">
    <div class="meta">
      <span class="tag">${esc(r.ts)}</span>
      <span class="tag model">${esc(r.model)}</span>
      <span class="tag in">输入 ${r.in_tok}</span>
      <span class="tag out">输出 ${r.out_tok}</span>
      <span class="tag">${secs.toFixed(1)}s</span>
      <span class="tag out" title="输出 token / 纯解码时长（不含 prefill）">解码 ${tps.toFixed(1)} tok/s</span>
      ${ttft > 0 ? `<span class="tag" title="首 token 延迟 = completionStartTime - startTime">TTFT ${ttft.toFixed(1)}s</span>` : ''}
      ${secs > 0 ? `<span class="tag" title="输出 token / 总时长（含 prefill，仅供参考）">端到端 ${e2e.toFixed(1)} tok/s</span>` : ''}
      ${isNew && seen.size>1 ? '<span class="new-badge">NEW</span>' : ''}
      <span class="rid">${esc((r.request_id||'').slice(0,28))}</span>
    </div>
    ${think ? `<details${thinkOpen?' open':''}><summary>思考过程（${think.length} 字）</summary>
       <div class="box think">${esc(think)}</div></details>` : ''}
    <div class="box"><span class="lbl">输入（最后一条消息）</span>${esc(r.input_text||'(空)')}</div>
    <div class="box out"><span class="lbl">输出</span>${esc(out || (think ? '(正文为空 — 内容见上方思考过程)' : '(空)'))}</div>
  </div>`;
}

async function load(){
  const hours = $('#hours').value, kw = $('#kw').value.trim();
  try{
    const [rows, st] = await Promise.all([
      fetch('/api/trace?hours='+hours+'&limit=80&kw='+encodeURIComponent(kw)).then(r=>r.json()),
      fetch('/api/stats?hours='+hours).then(r=>r.json()).catch(()=>({}))
    ]);
    if(!rows.length){
      $('#list').innerHTML = '<div class="empty">该时间窗内没有记录。<br>确认 litellm 已开启 store_prompts_in_spend_logs，且窗口内有实际请求。</div>';
    }else{
      $('#list').innerHTML = rows.map(card).join('');
    }
    $('#stats').textContent = `窗口请求 ${st.cnt_window||0} · 含内容 ${st.cnt_with_content||0} · 输入 ${(st.tok_in||0).toLocaleString()} tok · 输出 ${(st.tok_out||0).toLocaleString()} tok · 表 ${st.table_size||'-'} · 最后 ${st.last_at||'-'}`;
    if($('#autoscroll').classList.contains('on')) window.scrollTo({top:0,behavior:'smooth'});
  }catch(e){
    $('#list').innerHTML = '<div class="empty">加载失败：'+esc(e.message)+'</div>';
  }
}

function schedule(){
  clearInterval(timer);
  const s = parseInt($('#every').value,10);
  if(s>0) timer = setInterval(load, s*1000);
}

$('#hours').onchange = load;
$('#refresh').onclick = load;
$('#every').onchange = schedule;
$('#autoscroll').onclick = e => e.target.classList.toggle('on');
$('#thinktoggle').onclick = e => {
  const on = e.target.classList.toggle('on');
  thinkOpen = on;
  e.target.textContent = '思考过程：' + (on ? '展开' : '折叠');
  load();
};
let t; $('#kw').oninput = () => { clearTimeout(t); t = setTimeout(load, 400); };
load(); schedule();
</script>
</body>
</html>
"""


# ------------------------------------------------------------------ HTTP
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        b = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        try:
            if u.path == "/" or u.path == "/index.html":
                self._send(200, HTML, "text/html; charset=utf-8")
            elif u.path == "/api/trace":
                rows = q_trace(
                    hours=int(qs.get("hours", ["6"])[0]),
                    limit=int(qs.get("limit", ["60"])[0]),
                    kw=qs.get("kw", [""])[0],
                    chars=int(qs.get("chars", ["3000"])[0]),
                )
                self._send(200, json.dumps(rows, ensure_ascii=False), "application/json; charset=utf-8")
            elif u.path == "/api/stats":
                st = q_stats(hours=int(qs.get("hours", ["6"])[0]))
                self._send(200, json.dumps(st, ensure_ascii=False), "application/json; charset=utf-8")
            elif u.path == "/healthz":
                self._send(200, "ok", "text/plain")
            else:
                self._send(404, "not found", "text/plain")
        except Exception as e:  # noqa
            self._send(500, "ERROR: %s" % e, "text/plain; charset=utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9410)
    ap.add_argument("--test", action="store_true")
    a = ap.parse_args()
    if a.test:
        t0 = time.time()
        rows = q_trace(hours=24, limit=5)
        print("rows=%d  elapsed=%.2fs" % (len(rows), time.time() - t0))
        for r in rows:
            print("-" * 80)
            print(r["ts"], "|", r["model"], "| in", r["in_tok"], "out", r["out_tok"], "|", r["dur_ms"], "ms")
            print("  IN :", (r["input_text"] or "")[:200].replace("\n", " "))
            print("  OUT:", (r["output_text"] or "")[:200].replace("\n", " "))
        print("stats:", q_stats(24))
        return
    HTTPServer(("0.0.0.0", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
