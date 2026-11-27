#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# mac-ai.sh — Gestore unificato Apple MLX, Ollama e Open WebUI su macOS arm64
# ==============================================================================

UID_NUM="$(id -u)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON_VERSION="${MAC_AI_PYTHON:-3.11}"
MLX_DIR="${MLX_DIR:-$HOME/mlx-ai}"
OPENWEBUI_DIR="${OPENWEBUI_DIR:-$HOME/openwebui}"

DEFAULT_MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
DEFAULT_OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"

MLX_HOST="${MLX_HOST:-0.0.0.0}"
MLX_PORT="${MLX_PORT:-8081}"
OLLAMA_HOST_ADDR="${OLLAMA_HOST:-0.0.0.0:11434}"
WEBUI_HOST="${WEBUI_HOST:-0.0.0.0}"
WEBUI_PORT="${WEBUI_PORT:-8080}"

# Limiti memoria MLX calibrati per Apple Silicon 8 GB RAM unificata

MLX_MAX_TOKENS="${MLX_MAX_TOKENS:-512}"
MLX_PROMPT_CACHE_SIZE="${MLX_PROMPT_CACHE_SIZE:-2}"
MLX_PROMPT_CACHE_BYTES="${MLX_PROMPT_CACHE_BYTES:-536870912}"
MLX_PREFILL_STEP_SIZE="${MLX_PREFILL_STEP_SIZE:-512}"
MLX_KV_BITS="${MLX_KV_BITS:-4}"
MLX_QUANTIZED_KV_START="${MLX_QUANTIZED_KV_START:-1024}"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
MLX_PLIST="$LAUNCH_AGENTS_DIR/com.local.mlx.plist"
OLLAMA_PLIST="$LAUNCH_AGENTS_DIR/com.local.ollama.plist"
WEBUI_PLIST="$LAUNCH_AGENTS_DIR/com.local.openwebui.plist"

log()  { printf "\n[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
fail() { printf "\n[ERRORE] %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  ./mac-ai.sh <comando> [opzioni]

Comandi principali:
  install            Controlla installazioni/update, installa o aggiorna i componenti e avvia i servizi
  check              Verifica preliminarmente cosa è già installato e se ci sono update disponibili
  mlx                Avvia Apple MLX (0.0.0.0:8081) e ferma Ollama per preservare RAM
  ollama             Avvia Ollama (0.0.0.0:11434) e ferma MLX per preservare RAM
  webui              Avvia o riavvia solo Open WebUI (0.0.0.0:8080)
  stop               Ferma MLX e Ollama (opzionalmente anche Open WebUI con --all)
  status             Mostra stato servizi launchd, porte in ascolto, modelli e swap
  update             Verifica e applica eventuali aggiornamenti di brew, uv, mlx-lm, Ollama e Open WebUI
  sync               Esegue git pull --ff-only nella repo e lancia update
  help, -h, --help   Mostra questa guida

Opzioni:
  --model <nome>     Modello da usare (es. mlx-community/Qwen3-4B-Instruct-2507-4bit oppure qwen2.5:3b)
  --host <ip>        Indirizzo bind per MLX o WebUI (default: 0.0.0.0)
  --port <porta>     Porta di ascolto (default: 8081 per MLX, 8080 per WebUI)
  --no-webui         Non avviare/riavviare Open WebUI durante install, mlx o ollama
  --no-upgrade       Usa le installazioni locali esistenti senza cercare/applicare aggiornamenti online
  --all              Con 'stop', ferma anche Open WebUI oltre ai motori AI

Variabili d'ambiente supportate:
  MLX_MODEL, MLX_HOST, MLX_PORT, MLX_MAX_TOKENS, MLX_PROMPT_CACHE_SIZE,
  MLX_PROMPT_CACHE_BYTES, MLX_PREFILL_STEP_SIZE, MLX_KV_BITS, MLX_QUANTIZED_KV_START,
  OLLAMA_MODEL, OLLAMA_HOST, WEBUI_HOST, WEBUI_PORT

Esempi:
  ./mac-ai.sh check
  ./mac-ai.sh install --model mlx-community/Qwen3-4B-Instruct-2507-4bit
  ./mac-ai.sh mlx --no-upgrade
  ./mac-ai.sh mlx --model mlx-community/gemma-3-text-4b-it-4bit
  ./mac-ai.sh mlx --no-webui --no-upgrade
  ./mac-ai.sh ollama --model qwen2.5-coder:3b
  ./mac-ai.sh stop --all
  ./mac-ai.sh status
  ./mac-ai.sh sync
EOF
}

ensure_macos_arm() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "Supportato solo su macOS."
  [[ "$(uname -m)" == "arm64" ]] || fail "Richiede Apple Silicon (arm64); rilevato $(uname -m)."
  if ! command -v brew >/dev/null 2>&1; then
    [[ -x "/opt/homebrew/bin/brew" ]] && eval "$(/opt/homebrew/bin/brew shellenv)" || fail "Homebrew non trovato."
  else
    eval "$(brew shellenv)"
  fi
  mkdir -p "$LAUNCH_AGENTS_DIR" "$MLX_DIR" "$OPENWEBUI_DIR/data"
}

get_local_pkg_version() {
  local venv_dir="$1" pkg="$2"
  if [[ -x "$venv_dir/.venv/bin/python" ]]; then
    "$venv_dir/.venv/bin/python" -c "import importlib.metadata as m; print(m.version('$pkg'))" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

get_pypi_latest_version() {
  local py_bin="$1" pkg="$2"
  "$py_bin" -c "
import json, urllib.request
try:
    with urllib.request.urlopen('https://pypi.org/pypi/${pkg}/json', timeout=5) as r:
        print(json.load(r)['info']['version'])
except Exception:
    print('')
" 2>/dev/null || echo ""
}

ensure_uv() {
  local do_upgrade="${1:-1}"
  if brew list uv >/dev/null 2>&1; then
    if [[ "$do_upgrade" -eq 1 ]] && brew outdated --quiet uv | grep -q "^uv$"; then
      log "Aggiornamento uv disponibile via Homebrew..."
      brew upgrade uv
    fi
  else
    log "Installazione uv..."
    brew install uv
  fi
  command -v uv >/dev/null 2>&1 || fail "uv non disponibile nel PATH."
}

ensure_venv() {
  local dir="$1"
  if [[ ! -x "$dir/.venv/bin/python" ]]; then
    log "Creazione virtualenv Python $PYTHON_VERSION in $dir/.venv..."
    uv venv --clear --python "$PYTHON_VERSION" "$dir/.venv"
  fi
}

ensure_mlx_deps() {
  local do_upgrade="${1:-1}"
  ensure_uv "$do_upgrade"
  ensure_venv "$MLX_DIR"
  local local_ver
  local_ver="$(get_local_pkg_version "$MLX_DIR" "mlx-lm")"

  if [[ -z "$local_ver" ]]; then
    log "mlx-lm non presente: installazione in corso..."
    uv pip install --python "$MLX_DIR/.venv/bin/python" mlx-lm
    return 0
  fi

  if [[ "$do_upgrade" -eq 0 ]]; then
    log "mlx-lm già installato (v${local_ver}, --no-upgrade attivo)."
    return 0
  fi

  local latest_ver
  latest_ver="$(get_pypi_latest_version "$MLX_DIR/.venv/bin/python" "mlx-lm")"
  if [[ -n "$latest_ver" && "$latest_ver" != "$local_ver" ]]; then
    log "Aggiornamento mlx-lm: v${local_ver} -> v${latest_ver}..."
    uv pip install --python "$MLX_DIR/.venv/bin/python" --upgrade mlx-lm
  else
    log "mlx-lm è già installato e aggiornato (v${local_ver})."
  fi
}

ensure_ollama_deps() {
  local do_upgrade="${1:-1}"
  if brew list ollama >/dev/null 2>&1; then
    if [[ "$do_upgrade" -eq 1 ]] && brew outdated --quiet ollama | grep -q "^ollama$"; then
      log "Aggiornamento Ollama disponibile via Homebrew..."
      brew upgrade ollama
    else
      local over
      over="$(ollama --version 2>/dev/null | head -n 1 || echo "installato")"
      log "Ollama è già installato e aggiornato (${over})."
    fi
  else
    log "Installazione Ollama..."
    brew install ollama
  fi
}

ensure_webui_deps() {
  local do_upgrade="${1:-1}"
  ensure_uv "$do_upgrade"
  ensure_venv "$OPENWEBUI_DIR"
  local local_ver
  local_ver="$(get_local_pkg_version "$OPENWEBUI_DIR" "open-webui")"

  if [[ -z "$local_ver" ]]; then
    log "Open WebUI non presente: installazione in corso..."
    uv pip install --python "$OPENWEBUI_DIR/.venv/bin/python" open-webui
    return 0
  fi

  if [[ "$do_upgrade" -eq 0 ]]; then
    log "Open WebUI già installato (v${local_ver}, --no-upgrade attivo)."
    return 0
  fi

  local latest_ver
  latest_ver="$(get_pypi_latest_version "$OPENWEBUI_DIR/.venv/bin/python" "open-webui")"
  if [[ -n "$latest_ver" && "$latest_ver" != "$local_ver" ]]; then
    log "Aggiornamento Open WebUI: v${local_ver} -> v${latest_ver}..."
    uv pip install --python "$OPENWEBUI_DIR/.venv/bin/python" --upgrade open-webui
  else
    log "Open WebUI è già installato e aggiornato (v${local_ver})."
  fi
}

preflight_report() {
  local include_webui="${1:-1}"
  local needs_action=0

  log "Controllo preliminare installazioni e aggiornamenti..."

  if brew list uv >/dev/null 2>&1; then
    if brew outdated --quiet uv | grep -q "^uv$"; then
      echo "  - uv: installato (aggiornamento disponibile)"
      needs_action=1
    else
      echo "  - uv: già installato e aggiornato ($(uv --version))"
    fi
  else
    echo "  - uv: NON installato"
    needs_action=1
  fi

  if brew list ollama >/dev/null 2>&1; then
    if brew outdated --quiet ollama | grep -q "^ollama$"; then
      echo "  - Ollama: installato (aggiornamento disponibile)"
      needs_action=1
    else
      echo "  - Ollama: già installato e aggiornato ($(ollama --version 2>/dev/null | head -n 1))"
    fi
  else
    echo "  - Ollama: NON installato"
    needs_action=1
  fi

  local mlx_ver
  mlx_ver="$(get_local_pkg_version "$MLX_DIR" "mlx-lm")"
  if [[ -n "$mlx_ver" ]]; then
    local mlx_latest
    mlx_latest="$(get_pypi_latest_version "$MLX_DIR/.venv/bin/python" "mlx-lm")"
    if [[ -n "$mlx_latest" && "$mlx_latest" != "$mlx_ver" ]]; then
      echo "  - mlx-lm: installato v${mlx_ver} (disponibile v${mlx_latest})"
      needs_action=1
    else
      echo "  - mlx-lm: già installato e aggiornato (v${mlx_ver})"
    fi
  else
    echo "  - mlx-lm: NON installato"
    needs_action=1
  fi

  if [[ "$include_webui" -eq 1 ]]; then
    local webui_ver
    webui_ver="$(get_local_pkg_version "$OPENWEBUI_DIR" "open-webui")"
    if [[ -n "$webui_ver" ]]; then
      local webui_latest
      webui_latest="$(get_pypi_latest_version "$OPENWEBUI_DIR/.venv/bin/python" "open-webui")"
      if [[ -n "$webui_latest" && "$webui_latest" != "$webui_ver" ]]; then
        echo "  - Open WebUI: installato v${webui_ver} (disponibile v${webui_latest})"
        needs_action=1
      else
        echo "  - Open WebUI: già installato e aggiornato (v${webui_ver})"
      fi
    else
      echo "  - Open WebUI: NON installato"
      needs_action=1
    fi
  fi

  if [[ "$needs_action" -eq 0 ]]; then
    log "[OK] Tutto è già installato e aggiornato alle ultime versioni."
  else
    log "[INFO] Rilevati componenti da installare o aggiornare."
  fi
  return 0
}


stop_mlx() {

  launchctl bootout "gui/$UID_NUM" "$MLX_PLIST" >/dev/null 2>&1 || true

  pkill -f "mlx_lm.server" >/dev/null 2>&1 || true

  local pids

  pids="$(lsof -tiTCP:"${MLX_PORT}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    kill -9 $pids >/dev/null 2>&1 || true
  fi

}


stop_ollama() {
  launchctl bootout "gui/$UID_NUM" "$OLLAMA_PLIST" >/dev/null 2>&1 || true
  pkill -f "ollama serve" >/dev/null 2>&1 || true
}

stop_webui() {
  launchctl bootout "gui/$UID_NUM" "$WEBUI_PLIST" >/dev/null 2>&1 || true
  pkill -f "$OPENWEBUI_DIR/.venv/bin/open-webui" >/dev/null 2>&1 || true
}

write_and_start_mlx() {
  local model="$1" host="$2" port="$3" do_upgrade="${4:-1}"
  ensure_mlx_deps "$do_upgrade"
  log "Arresto Ollama e precedente istanza MLX..."
  stop_ollama
  stop_mlx
  sleep 1

  cat <<EOF > "$MLX_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.mlx</string>
  <key>WorkingDirectory</key><string>${MLX_DIR}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${MLX_DIR}/.venv/bin/mlx_lm.server</string>
    <string>--model</string><string>${model}</string>
    <string>--host</string><string>${host}</string>
    <string>--port</string><string>${port}</string>
    <string>--max-tokens</string><string>${MLX_MAX_TOKENS}</string>
    <string>--prompt-cache-size</string><string>${MLX_PROMPT_CACHE_SIZE}</string>
    <string>--prompt-cache-bytes</string><string>${MLX_PROMPT_CACHE_BYTES}</string>
    <string>--prefill-step-size</string><string>${MLX_PREFILL_STEP_SIZE}</string>
    <string>--kv-bits</string><string>${MLX_KV_BITS}</string>
    <string>--quantized-kv-start</string><string>${MLX_QUANTIZED_KV_START}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/mlx.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/mlx.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$MLX_PLIST" >/dev/null || fail "Plist MLX non valido."
  launchctl bootstrap "gui/$UID_NUM" "$MLX_PLIST"

  log "Attesa avvio MLX su ${host}:${port} (modello: ${model})..."
  for _ in $(seq 1 300); do
    if curl -fsS "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
      log "MLX pronto su http://${host}:${port}/v1"
      return 0
    fi
    sleep 2
  done
  fail "Timeout avvio MLX. Controlla /tmp/mlx.err.log"
}

write_and_start_ollama() {
  local model="$1" do_upgrade="${2:-1}"
  ensure_ollama_deps "$do_upgrade"
  local ollama_bin
  ollama_bin="$(command -v ollama)"
  log "Arresto MLX e precedente istanza Ollama..."
  stop_mlx
  stop_ollama
  sleep 1

  cat <<EOF > "$OLLAMA_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.ollama</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>${OLLAMA_HOST_ADDR}</string>
    <key>OLLAMA_KEEP_ALIVE</key><string>2m</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>${ollama_bin}</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/ollama.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/ollama.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$OLLAMA_PLIST" >/dev/null || fail "Plist Ollama non valido."
  launchctl bootstrap "gui/$UID_NUM" "$OLLAMA_PLIST"

  log "Attesa avvio Ollama su ${OLLAMA_HOST_ADDR}..."
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  log "Verifica/download modello Ollama: ${model}..."
  OLLAMA_HOST="127.0.0.1:11434" "$ollama_bin" pull "$model"
  log "Ollama pronto con modello ${model}"
}

write_and_start_webui() {
  local host="$1" port="$2" do_upgrade="${3:-1}"
  ensure_webui_deps "$do_upgrade"
  local secret_file="$OPENWEBUI_DIR/data/.webui_secret_key"
  if [[ ! -s "$secret_file" ]]; then
    head -c 32 /dev/urandom | base64 > "$secret_file"
    chmod 600 "$secret_file"
  fi
  local secret_key
  secret_key="$(cat "$secret_file")"

  stop_webui
  sleep 1

  cat <<EOF > "$WEBUI_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.openwebui</string>
  <key>WorkingDirectory</key><string>${OPENWEBUI_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DATA_DIR</key><string>${OPENWEBUI_DIR}/data</string>
    <key>WEBUI_SECRET_KEY</key><string>${secret_key}</string>
    <key>ENABLE_OLLAMA_API</key><string>True</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>${OPENWEBUI_DIR}/.venv/bin/open-webui</string>
    <string>serve</string>
    <string>--host</string><string>${host}</string>
    <string>--port</string><string>${port}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/openwebui.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/openwebui.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$WEBUI_PLIST" >/dev/null || fail "Plist Open WebUI non valido."
  launchctl bootstrap "gui/$UID_NUM" "$WEBUI_PLIST"

  log "Attesa avvio Open WebUI su ${host}:${port}..."
  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${port}" >/dev/null 2>&1; then
      log "Open WebUI pronto su http://${host}:${port}"
      return 0
    fi
    sleep 2
  done
  fail "Timeout avvio Open WebUI. Controlla /tmp/openwebui.err.log"
}

show_status() {
  echo "=== Servizi launchd ==="
  launchctl list | grep -E "com\.local\.(mlx|ollama|openwebui)" || echo "Nessun servizio com.local.* attivo"
  echo ""
  echo "=== Porte in ascolto (8081=MLX, 11434=Ollama, 8080=WebUI) ==="

  lsof -nP -iTCP:8081 -iTCP:11434 -iTCP:8080 -sTCP:LISTEN || true
  echo ""
  echo "=== Modello attivo MLX ==="
  curl -fsS "http://127.0.0.1:${MLX_PORT}/v1/models" 2>/dev/null || echo "MLX non attivo"
  echo ""
  echo "=== Modelli in memoria Ollama ==="
  ollama ps 2>/dev/null || echo "Ollama non attivo"
  echo ""
  echo "=== Memoria swap ==="
  sysctl vm.swapusage
}

do_update() {
  log "Aggiornamento indici Homebrew..."
  brew update >/dev/null
  preflight_report 1
  ensure_uv 1
  ensure_ollama_deps 1
  ensure_mlx_deps 1
  ensure_webui_deps 1
  if curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    log "Verifica aggiornamenti modelli Ollama installati..."
    ollama list | awk 'NR>1 {print $1}' | xargs -r -n1 ollama pull || true
  fi
  launchctl list | grep -q "com.local.mlx" && launchctl kickstart -k "gui/$UID_NUM/com.local.mlx" || true
  launchctl list | grep -q "com.local.ollama" && launchctl kickstart -k "gui/$UID_NUM/com.local.ollama" || true
  launchctl list | grep -q "com.local.openwebui" && launchctl kickstart -k "gui/$UID_NUM/com.local.openwebui" || true
  log "Procedura di verifica/aggiornamento completata."
}

# --- Parsing argomenti ---
CMD="${1:-help}"
case "$CMD" in
  help|-h|--help)
    usage
    exit 0
    ;;
esac
shift || true

OPT_MODEL=""
OPT_HOST=""
OPT_PORT=""
NO_WEBUI=0
DO_UPGRADE=1
STOP_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || fail "--model richiede un valore."
      OPT_MODEL="$2"; shift 2 ;;
    --host)
      [[ $# -ge 2 ]] || fail "--host richiede un valore."
      OPT_HOST="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || fail "--port richiede un valore."
      OPT_PORT="$2"; shift 2 ;;
    --no-webui)
      NO_WEBUI=1; shift ;;
    --no-upgrade)
      DO_UPGRADE=0; shift ;;
    --all)
      STOP_ALL=1; shift ;;
    -h|--help|help)
      usage; exit 0 ;;
    *)
      fail "Opzione sconosciuta: $1 (usa ./mac-ai.sh --help)" ;;
  esac
done

ensure_macos_arm

case "$CMD" in
  check)
    brew update >/dev/null 2>&1 || true
    preflight_report $((1 - NO_WEBUI))
    ;;
  install)
    if [[ "$DO_UPGRADE" -eq 1 ]]; then
      brew update >/dev/null 2>&1 || true
      preflight_report $((1 - NO_WEBUI))
    fi
    M_MODEL="${OPT_MODEL:-$DEFAULT_MLX_MODEL}"
    M_HOST="${OPT_HOST:-$MLX_HOST}"
    M_PORT="${OPT_PORT:-$MLX_PORT}"
    ensure_ollama_deps "$DO_UPGRADE"
    write_and_start_mlx "$M_MODEL" "$M_HOST" "$M_PORT" "$DO_UPGRADE"
    if [[ "$NO_WEBUI" -eq 0 ]]; then
      write_and_start_webui "$WEBUI_HOST" "$WEBUI_PORT" "$DO_UPGRADE"
    fi
    show_status
    ;;
  mlx)
    M_MODEL="${OPT_MODEL:-$DEFAULT_MLX_MODEL}"
    M_HOST="${OPT_HOST:-$MLX_HOST}"
    M_PORT="${OPT_PORT:-$MLX_PORT}"
    write_and_start_mlx "$M_MODEL" "$M_HOST" "$M_PORT" "$DO_UPGRADE"
    if [[ "$NO_WEBUI" -eq 0 ]] && ! curl -fsS "http://127.0.0.1:${WEBUI_PORT}" >/dev/null 2>&1; then
      write_and_start_webui "$WEBUI_HOST" "$WEBUI_PORT" "$DO_UPGRADE"
    fi
    show_status
    ;;
  ollama)
    O_MODEL="${OPT_MODEL:-$DEFAULT_OLLAMA_MODEL}"
    write_and_start_ollama "$O_MODEL" "$DO_UPGRADE"
    if [[ "$NO_WEBUI" -eq 0 ]] && ! curl -fsS "http://127.0.0.1:${WEBUI_PORT}" >/dev/null 2>&1; then
      write_and_start_webui "$WEBUI_HOST" "$WEBUI_PORT" "$DO_UPGRADE"
    fi
    show_status
    ;;
  webui)
    W_HOST="${OPT_HOST:-$WEBUI_HOST}"
    W_PORT="${OPT_PORT:-$WEBUI_PORT}"
    write_and_start_webui "$W_HOST" "$W_PORT" "$DO_UPGRADE"
    show_status
    ;;
  stop)
    log "Arresto motori AI..."
    stop_mlx
    stop_ollama
    if [[ "$STOP_ALL" -eq 1 ]]; then
      log "Arresto anche Open WebUI..."
      stop_webui
    fi
    show_status
    ;;
  status)
    show_status
    ;;
  update)
    do_update
    show_status
    ;;
  sync)
    log "Allineamento repository git..."
    git -C "$REPO_DIR" pull --ff-only
    chmod +x "$REPO_DIR/mac-ai.sh"
    do_update
    show_status
    ;;
  *)
    fail "Comando sconosciuto: '$CMD'. Esegui './mac-ai.sh --help' per vedere i comandi disponibili."
    ;;
esac
