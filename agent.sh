#!/usr/bin/env bash
# Local agent, Linux and macOS. Needs only Docker (macOS: also Ollama).
#   Linux: Ollama, Open Terminal, Open WebUI in Docker (NVIDIA GPU through the NVIDIA Container Toolkit).
#   macOS: Ollama native (Docker on macOS has no GPU access), Open Terminal and Open WebUI in Docker.
# Usage: ./agent.sh setup | configure | up | down | status | backup | restore <file> | import-models <folder> | pull <model>
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

umask 077
if [[ ! -f .env ]]; then
    printf 'WEBUI_SECRET_KEY=%s\nOPEN_TERMINAL_API_KEY=%s\n' "$(secret)" "$(secret)" > .env
    say 'Created .env (keys for Open WebUI and Open Terminal).'
fi
# Admin login: creates the account on a fresh install; ./agent.sh configure signs in with it.
if ! grep -q '^WEBUI_ADMIN_EMAIL=' .env; then
    printf 'WEBUI_ADMIN_NAME=Admin\nWEBUI_ADMIN_EMAIL=admin@example.com\nWEBUI_ADMIN_PASSWORD=%s\n' "$(secret)" >> .env
    say 'Added an admin login to .env (WEBUI_ADMIN_*). If Open WebUI already has an account, put its login there.'
fi

# Defaults; any of these can be set in .env.
OT_CWD="$(dirname "$here")"          # the projects folder this repo sits in
BACKUP_DIR="$here/backups"
DEFAULT_MODEL=gpt-oss:20b
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] && printf -v "$key" '%s' "${value%$'\r'}"
done < .env
export DEFAULT_MODEL OT_CWD           # read by docker-compose.yaml

# ---------------------------------------------------------------- docker

compose_files=(-f docker-compose.yaml)
profiles=(--profile docker-terminal)
docker_ollama=0
if [[ "$os" == Linux ]]; then
    docker_ollama=1
    profiles+=(--profile docker-ollama)
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
        compose_files+=(-f docker-compose.gpu.yaml)
    fi
    OLLAMA_URL=http://ollama:11434
else
    OLLAMA_URL=http://host.docker.internal:11434   # native Ollama
fi
export OLLAMA_URL                                 # first-start default in docker-compose.yaml
OT_URL=http://open-terminal:8000

# Pinned helper image for copying volumes (backup, restore, import-models).
alpine=alpine@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

dc() { docker compose "${compose_files[@]}" "${profiles[@]}" "$@"; }

is_up() { curl -fsS -m 2 -o /dev/null "$1" 2>/dev/null; }

ollama_cmd() {
    if (( docker_ollama )); then docker exec ollama ollama "$@"; else ollama "$@"; fi
}

start_ollama() {
    if (( docker_ollama )); then
        dc up -d ollama
        for _ in $(seq 1 60); do docker exec ollama ollama list >/dev/null 2>&1 && return 0; sleep 1; done
        die 'Ollama did not answer. See: docker logs ollama'
    fi
    # macOS: use a running Ollama app, else start ollama serve with the agent's settings (as in docker-compose.yaml).
    is_up http://127.0.0.1:11434/api/version && return 0
    command -v ollama >/dev/null || die 'ollama not found: install it from https://ollama.com/download'
    (
        export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_FLASH_ATTENTION=1 \
            OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=30m
        nohup ollama serve > ollama.log 2> ollama.err.log &
        echo $! > ollama.pid
    )
    for _ in $(seq 1 60); do is_up http://127.0.0.1:11434/api/version && return 0; sleep 1; done
    die "Ollama did not start (see $here/ollama.err.log)."
}

stop_ollama() {   # macOS: only an Ollama this script started
    [[ -f ollama.pid ]] || return 0
    kill -TERM "$(cat ollama.pid)" 2>/dev/null && say 'Ollama stopped.' || true
    rm -f ollama.pid
}

# ---------------------------------------------------------------- configure, backup

configure() {
    # Runs configure.py in a throwaway container of the Open WebUI image (it brings its own Python), on the stack's
    # network: nothing to install here.
    dc up -d open-webui
    # compose run: the same pinned image and network as the open-webui service.
    dc run --rm --no-deps --entrypoint python \
        -e PYTHONUNBUFFERED=1 -e PYTHONDONTWRITEBYTECODE=1 -e "OT_URL=$OT_URL" -e "OLLAMA_URL=$OLLAMA_URL" \
        -v "$here:/agent:ro" -v "$OT_CWD:/projects:ro" \
        open-webui /agent/configure.py
}

backup() {
    # Open WebUI must be stopped, so its database is consistent in the copy. cache/ is fetched again by Open WebUI.
    mkdir -p "$BACKUP_DIR"
    local name; name="open-webui-$(date +%Y%m%d-%H%M%S).tgz"
    docker run --rm -v local-agent_open-webui_data:/data:ro -v "$BACKUP_DIR:/backup" "$alpine" \
        tar czf "/backup/$name" --exclude=./cache -C /data .
    say "Open WebUI backed up to $BACKUP_DIR/$name"
}

restore() {
    [[ -n "$1" && -f "$1" ]] || die 'Usage: ./agent.sh restore <backup .tgz>'
    local dir file; dir="$(cd "$(dirname "$1")" && pwd)"; file="$(basename "$1")"
    docker run --rm -v local-agent_open-webui_data:/data -v "$dir:/backup:ro" "$alpine" \
        sh -c "rm -rf /data/* && tar xzf '/backup/$file' -C /data"
    say "Open WebUI restored from $dir/$file"
}

# ---------------------------------------------------------------- setup

setup() {
    command -v docker >/dev/null || die 'Docker not found: install Docker (Linux: Docker Engine; macOS: Docker Desktop).'
    docker info >/dev/null 2>&1 || die 'Docker is not running (Linux: is your user in the docker group?).'
    say 'Docker: ok'
    if [[ "$os" == Linux ]] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
        say 'No NVIDIA runtime in Docker: Ollama will run on the CPU (slow). For a GPU install the NVIDIA Container Toolkit.'
    fi
    if [[ -f "$OT_CWD/AGENTS.md" ]]; then say "Kept $OT_CWD/AGENTS.md"
    else cp AGENTS.example.md "$OT_CWD/AGENTS.md"; say "Created $OT_CWD/AGENTS.md"; fi
    dc pull
    start_ollama
    if ollama_cmd show "$DEFAULT_MODEL" >/dev/null 2>&1; then say "Model $DEFAULT_MODEL: ok"
    else ollama_cmd pull "$DEFAULT_MODEL"; fi
    dc up -d --remove-orphans
    configure
    say 'Setup done: http://localhost:3000 (login: WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD in .env).'
}

# ---------------------------------------------------------------- actions

case "$action" in
    setup) setup ;;
    configure) configure ;;
    up)
        (( docker_ollama )) || start_ollama
        dc up -d --remove-orphans
        say 'Open WebUI: http://localhost:3000'
        ;;
    down)
        dc down --remove-orphans
        stop_ollama
        ;;
    status)
        dc ps --format 'table {{.Name}}\t{{.Status}}'
        (( docker_ollama )) || { is_up http://127.0.0.1:11434/api/version && say 'Ollama: running' || say 'Ollama: stopped'; }
        ;;
    backup)  dc stop open-webui; trap 'dc start open-webui' EXIT; backup ;;
    restore) dc stop open-webui; trap 'dc start open-webui' EXIT; restore "$arg" ;;
    import-models)
        # One-off: copy Ollama models from a folder (layout <folder>/models/blobs, manifests) into the volume (Linux).
        (( docker_ollama )) || die 'macOS: native Ollama uses its own folder (~/.ollama); nothing to import.'
        [[ -n "$arg" && -d "$arg/models" ]] || die 'Usage: ./agent.sh import-models <folder with a models subfolder>'
        dc create ollama; dc stop ollama
        docker run --rm -v "$(cd "$arg" && pwd):/src:ro" -v local-agent_ollama_data:/dst "$alpine" cp -a /src/models /dst/
        start_ollama
        ollama_cmd list
        ;;
    pull)
        [[ -n "$arg" ]] || die 'Usage: ./agent.sh pull <model>'
        start_ollama
        ollama_cmd pull "$arg"
        ;;
    *) die "unknown action '$action' (setup | configure | up | down | status | backup | restore | import-models | pull)" ;;
esac
