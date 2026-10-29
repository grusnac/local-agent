#!/usr/bin/env bash
# Local agent, Linux and macOS.
#   Linux: Ollama + Open WebUI in Docker (NVIDIA GPU through the NVIDIA Container Toolkit), Open Terminal native.
#   macOS: Ollama native (Docker on macOS has no GPU access), Open WebUI in Docker, Open Terminal native.
# Usage: ./agent.sh setup | up | down | status | backup | restore <file> | import-models <folder> | pull <model>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
action="${1:-status}"
arg="${2:-}"
os="$(uname -s)"   # Linux | Darwin

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- settings

secret() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }

if [[ ! -f .env ]]; then
    umask 077
    printf 'WEBUI_SECRET_KEY=%s\nOPEN_TERMINAL_API_KEY=%s\n' "$(secret)" "$(secret)" > .env
    say 'Created .env (keys for Open WebUI and Open Terminal).'
fi

# Defaults; any of these can be set in .env.
OT_PORT=8000
OT_CWD="$(dirname "$here")"          # the projects folder this repo sits in
BACKUP_DIR="$here/backups"
DEFAULT_MODEL=gpt-oss:20b
OT_HOST=""
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] && printf -v "$key" '%s' "$value"
done < .env
export DEFAULT_MODEL                 # read by docker-compose.yaml

if [[ -z "$OT_HOST" ]]; then
    if [[ "$os" == Linux ]]; then
        # On Linux, host.docker.internal (host-gateway) is the docker0 bridge address: a server on 127.0.0.1 is not
        # reachable from containers, so Open Terminal listens on that bridge address (not on the network).
        OT_HOST="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
        [[ -n "$OT_HOST" ]] || { OT_HOST=127.0.0.1; say 'warning: no docker0 bridge found; Open WebUI may not reach Open Terminal.'; }
    else
        OT_HOST=127.0.0.1            # Docker Desktop forwards host.docker.internal to the host's loopback
    fi
fi

# ---------------------------------------------------------------- docker

compose_args=(-f docker-compose.yaml)
docker_ollama=0
if [[ "$os" == Linux ]]; then
    docker_ollama=1
    compose_args+=(--profile docker-ollama)
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
        compose_args=(-f docker-compose.yaml -f docker-compose.gpu.yaml --profile docker-ollama)
        has_gpu=1
    else
        has_gpu=0
    fi
else
    export OLLAMA_URL=http://host.docker.internal:11434   # native Ollama
    has_gpu=1                                             # Metal, used by native Ollama
fi

dc() { docker compose "${compose_args[@]}" "$@"; }

is_up() { curl -fsS -m 2 -o /dev/null "$1" 2>/dev/null; }

ollama_cmd() {
    if (( docker_ollama )); then docker exec ollama ollama "$@"; else ollama "$@"; fi
}

wait_for() {   # url, label
    for _ in $(seq 1 120); do is_up "$1" && return 0; sleep 1; done
    die "$2 did not start."
}

# Native process: start in the background with logs + pid file; stop the pid and its children.
start_native() {   # name, health url, command...
    local name="$1" url="$2"; shift 2
    if is_up "$url"; then say "$name already running."; return; fi
    nohup "$@" > "$name.log" 2> "$name.err.log" &
    echo $! > "$name.pid"
    printf 'Waiting for %s...' "$name"
    wait_for "$url" "$name (see $here/$name.err.log)"
    say ' ready.'
}

stop_native() {    # name
    local pidfile="$1.pid" pid
    [[ -f "$pidfile" ]] || return 0
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
        pkill -TERM -P "$pid" 2>/dev/null || true   # uvx -> python
        kill -TERM "$pid" 2>/dev/null || true
        say "$1 stopped (pid $pid)."
    fi
    rm -f "$pidfile"
}

ot_url() { echo "http://$OT_HOST:$OT_PORT/health"; }

start_terminal() {
    command -v uvx >/dev/null || [[ -x "$HOME/.local/bin/uvx" ]] || die 'uvx not found: run ./agent.sh setup.'
    local uvx; uvx="$(command -v uvx || echo "$HOME/.local/bin/uvx")"
    # Subshell: the key goes to Open Terminal through its environment (not the command line), nowhere else.
    (
        export OPEN_TERMINAL_API_KEY
        start_native open-terminal "$(ot_url)" "$uvx" open-terminal run --cwd "$OT_CWD" \
            --host "$OT_HOST" --port "$OT_PORT" --cors-allowed-origins http://localhost:3000
    )
}

start_ollama() {
    if (( docker_ollama )); then
        dc up -d ollama
        for _ in $(seq 1 60); do docker exec ollama ollama list >/dev/null 2>&1 && return 0; sleep 1; done
        die 'Ollama did not answer. See: docker logs ollama'
    fi
    # macOS: if the Ollama app already serves on 11434, use it; else run ollama serve with the agent's settings.
    command -v ollama >/dev/null || die 'ollama not found: install it from https://ollama.com/download'
    # Same settings as the Docker Ollama (docker-compose.yaml).
    (
        export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_FLASH_ATTENTION=1 \
            OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=30m
        start_native ollama http://127.0.0.1:11434/api/version ollama serve
    )
}

# ---------------------------------------------------------------- backup

backup() {
    # Open WebUI must be stopped, so its database is consistent in the copy. cache/ is fetched again by Open WebUI.
    mkdir -p "$BACKUP_DIR"
    local name; name="open-webui-$(date +%Y%m%d-%H%M%S).tgz"
    docker run --rm -v local-agent_open-webui_data:/data:ro -v "$BACKUP_DIR:/backup" alpine \
        tar czf "/backup/$name" --exclude=./cache -C /data .
    say "Open WebUI backed up to $BACKUP_DIR/$name"
}

restore() {
    [[ -n "$1" && -f "$1" ]] || die 'Usage: ./agent.sh restore <backup .tgz>'
    local dir file; dir="$(cd "$(dirname "$1")" && pwd)"; file="$(basename "$1")"
    docker run --rm -v local-agent_open-webui_data:/data -v "$dir:/backup:ro" alpine \
        sh -c "rm -rf /data/* && tar xzf '/backup/$file' -C /data"
    say "Open WebUI restored from $dir/$file"
}

# ---------------------------------------------------------------- setup

setup() {
    command -v docker >/dev/null || die 'Docker not found: install Docker (Linux: Docker Engine; macOS: Docker Desktop).'
    docker info >/dev/null 2>&1 || die 'Docker is not running (Linux: is your user in the docker group?).'
    say 'Docker: ok'
    command -v curl >/dev/null || die 'curl not found: install it.'
    if ! command -v uvx >/dev/null && [[ ! -x "$HOME/.local/bin/uvx" ]]; then
        say 'Installing uv (runs Open Terminal)...'
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    say 'uv: ok'
    if (( docker_ollama && ! has_gpu )); then
        say 'No NVIDIA runtime in Docker: Ollama will run on the CPU (slow). For a GPU install the NVIDIA Container Toolkit.'
    fi
    dc pull
    start_ollama
    if ollama_cmd show "$DEFAULT_MODEL" >/dev/null 2>&1; then say "Model $DEFAULT_MODEL: ok"
    else ollama_cmd pull "$DEFAULT_MODEL"; fi
    if [[ -f "$OT_CWD/AGENTS.md" ]]; then say "Kept $OT_CWD/AGENTS.md"
    else cp AGENTS.example.md "$OT_CWD/AGENTS.md"; say "Created $OT_CWD/AGENTS.md"; fi
    say 'Setup done. Next: ./agent.sh up, then the one-time Open WebUI settings in README.md.'
}

# ---------------------------------------------------------------- actions

case "$action" in
    setup) setup ;;
    up)
        (( docker_ollama )) || start_ollama
        start_terminal
        dc up -d --remove-orphans
        say 'Open WebUI: http://localhost:3000'
        ;;
    down)
        dc down --remove-orphans
        stop_native open-terminal
        stop_native ollama   # only if this script started it (macOS)
        ;;
    status)
        dc ps --format 'table {{.Name}}\t{{.Status}}'
        is_up "$(ot_url)" && say 'Open Terminal: running' || say 'Open Terminal: stopped'
        (( docker_ollama )) || { is_up http://127.0.0.1:11434/api/version && say 'Ollama: running' || say 'Ollama: stopped'; }
        ;;
    backup)  dc stop open-webui; trap 'dc start open-webui' EXIT; backup ;;
    restore) dc stop open-webui; trap 'dc start open-webui' EXIT; restore "$arg" ;;
    import-models)
        # One-off: copy Ollama models from a folder (layout <folder>/models/blobs, manifests) into the volume (Linux).
        (( docker_ollama )) || die 'macOS: native Ollama uses its own folder (~/.ollama); nothing to import.'
        [[ -n "$arg" && -d "$arg/models" ]] || die 'Usage: ./agent.sh import-models <folder with a models subfolder>'
        dc create ollama; dc stop ollama
        docker run --rm -v "$(cd "$arg" && pwd):/src:ro" -v local-agent_ollama_data:/dst alpine cp -a /src/models /dst/
        start_ollama
        ollama_cmd list
        ;;
    pull)
        [[ -n "$arg" ]] || die 'Usage: ./agent.sh pull <model>'
        start_ollama
        ollama_cmd pull "$arg"
        ;;
    *) die "unknown action '$action' (setup | up | down | status | backup | restore | import-models | pull)" ;;
esac
