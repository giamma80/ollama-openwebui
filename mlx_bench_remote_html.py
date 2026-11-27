#!/usr/bin/env python3
"""
Benchmark remoto (eseguito da client verso server mlx_lm.server).
Misura TTFT, throughput (tok/s), token e fedelta strutturale via SSE,
e genera un report HTML autonomo visualizzabile nel browser.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import platform
import re
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
DEFAULT_BASE_URL = "http://192.168.1.77:8081"
DEFAULT_MAX_TOKENS = 768
DEFAULT_TEMPERATURE = 0.2
DEFAULT_TIMEOUT = 240

SYSTEM_PROMPTS: dict[str, str] = {
    "BA": (
        "Sei un Business Analyst senior. Rispondi in italiano in modo sintetico, strutturato e fattuale, senza preamboli. "
        "Per ogni analisi o requisito copri: attori, flussi principali, regole di business, dipendenze/vincoli, rischi e metriche/KPI. "
        "Separa sempre fatti certi, assunzioni esplicite e open questions. Non inventare dati, costi o metriche assenti dal contesto. "
        "Se mancano informazioni critiche, elenca solo le domande essenziali. "
        "Usa tabelle Markdown o elenchi puntati compatti; per eventuali diagrammi Mermaid usa blocchi ```mermaid "
        'con etichette tra virgolette doppie ("...").'
    ),
    "SA": (
        "Sei un Software Architect senior. Rispondi in italiano in modo diretto, pragmatico e orientato alle decisioni, senza preamboli. "
        "Per ogni architettura o scelta tecnica copri: componenti e responsabilita, flussi/interfacce/contratti, trade-off e compromessi, "
        "vincoli (latenza, memoria, sicurezza, manutenibilita) e rischi operativi. "
        "Distingui chiaramente decisioni consigliate, alternative scartate e assunzioni. Non inventare SLA, librerie o integrazioni non indicate. "
        "Usa elenchi puntati, tabelle o schemi testuali essenziali; per eventuali diagrammi Mermaid usa blocchi ```mermaid "
        'con etichette tra virgolette doppie ("...").'
    ),
}

TEST_CASES: list[dict[str, str]] = [
    {
        "id": "ba_onboarding_pmi",
        "role": "BA",
        "title": "Onboarding digitale PMI con retry su verifica",
        "prompt": (
            "Analizza questo flusso di onboarding digitale per PMI:\n"
            "1. L'utente inserisce P.IVA e dati anagrafici sul portale web.\n"
            "2. Il sistema verifica i dati tramite servizio esterno e invia un OTP via SMS.\n"
            "3. Se la verifica supera i 5 secondi o il servizio non e disponibile, il flusso va in coda di retry.\n"
            "4. A verifica OK, viene generato il contratto e inviato alla firma digitale.\n"
            "Definisci requisiti funzionali, regole di business, rischi e punti aperti."
        ),
    },
    {
        "id": "ba_egm_price_sensitive",
        "role": "BA",
        "title": "Sintesi comunicati price sensitive pre/post IPO",
        "prompt": (
            "Definisci i requisiti di un modulo per tracciare comunicati price sensitive su societa quotate o in percorso di quotazione:\n"
            "- Acquisisce comunicati da fonti ufficiali e news.\n"
            "- Collega ogni comunicato alla data di evento e al contesto pre/post quotazione.\n"
            "- Produce uno snapshot sintetico con fonte citata.\n"
            "Evidenzia attori, flussi, vincoli, rischi e metriche/KPI senza inventare numeri o SLA."
        ),
    },
    {
        "id": "sa_ingest_pipeline",
        "role": "SA",
        "title": "Pipeline ingestione documenti e calcolo indicatori",
        "prompt": (
            "Progetta l'architettura di un servizio di ingestione documenti finanziari e calcolo indicatori:\n"
            "- Riceve documenti via webhook/batch, li normalizza e li salva.\n"
            "- Espone API REST per interrogare lo stato di elaborazione e gli indicatori calcolati.\n"
            "- Deve essere tracciabile, manutenibile e tollerante ai fallimenti temporanei dei parser.\n"
            "Indica componenti, interfacce, trade-off, alternative scartate e rischi operativi."
        ),
    },
    {
        "id": "sa_gateway_routing",
        "role": "SA",
        "title": "Gateway locale/cloud con fallback e controllo memoria",
        "prompt": (
            "Definisci l'architettura di un gateway locale per instradare richieste verso un motore di inferenza locale "
            "su nodo con memoria limitata e, solo quando necessario o non disponibile in locale, verso un endpoint esterno:\n"
            "- Gestisce timeout, errori di memoria/esecuzione del runtime locale e log delle metriche.\n"
            "- Mantiene separati configurazione, routing e osservabilita.\n"
            "Copri componenti, flussi, compromessi, vincoli e assunzioni."
        ),
    },
]


def evaluate_fidelity(role: str, response_text: str, prompt_text: str) -> dict[str, Any]:
    low = response_text.lower()
    expected_terms = {
        "BA": ["attor", "fluss", "regol", "vincol", "rischi", "kpi", "assunzion", "open"],
        "SA": ["component", "fluss", "trade-off", "vincol", "rischi", "decision", "assunzion"],
    }[role]

    matched = [term for term in expected_terms if term in low]
    coverage = round(len(matched) / len(expected_terms), 2)

    has_comma_dup = bool(re.search(r"\b(\w+),\s*\1\b", response_text))
    has_word_spam = bool(re.search(r"\b(\w{2,})\b(?:\s+\1\b){3,}", low))
    has_loop = has_comma_dup or has_word_spam

    invented_pct: list[str] = []
    for pct in re.findall(r"\b\d+(?:[.,]\d+)?\s*%", response_text):
        if pct not in prompt_text:
            invented_pct.append(pct)

    score = 5
    if has_loop:
        score -= 2
    if coverage < 0.5:
        score -= 1
    if len(invented_pct) >= 3:
        score -= 1
    if len(response_text.strip()) < 80:
        score -= 1
    score = max(1, min(5, score))

    return {
        "section_coverage": coverage,
        "matched_sections": matched,
        "has_repetition_loop": has_loop,
        "invented_percentages": invented_pct[:8],
        "auto_fidelity_1_5": score,
    }


def wait_for_server(base_url: str, timeout_s: int = 15) -> bool:
    deadline = time.perf_counter() + timeout_s
    models_url = f"{base_url.rstrip('/')}/v1/models"
    while time.perf_counter() < deadline:
        try:
            with urllib.request.urlopen(models_url, timeout=3) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(1.0)
    return False


def run_completion_stream(
    base_url: str,
    model: str,
    role: str,
    system_prompt: str,
    user_prompt: str,
    max_tokens: int,
    temperature: float,
    timeout_s: int,
) -> dict[str, Any]:
    endpoint = f"{base_url.rstrip('/')}/v1/chat/completions"
    payload = {
        "model": model,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    t_start = time.perf_counter()
    t_first_token: float | None = None
    chunks: list[str] = []
    usage: dict[str, Any] = {}
    error_msg: str | None = None

    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data_part = line[5:].strip()
                if data_part == "[DONE]":
                    break
                try:
                    obj = json.loads(data_part)
                except json.JSONDecodeError:
                    continue

                if isinstance(obj.get("usage"), dict) and obj["usage"]:
                    usage = obj["usage"]

                choices = obj.get("choices") or []
                if choices and isinstance(choices[0], dict):
                    delta = choices[0].get("delta") or {}
                    content = delta.get("content")
                    if content:
                        if t_first_token is None:
                            t_first_token = time.perf_counter()
                        chunks.append(content)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        error_msg = f"HTTP {e.code}: {body[:400]}"
    except Exception as e:
        error_msg = str(e)

    t_end = time.perf_counter()
    full_text = "".join(chunks)

    total_s = max(t_end - t_start, 1e-6)
    ttft_s = (t_first_token - t_start) if t_first_token is not None else total_s
    decode_s = max((t_end - t_first_token), 1e-6) if t_first_token is not None else total_s

    prompt_tokens = int(usage.get("prompt_tokens") or -1)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    if completion_tokens <= 0 and full_text:
        completion_tokens = max(1, len(full_text) // 4)

    total_tokens = int(usage.get("total_tokens") or (max(0, prompt_tokens) + completion_tokens))
    tokens_per_sec = (completion_tokens / decode_s) if completion_tokens > 0 else 0.0

    fidelity = evaluate_fidelity(role=role, response_text=full_text, prompt_text=user_prompt)

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ttft_s": round(ttft_s, 3),
        "total_s": round(total_s, 3),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "tokens_per_sec": round(tokens_per_sec, 2),
        "section_coverage": fidelity["section_coverage"],
        "has_repetition_loop": fidelity["has_repetition_loop"],
        "invented_percentages": fidelity["invented_percentages"],
        "auto_fidelity_1_5": fidelity["auto_fidelity_1_5"],
        "response_text": full_text,
        "error": error_msg,
    }


def save_csv(results: list[dict[str, Any]], csv_path: Path) -> None:
    if not results:
        return
    fieldnames = [
        "timestamp",
        "client_host",
        "server_target",
        "model",
        "case_id",
        "role",
        "title",
        "status",
        "ttft_s",
        "total_s",
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
        "tokens_per_sec",
        "section_coverage",
        "has_repetition_loop",
        "auto_fidelity_1_5",
        "error",
    ]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(results)


def build_html_report(
    results: list[dict[str, Any]],
    model_name: str,
    base_url: str,
    client_host: str,
    server_label: str,
) -> str:
    ok_rows = [r for r in results if not r.get("error")]
    avg_ttft = round(sum(r["ttft_s"] for r in ok_rows) / len(ok_rows), 3) if ok_rows else 0.0
    avg_tps = round(sum(r["tokens_per_sec"] for r in ok_rows) / len(ok_rows), 2) if ok_rows else 0.0
    avg_fid = round(sum(r["auto_fidelity_1_5"] for r in ok_rows) / len(ok_rows), 2) if ok_rows else 0.0
    total_comp = sum(r["completion_tokens"] for r in ok_rows)

    max_tps = max([r["tokens_per_sec"] for r in ok_rows] + [1.0])
    svg_bars: list[str] = []
    y_pos = 24
    for r in results:
        tps = r["tokens_per_sec"] if not r.get("error") else 0.0
        bar_w = int((tps / max_tps) * 360)
        label = html.escape(f"{r['role']} · {r['case_id']}")
        color = "#2563eb" if r["role"] == "BA" else "#059669"
        if r.get("error"):
            color = "#dc2626"
        svg_bars.append(
            f'<text x="8" y="{y_pos + 14}" font-size="12" fill="#1e293b">{label}</text>'
            f'<rect x="230" y="{y_pos}" width="{max(bar_w, 2)}" height="20" rx="4" fill="{color}"/>'
            f'<text x="{238 + max(bar_w, 2)}" y="{y_pos + 14}" font-size="12" fill="#0f172a">{tps:.2f} tok/s (TTFT {r["ttft_s"]:.2f}s)</text>'
        )
        y_pos += 32

    svg_height = max(60, y_pos + 12)
    svg_chart = (
        f'<svg width="100%" viewBox="0 0 680 {svg_height}" style="max-width:760px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;">'
        + "".join(svg_bars)
        + "</svg>"
    )

    table_rows: list[str] = []
    cards_html: list[str] = []
    for idx, r in enumerate(results):
        status_badge = '<span class="badge ok">OK</span>' if not r.get("error") else '<span class="badge err">ERR</span>'
        loop_flag = "SI" if r["has_repetition_loop"] else "No"
        inv_pct = ", ".join(r["invented_percentages"]) if r["invented_percentages"] else "-"
        row_html = f"""
        <tr data-role="{html.escape(r['role'])}">
          <td>{html.escape(r['role'])}</td>
          <td><strong>{html.escape(r['case_id'])}</strong><br><small>{html.escape(r['title'])}</small></td>
          <td>{status_badge}</td>
          <td>{r['ttft_s']:.3f}s</td>
          <td>{r['total_s']:.3f}s</td>
          <td>{r['prompt_tokens']} / {r['completion_tokens']}</td>
          <td><strong>{r['tokens_per_sec']:.2f}</strong></td>
          <td>{int(r['section_coverage']*100)}%</td>
          <td>{loop_flag}</td>
          <td>
            <select class="fid-select" data-idx="{idx}" onchange="recalcFidelity()">
              {"".join(f'<option value="{v}" {"selected" if v == r["auto_fidelity_1_5"] else ""}>{v}/5</option>' for v in range(1, 6))}
            </select>
          </td>
        </tr>
        """
        table_rows.append(row_html)

        prompt_escaped = html.escape(r["prompt_text"])
        sys_escaped = html.escape(r["system_prompt_text"])
        body_escaped = html.escape(r["response_text"] or r.get("error") or "")
        card_html = f"""
        <details class="card" data-role="{html.escape(r['role'])}" {"open" if idx == 0 else ""}>
          <summary>
            <span class="pill">{html.escape(r['role'])}</span>
            <strong>{html.escape(r['case_id'])}</strong> — {html.escape(r['title'])}
            <span class="meta-inline">TTFT: {r['ttft_s']:.2f}s · {r['tokens_per_sec']:.2f} tok/s · Copertura: {int(r['section_coverage']*100)}%</span>
          </summary>
          <div class="card-body">
            <div class="subgrid">
              <div><strong>% non presenti nel prompt:</strong> {html.escape(inv_pct)}</div>
              <div><strong>Loop rilevato:</strong> {loop_flag}</div>
              <div><strong>Errore:</strong> {html.escape(r.get("error") or "-")}</div>
            </div>
            <details><summary>System Prompt</summary><pre>{sys_escaped}</pre></details>
            <details><summary>User Prompt</summary><pre>{prompt_escaped}</pre></details>
            <div class="resp-box">
              <div class="resp-title">Risposta modello</div>
              <pre class="resp-pre">{body_escaped}</pre>
            </div>
          </div>
        </details>
        """
        cards_html.append(card_html)

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"""<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<title>Benchmark Remoto MLX — {html.escape(model_name)}</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 24px; background: #ffffff; color: #0f172a; line-height: 1.45; }}
  h1 {{ margin: 0 0 6px 0; font-size: 22px; }}
  .sub {{ color: #475569; font-size: 13px; margin-bottom: 20px; }}
  .kpis {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 22px; }}
  .kpi {{ border: 1px solid #e2e8f0; border-radius: 8px; padding: 14px; background: #f8fafc; }}
  .kpi .lbl {{ font-size: 11px; text-transform: uppercase; color: #64748b; letter-spacing: .04em; }}
  .kpi .val {{ font-size: 22px; font-weight: 700; margin-top: 4px; }}
  .controls {{ margin: 16px 0; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }}
  button {{ padding: 6px 12px; border: 1px solid #cbd5e1; border-radius: 6px; background: #fff; cursor: pointer; font-size: 13px; }}
  button.active {{ background: #0f172a; color: #fff; border-color: #0f172a; }}
  table {{ width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 13px; }}
  th, td {{ border-bottom: 1px solid #e2e8f0; padding: 8px 10px; text-align: left; vertical-align: top; }}
  th {{ background: #f1f5f9; font-weight: 600; }}
  .badge {{ padding: 2px 7px; border-radius: 999px; font-size: 11px; font-weight: 600; }}
  .badge.ok {{ background: #dcfce7; color: #166534; }}
  .badge.err {{ background: #fee2e2; color: #991b1b; }}
  .card {{ border: 1px solid #e2e8f0; border-radius: 8px; margin-top: 12px; background: #fff; }}
  .card > summary {{ padding: 12px 14px; cursor: pointer; font-size: 14px; background: #f8fafc; border-radius: 8px; }}
  .pill {{ background: #e2e8f0; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; margin-right: 6px; }}
  .meta-inline {{ float: right; color: #475569; font-size: 12px; }}
  .card-body {{ padding: 14px; }}
  .subgrid {{ display: flex; gap: 20px; flex-wrap: wrap; font-size: 12px; color: #334155; margin-bottom: 10px; }}
  pre {{ background: #0f172a; color: #f8fafc; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 12px; white-space: pre-wrap; word-break: break-word; }}
  .resp-box {{ margin-top: 12px; }}
  .resp-title {{ font-weight: 600; font-size: 13px; margin-bottom: 6px; }}
</style>
</head>
<body>
  <h1>Report Benchmark Remoto MLX</h1>
  <div class="sub">
    Modello: <strong>{html.escape(model_name)}</strong> · Server: <code>{html.escape(base_url)}</code> ({html.escape(server_label)}) · Client: <code>{html.escape(client_host)}</code> · Generato: {html.escape(generated_at)}
  </div>

  <div class="kpis">
    <div class="kpi"><div class="lbl">TTFT Medio (incl. rete)</div><div class="val">{avg_ttft:.3f}s</div></div>
    <div class="kpi"><div class="lbl">Throughput Medio</div><div class="val">{avg_tps:.2f} tok/s</div></div>
    <div class="kpi"><div class="lbl">Token Generati</div><div class="val">{total_comp}</div></div>
    <div class="kpi"><div class="lbl">Fedelta (Stima / Media)</div><div class="val" id="avg-fid">{avg_fid:.2f}/5</div></div>
  </div>

  <h2>Throughput per test case</h2>
  {svg_chart}

  <div class="controls">
    <span>Filtro ruolo:</span>
    <button class="filter-btn active" data-filter="ALL" onclick="filterRole('ALL', this)">Tutti</button>
    <button class="filter-btn" data-filter="BA" onclick="filterRole('BA', this)">Business Analyst</button>
    <button class="filter-btn" data-filter="SA" onclick="filterRole('SA', this)">Software Architect</button>
  </div>

  <table id="bench-table">
    <thead>
      <tr>
        <th>Ruolo</th>
        <th>Test Case</th>
        <th>Stato</th>
        <th>TTFT</th>
        <th>Totale</th>
        <th>Token (P/C)</th>
        <th>tok/s</th>
        <th>Copertura</th>
        <th>Loop</th>
        <th>Fedelta (1-5)</th>
      </tr>
    </thead>
    <tbody>
      {"".join(table_rows)}
    </tbody>
  </table>

  <h2 style="margin-top:26px;">Dettaglio Prompt e Risposte</h2>
  <div id="cards">
    {"".join(cards_html)}
  </div>

<script>
function filterRole(role, btn) {{
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('#bench-table tbody tr, #cards .card').forEach(el => {{
    const r = el.getAttribute('data-role');
    el.style.display = (role === 'ALL' || r === role) ? '' : 'none';
  }});
}}

function recalcFidelity() {{
  const selects = Array.from(document.querySelectorAll('.fid-select'));
  if (!selects.length) return;
  const sum = selects.reduce((acc, s) => acc + Number(s.value || 0), 0);
  const avg = (sum / selects.length).toFixed(2);
  document.getElementById('avg-fid').textContent = avg + '/5';
}}
</script>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark remoto verso mlx_lm.server con report HTML.")
    parser.add_argument("--model", default=os.environ.get("MLX_BENCH_MODEL", DEFAULT_MODEL), help="Path o repo del modello")
    parser.add_argument("--base-url", default=os.environ.get("MLX_BENCH_URL", DEFAULT_BASE_URL), help="URL server MLX (es. http://192.168.1.77:8081)")
    parser.add_argument("--server-label", default="mlx-server", help="Etichetta descrittiva del nodo server")
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, help="Max token in uscita per chiamata")
    parser.add_argument("--temperature", type=float, default=DEFAULT_TEMPERATURE, help="Temperature di generazione")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="Timeout HTTP in secondi")
    parser.add_argument("--out-dir", default="./bench_results", help="Cartella di output sul client per HTML, CSV e JSONL")
    parser.add_argument("--open", action="store_true", help="Apre automaticamente il report HTML nel browser del client")
    args = parser.parse_args()

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    client_host = platform.node() or "client"

    if not wait_for_server(args.base_url, timeout_s=10):
        print(
            f"[ERRORE] Endpoint {args.base_url}/v1/models non raggiungibile dal client. "
            "Verifica che il server sia attivo, in ascolto sull'interfaccia di rete e non bloccato da firewall.",
            file=sys.stderr,
        )
        sys.exit(1)

    all_results: list[dict[str, Any]] = []
    for case in TEST_CASES:
        role = case["role"]
        sys_prompt = SYSTEM_PROMPTS[role]
        print(f"[RUN] {role} - {case['id']} ({case['title']}) -> {args.base_url}")
        metrics = run_completion_stream(
            base_url=args.base_url,
            model=args.model,
            role=role,
            system_prompt=sys_prompt,
            user_prompt=case["prompt"],
            max_tokens=args.max_tokens,
            temperature=args.temperature,
            timeout_s=args.timeout,
        )
        record = {
            "client_host": client_host,
            "server_target": args.base_url,
            "model": args.model,
            "case_id": case["id"],
            "role": role,
            "title": case["title"],
            "status": "ERR" if metrics["error"] else "OK",
            "system_prompt_text": sys_prompt,
            "prompt_text": case["prompt"],
            **metrics,
        }
        all_results.append(record)
        print(
            f"      -> status={record['status']} | TTFT={record['ttft_s']:.3f}s | "
            f"tok/s={record['tokens_per_sec']:.2f} | tok={record['prompt_tokens']}/{record['completion_tokens']} | "
            f"fid={record['auto_fidelity_1_5']}/5"
        )

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    jsonl_path = out_dir / f"benchmark_{stamp}.jsonl"
    csv_path = out_dir / f"benchmark_{stamp}.csv"
    html_path = out_dir / f"benchmark_{stamp}.html"
    latest_html = out_dir / "benchmark_latest.html"

    with open(jsonl_path, "w", encoding="utf-8") as f:
        for r in all_results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    save_csv(all_results, csv_path)
    html_content = build_html_report(all_results, args.model, args.base_url, client_host, args.server_label)
    html_path.write_text(html_content, encoding="utf-8")
    latest_html.write_text(html_content, encoding="utf-8")

    print("\n[COMPLETATO] File generati sul client:")
    print(f"  - HTML (latest): {latest_html}")
    print(f"  - HTML:          {html_path}")
    print(f"  - CSV:           {csv_path}")
    print(f"  - JSONL:         {jsonl_path}")

    if args.open:
        webbrowser.open(latest_html.as_uri())


if __name__ == "__main__":
    main()
