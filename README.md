Apple MLX / Ollama + Open WebUI su macOS Apple Silicon
Gestione unificata di Apple MLX (mlx-lm), Ollama e Open WebUI su macOS Apple Silicon (arm64) tramite un unico script parametrico (mac-ai.sh) basato su Homebrew, uv e launchd.
Struttura
mac-ai.sh: script unico con guida integrata (--help / -h / help) per installare, controllare preliminarmente installazioni e aggiornamenti (check), avviare, alternare in mutua esclusione i motori AI, aggiornare e verificare stato e memoria.
README.md: guida rapida all'uso.
Prerequisiti
Mac con chip Apple Silicon (arm64) e SSH attivo (System Settings > General > Sharing > Remote Login).
Homebrew installato (/opt/homebrew/bin/brew).
Sui Mac con 8 GB di RAM unificata, tenere attivo un solo motore alla volta (mlx oppure ollama) con modelli compatti a 4 bit.
Installazione rapida
git clone https://github.com/giamma80/ollama-openwebui.git
cd ollama-openwebui
chmod +x mac-ai.sh

# Guida completa ai comandi e alle opzioni
./mac-ai.sh --help

# Installazione completa con Apple MLX (0.0.0.0:8081) + Open WebUI (0.0.0.0:8080)
./mac-ai.sh install --model mlx-community/Qwen3-4B-Instruct-2507-4bit

# Evita lo sleep del Mac quando usato come server
sudo pmset -a sleep 0 displaysleep 5 disksleep 0
Comandi principali
Controllo preliminare installazioni e aggiornamenti

./mac-ai.sh check
Avvia Apple MLX su 0.0.0.0:8081 (ferma Ollama automaticamente)
./mac-ai.sh mlx
Avvia Apple MLX con un modello specifico
./mac-ai.sh mlx --model mlx-community/gemma-3-text-4b-it-4bit
Avvia solo MLX senza Open WebUI (es. per benchmark API da client remoto)
./mac-ai.sh stop --all
./mac-ai.sh mlx --no-webui
./mac-ai.sh mlx --no-webui --no-upgrade
Passa a Ollama su 0.0.0.0:11434 (ferma MLX automaticamente)
./mac-ai.sh ollama --model qwen2.5:3b
Verifica servizi launchd, porte in ascolto, modello attivo e swap
./mac-ai.sh status
Aggiorna pacchetti, motori e Open WebUI (o allinea anche git)
./mac-ai.sh update
./mac-ai.sh sync


## Endpoint e porte

| Servizio | Indirizzo bind | Endpoint API / UI |
| :--- | :--- | :--- |
| **Apple MLX (`mlx-lm`)** | `0.0.0.0:8081` | `http://<IP-SERVER>:8081/v1` |
| **Ollama** | `0.0.0.0:11434` | `http://<IP-SERVER>:11434` |
| **Open WebUI** | `0.0.0.0:8080` | `http://<IP-SERVER>:8080` |

## Collegamento MLX in Open WebUI

1. Apri **Admin Panel > Settings > Connections**.
2. Se Ollama è spento, disattiva l'interruttore **Ollama API** per evitare attese.
3. In **OpenAI API**, aggiungi una connessione:
   * **URL:** `http://127.0.0.1:8081/v1`
   * **Autenticazione:** Bearer `mlx`
   * **Tipo di API:** `Chat Completions`

## Accorgimenti per nodi da 8 GB di RAM

* `mac-ai.sh` avvia già `mlx_lm.server` con limiti conservativi di memoria (`--prompt-cache-size 2`, `--prompt-cache-bytes 536870912`, `--prefill-step-size 512`, `--kv-bits 4 --quantized-kv-start 1024`, `--max-tokens 1024`), sovrascrivibili via variabili `MLX_*`.
* In Open WebUI disattiva **Tools**, **Web Search**, **Code Interpreter**, **Title Generation**, **Follow Up Generation** e **Memory**, impostando **Function Calling** su `Default`.
* Log di servizio: `/tmp/mlx.err.log`, `/tmp/ollama.err.log`, `/tmp/openwebui.err.log`.


