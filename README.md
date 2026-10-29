# Local agent

A local AI coding agent in the browser: Open WebUI + Ollama + Open Terminal. It reads and edits files in the
projects folder this repo sits in (`<projects>/local-agent`), runs commands, and follows the `AGENTS.md` rules.
Nothing leaves the computer.

## Needs

- **Docker** (Windows, macOS: Docker Desktop; Linux: Docker Engine + NVIDIA Container Toolkit for a GPU).
- **macOS:** Ollama from https://ollama.com/download (Docker on macOS has no GPU).
- **Windows:** in Docker Desktop, set Settings > VM resources > Disk image location to a drive with room for the
  models (~15 GB each). `setup` installs uv, which runs Open Terminal natively so the agent can use Windows tools.

## Start

| Windows | Linux, macOS | |
|---|---|---|
| `agent.cmd setup` | `./agent.sh setup` | Everything below, once. Safe to run again. |
| `agent-up.cmd` | `./agent.sh up` | Start. |
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
| Knowledge bases | `knowledge.conf` (copy `knowledge.example.conf`; git ignores it) |
| **Agent** model: base model, system prompt, terminal pre-selected, memory, native tool calls, knowledge | `DEFAULT_MODEL`, `system-prompt.md`, `knowledge.conf` |

First start only (from `docker-compose.yaml`): admin account, default model, task model = chat model, follow-up and
tags generation off, memory on.

## Other commands

`agent.cmd <command>` / `./agent.sh <command>`:

| Command | |
|---|---|
| `status` | What is running. |
| `pull <model>` | Download a model. |
| `import-models <folder>` | Copy existing Ollama models (a folder with `models/`) into the volume. |
| `backup` / `restore <file>` | Open WebUI data (agents, knowledge, memories, chats) to/from `BACKUP_DIR`. |

## Settings (`.env`, private)

| Key | Default |
|---|---|
| `DEFAULT_MODEL` | `gpt-oss:20b` |
| `OT_CWD` | the folder above this repo |
| `BACKUP_DIR` | `backups/` here |
| `OT_PORT` (Windows) | `8000` |

## Good to know

- Only one model fits in 16 GB VRAM. The first message after a start or a model switch waits for the load (~100 s
  for 13 GB), then answers take about a second. The model unloads after 30 idle minutes, freeing the GPU.
- Models live in a Docker volume: a Windows folder mounted into a container reads ~3x slower and made loads take
  minutes.
- Open WebUI keeps settings in its database: `docker-compose.yaml` values only apply on a first start; later changes
  go through `configure` or the UI.
- Ports listen on this computer only. Open Terminal needs its key and accepts only `http://localhost:3000`.
  It is not a sandbox: it can do anything your user can; the no-delete / no-commit rules in `AGENTS.md` are
  instructions to the model, not limits.
- Versions are pinned (tested together): Ollama 0.40.13, Open WebUI 0.12.4, Open Terminal 0.14.6 (Docker image: the 2026-10-29 build), by digest in
  `docker-compose.yaml` and `agent.ps1`. To upgrade: change them there, test, commit.
- Tested on Windows 11 with an NVIDIA GPU. Linux and macOS: not tested yet.

## Troubleshooting

| Symptom | Check |
|---|---|
| "No models available" | `configure` (or Admin > Settings > Connections > Ollama, gear icon). |
| Agent doesn't use files | Cloud icon next to `+` in the chat: the terminal must be selected. |
| Slow or no answer | `docker exec ollama ollama ps` (macOS: `ollama ps`): the model, and `100% GPU`. |
| Terminal errors (Windows) | `open-terminal.err.log`; requests in `open-terminal.log`. |
| Anything else | `docker logs open-webui`, `docker logs ollama`. |
