# Local agent

A local AI coding agent in the browser: Open WebUI + Ollama + Open Terminal. It reads and edits files in the
projects folder this repo sits in (`<projects>/local-agent`), runs commands, searches the web, and follows the
`AGENTS.md` rules. Only web search queries leave the computer (through SearXNG, no account or key).

## Needs

- **Docker** (Windows, macOS: Docker Desktop; Linux: Docker Engine + NVIDIA Container Toolkit for a GPU).
- **macOS:** Ollama from https://ollama.com/download (Docker on macOS has no GPU).
- **Windows:** in Docker Desktop, set Settings > VM resources > Disk image location to a drive with room for the
  models (~15 GB each). Nothing else is installed on the computer.

## GPU

| | Windows | Linux | macOS |
|---|---|---|---|
| NVIDIA | yes (tested) | yes, untested (NVIDIA Container Toolkit) | - |
| Apple Silicon | - | - | yes, untested (native Ollama, Metal) |
| AMD | no: Docker Desktop passes only NVIDIA GPUs to containers, Ollama would run on the CPU | not yet: needs Ollama's ROCm image | - |
| none | CPU only: works, very slow | CPU only | - |

## Start

| Windows | Linux, macOS | |
|---|---|---|
| `agent.cmd setup` | `./agent.sh setup` | Everything below, once. Safe to run again. |
| `agent-up.cmd` | `./agent.sh up` | Start (also after every reboot: nothing starts on its own). |
| `agent-down.cmd` | `./agent.sh down` | Stop (data and models are kept). |

`setup` creates `.env` (keys, admin login), pulls the images and the default model, puts `AGENTS.md` in the
projects folder if none is there, starts everything and runs `configure`. Then open http://localhost:3000 and sign in
with `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` from `.env`.

**Open WebUI already has an account?** Put that admin's login in `.env` (`WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`)
before `setup` / `configure`.

## What `configure` sets (rerun after changing its inputs)

| In Open WebUI | From |
|---|---|
| Ollama connection | per OS |
| Open Terminal connection + key | `OPEN_TERMINAL_API_KEY` in `.env` |
| Web search: SearXNG, 3 results | `docker-compose.yaml`, `searxng/settings.yml` |
| Knowledge bases | `knowledge.conf` (copy `knowledge.example.conf`; git ignores it) |
| **Agent** model: base model, system prompt, terminal and web search on, memory, native tool calls, knowledge | `DEFAULT_MODEL`, `system-prompt.md`, `knowledge.conf` |
| Default model for new chats: Agent | - |

First start only (from `docker-compose.yaml`): admin account, default model, task model = chat model, follow-up and
tags generation off, memory on, English interface. A browser that already chose a language keeps it: Settings >
General > Language. The Agent answers in English (`system-prompt.md`).

## Other commands

`agent.cmd <command>` / `./agent.sh <command>`:

| Command | |
|---|---|
| `status` | What is running. |
| `pull <model>` | Download a model. |
| `import-models <folder>` | Copy existing Ollama models (a folder with `models/`) into the volume. |
| `backup` / `restore <file>` | Open WebUI data (agents, knowledge, memories, chats) to/from `BACKUP_DIR`. `restore` backs up the current data first. |

## Settings (`.env`, private)

| Key | Default |
|---|---|
| `DEFAULT_MODEL` | `gpt-oss:20b` |
| `OT_CWD` | the folder above this repo |
| `BACKUP_DIR` | `backups/` here |

## Good to know

- Only one model fits in 16 GB VRAM. The first message after a start or a model switch waits for the load (~100 s
  for 13 GB), then answers take about a second. The model unloads after 30 idle minutes, freeing the GPU.
- Models live in a Docker volume: a Windows folder mounted into a container reads ~3x slower and made loads take
  minutes.
- Open WebUI keeps settings in its database: `docker-compose.yaml` values only apply on a first start; later changes
  go through `configure` or the UI.
- Ports listen on this computer only. Open Terminal has no port: only Open WebUI reaches it, with its key.
- The agent's terminal is a Linux shell in a container (every OS): it sees the projects folder as `~/projects`,
  nothing else of the computer, and Windows programs (MSYS2, Visual Studio) are not available. It can change or
  delete anything in the projects folder: the no-delete / no-commit rules in `AGENTS.md` are instructions to the
  model, not limits.
- Web search: the model searches when it needs to, or turn on Web Search in a chat (next to `+`). Each search
  adds the results to the model's context, so those answers take a little longer. SearXNG uses ~100-150 MB RAM.
- Fixed versions, tested together: Ollama 0.40.13, Open WebUI 0.12.4, Open Terminal 0.14.6, SearXNG
  2026.10.27-b5ed73fcb (`docker-compose.yaml`). To upgrade: change them there, test, commit.
- Tested on Windows 11 with an NVIDIA GPU. Linux and macOS: not tested yet. Open Terminal in Docker on Windows:
  not tested yet.

## Troubleshooting

| Symptom | Check |
|---|---|
| "No models available" | `configure` (or Admin > Settings > Connections > Ollama, gear icon). |
| Agent doesn't use files | Cloud icon next to `+` in the chat: the terminal must be selected. |
| Slow or no answer | `docker exec ollama ollama ps` (macOS: `ollama ps`): the model, and `100% GPU`. |
| Terminal errors | `docker logs open-terminal`. |
| Anything else | `docker logs open-webui`, `docker logs ollama`. |
