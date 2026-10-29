# Local agent

A local AI agent you talk to in the browser. It reads and edits files in the projects folder this repo sits in, runs
commands, and follows the rules in the `AGENTS.md` files. Nothing leaves the computer.

```
Browser -- Open WebUI (Docker, http://localhost:3000)        chat, memory, knowledge, agents
              |-- Ollama (:11434)                             the model
              '-- Open Terminal (native, :8000)               shell + files, starts in the projects folder
```

| | Windows | Linux | macOS |
|---|---|---|---|
| Script | `agent.cmd <command>` (runs `agent.ps1`) | `./agent.sh <command>` | `./agent.sh <command>` |
| Ollama | Docker, NVIDIA GPU | Docker, NVIDIA GPU (NVIDIA Container Toolkit) | native (Docker on macOS has no GPU) |
| Models | Docker volume `ollama_data` | Docker volume `ollama_data` | `~/.ollama` |
| Open Terminal | native, PowerShell, `127.0.0.1` | native, bash, on the `docker0` bridge address | native, `127.0.0.1` |
| Tested | yes (Windows 11, RTX 5080) | no | no |

## Commands

| Command | Does |
|---|---|
| `setup` | Checks Docker, installs uv if missing, creates `.env` with random keys, pulls images, starts Ollama and pulls the default model, puts `AGENTS.md` in the projects folder if none is there. Safe to run again. |
| `up` | Starts Open Terminal, Ollama, Open WebUI. |
| `down` | Stops them. Volumes (models, Open WebUI data) are kept. |
| `status` | Shows what is running. |
| `backup` | Writes `<BACKUP_DIR>/open-webui-<date>-<time>.tgz`: agents, knowledge bases, memories, chats, settings. |
| `restore <file>` | Replaces Open WebUI's data with a backup. |
| `import-models <folder>` | Copies Ollama models from a folder (with a `models` subfolder) into the volume. Windows, Linux. |
| `pull <model>` | Downloads a model, e.g. `pull qwen3-coder:30b`. |

Windows shortcuts: `agent-up.cmd`, `agent-down.cmd`, `agent-status.cmd`.

## First time

1. Install Docker (Windows, macOS: Docker Desktop; Linux: Docker Engine + NVIDIA Container Toolkit for a GPU).
   macOS: also Ollama from https://ollama.com/download.
2. Windows: put Docker's disk on a drive with room for the models (~15 GB each): Docker Desktop > Settings >
   VM resources > Disk image location.
3. `setup`, then `up`, then open http://localhost:3000 and create the admin account.
4. Open WebUI settings (once; saved in its database):
   - **Admin > Integrations > Open Terminal > +:** URL `http://host.docker.internal:8000`, API key =
     `OPEN_TERMINAL_API_KEY` from `.env`, auth Bearer, toggle on.
   - **Workspace > Models > +** (optional): name **Agent**, base `gpt-oss:20b`, system prompt from
     `system-prompt.md`, Memory ticked, Advanced Params > Function Calling = Native.
   - Set automatically on a first start (from `docker-compose.yaml`): Ollama URL, default model, task model = chat
     model, follow-up and tags generation off, memory on.
5. In a chat, pick the terminal under the cloud icon next to `+`.

## Settings (`.env`)

Created by `setup`. Keep it private (git ignores it).

| Key | Default | |
|---|---|---|
| `WEBUI_SECRET_KEY`, `OPEN_TERMINAL_API_KEY` | random | |
| `DEFAULT_MODEL` | `gpt-oss:20b` | pulled by `setup`; first-start default in Open WebUI |
| `OT_CWD` | folder above this repo | where Open Terminal starts |
| `OT_HOST`, `OT_PORT` | see table above, `8000` | |
| `BACKUP_DIR` | `backups/` in this repo | |

## Files

| File | What |
|---|---|
| `agent.ps1`, `agent.cmd`, `agent-*.cmd` | Windows. |
| `agent.sh` | Linux, macOS. |
| `docker-compose.yaml` | Open WebUI; Ollama with the `docker-ollama` profile. |
| `docker-compose.gpu.yaml` | Added when an NVIDIA GPU is found. |
| `AGENTS.example.md` | Copied to the projects folder by `setup`: rules the model gets with every message. |
| `system-prompt.md` | Optional system prompt for an **Agent** model. |
| `*.log`, `*.pid` | Open Terminal (and native Ollama on macOS) logs and process ids. |

## What we found (why it is built this way)

- **Models in a Docker volume.** Through a bind mount of a Windows folder, `F:\models` read at ~140 MB/s; the volume
  reads at ~435 MB/s. gpt-oss:20b (13 GB) loads in ~100 s, then answers in ~1 s.
- **First message after `up` or a model switch waits for the load.** The model unloads after 30 idle minutes, which
  frees the GPU for games. Only one model fits in 16 GB VRAM.
- **Ollama native on macOS**: Docker on macOS can't use the GPU.
- **Open Terminal native**: in a Linux container it could not run Windows builds (MSYS2, Visual Studio).
- **Open WebUI keeps its own saved settings**: environment values only apply on a first start. A wrong saved Ollama
  URL shows as "No models available" and hides the custom models; fix it under Admin > Settings > Connections
  (gear icon). Ollama answers 403 to unknown host names (e.g. a Docker alias); `ollama` (same Docker network) and
  `host.docker.internal` work.
- **Context 32K, flash attention, q8_0 KV cache**: Ollama's default context (4096) is too small for an agent.
- **Ports on 127.0.0.1 only** (Linux: Open Terminal on the docker0 bridge address), Open Terminal accepts only
  `http://localhost:3000` (CORS) and needs its key. It is not a sandbox: it can do anything the user can. The
  no-delete / no-commit rules are instructions to the model, not limits.

## Checks

```
docker exec open-webui curl -s http://ollama:11434/api/version
```

```
docker exec open-webui curl -s http://host.docker.internal:8000/health
```

Loaded model and GPU share (`100% GPU` is best): `docker exec ollama ollama ps`

Commands the model sent to Open Terminal (Windows):

```
Select-String -Path open-terminal.log -Pattern "POST|/files|/execute" | Select-Object -Last 10
```

Logs: `docker logs ollama`, `docker logs open-webui`, `open-terminal.err.log` (startup, errors),
`open-terminal.log` (requests).
