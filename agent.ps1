# Local agent, Windows: Ollama, Open Terminal and Open WebUI in Docker. Needs only Docker Desktop.
# Usage: agent.ps1 setup | configure | up | down | status | backup | restore <file> | import-models <folder> | pull <model>
# agent-up.cmd / agent-down.cmd / agent-status.cmd call up / down / status.
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'configure', 'up', 'down', 'status', 'backup', 'restore', 'import-models', 'pull')]
    [string]$Action = 'status',
    [Parameter(Position = 1)][string]$Arg = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# ---------------------------------------------------------------- settings

$envFile = Join-Path $PSScriptRoot '.env'

function New-Secret {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

if (-not (Test-Path $envFile)) {
    @(
        "WEBUI_SECRET_KEY=$(New-Secret)"
        "OPEN_TERMINAL_API_KEY=$(New-Secret)"
    ) | Set-Content -Encoding ascii $envFile
    Write-Host 'Created .env (keys for Open WebUI and Open Terminal).'
}

# Appends lines to .env; first ends its last line if an editor saved it without a line break.
function Add-EnvLines([string[]]$lines) {
    $text = [IO.File]::ReadAllText($envFile)
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $lines = @('') + $lines }
    $lines | Add-Content -Encoding ascii $envFile
}

# SearXNG's secret (added to older .env files too).
if (-not (Select-String -Path $envFile -Pattern '^SEARXNG_SECRET=' -Quiet)) {
    Add-EnvLines @("SEARXNG_SECRET=$(New-Secret)")
}

# Admin login: creates the account on a fresh install; agent configure signs in with it.
if (-not (Select-String -Path $envFile -Pattern '^WEBUI_ADMIN_EMAIL=' -Quiet)) {
    Add-EnvLines @(
        'WEBUI_ADMIN_NAME=Admin'
        'WEBUI_ADMIN_EMAIL=admin@example.com'
        "WEBUI_ADMIN_PASSWORD=$(New-Secret)"
    )
    Write-Host 'Added an admin login to .env (WEBUI_ADMIN_*). If Open WebUI already has an account, put its login there.'
}

# Defaults; any of these can be set in .env.
$cfg = @{
    OT_CWD        = (Split-Path $PSScriptRoot -Parent)     # the projects folder this repo sits in
    BACKUP_DIR    = (Join-Path $PSScriptRoot 'backups')
    DEFAULT_MODEL = 'gpt-oss:20b'
}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
# Read by docker-compose.yaml.
$env:DEFAULT_MODEL = $cfg.DEFAULT_MODEL
$env:OT_CWD = $cfg.OT_CWD

# ---------------------------------------------------------------- docker

$hasGpu = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
$composeArgs = @('-f', 'docker-compose.yaml')
if ($hasGpu) { $composeArgs += @('-f', 'docker-compose.gpu.yaml') }
$composeArgs += @('--profile', 'docker-ollama', '--profile', 'docker-terminal')

# Pinned helper image for copying volumes (backup, restore, import-models).
$alpine = 'alpine:3.24.3'

function Invoke-Compose {
    docker compose @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $args failed (is Docker Desktop running?)." }
}

# Quiet check of a command's exit code. Through cmd: PowerShell 5.1 turns a native command's redirected stderr
# into an error.
function Test-Quiet([string]$command) {
    cmd /c "$command >nul 2>nul"
    $LASTEXITCODE -eq 0
}

function Wait-Ollama {
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Quiet 'docker exec ollama ollama list') { return }
        Start-Sleep -Seconds 1
    }
    throw 'Ollama did not answer. See: docker logs ollama'
}

function Start-Ollama {
    Invoke-Compose up -d ollama
    Wait-Ollama
}

# ---------------------------------------------------------------- backup

function Backup-WebUi {
    # Open WebUI must be stopped, so its database is consistent in the copy.
    # cache/ (downloaded embedding models etc.) is left out: Open WebUI fetches it again.
    New-Item -ItemType Directory -Force $cfg.BACKUP_DIR | Out-Null
    $name = "open-webui-$(Get-Date -Format 'yyyyMMdd-HHmmss').tgz"
    docker run --rm -v local-agent_open-webui_data:/data:ro -v "$($cfg.BACKUP_DIR):/backup" $alpine `
        tar czf "/backup/$name" --exclude=./cache -C /data .
    if ($LASTEXITCODE -ne 0) { throw 'Backup failed.' }
    Write-Host "Open WebUI backed up to $(Join-Path $cfg.BACKUP_DIR $name)"
}

function Restore-WebUi([string]$file) {
    if (-not $file -or -not (Test-Path $file)) { throw 'Usage: agent.ps1 restore <backup .tgz>' }
    $item = Get-Item $file
    Write-Host 'Saving the current data first, in case you want it back.'
    Backup-WebUi
    # find, not rm -rf /data/*: the * leaves hidden files behind.
    docker run --rm -v local-agent_open-webui_data:/data -v "$($item.DirectoryName):/backup:ro" $alpine `
        sh -c "find /data -mindepth 1 -delete && tar xzf '/backup/$($item.Name)' -C /data"
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    Write-Host "Open WebUI restored from $($item.FullName)"
}

# ---------------------------------------------------------------- configure

function Invoke-Configure {
    # Runs configure.py in a throwaway container of the Open WebUI image (it brings its own Python), on the stack's
    # network: nothing to install here. It signs in with WEBUI_ADMIN_* and sets the Ollama URL, the Open Terminal
    # connection, the knowledge bases from knowledge.conf and the Agent model.
    Invoke-Compose up -d open-webui
    # compose run: the same pinned image and network as the open-webui service.
    Invoke-Compose run --rm --no-deps --entrypoint python `
        -e PYTHONUNBUFFERED=1 -e PYTHONDONTWRITEBYTECODE=1 `
        -e 'OT_URL=http://open-terminal:8000' -e 'OLLAMA_URL=http://ollama:11434' `
        -v "$($PSScriptRoot):/agent:ro" -v "$($cfg.OT_CWD):/projects:ro" `
        open-webui /agent/configure.py
    if ($LASTEXITCODE -ne 0) { throw 'configure failed (message above).' }
}

# ---------------------------------------------------------------- setup

function Invoke-Setup {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker not found: install Docker Desktop.' }
    if (-not (Test-Quiet 'docker info')) { throw 'Docker is not running: start Docker Desktop.' }
    Write-Host 'Docker: ok'
    if ($hasGpu) { Write-Host 'NVIDIA GPU: ok' } else { Write-Host 'No NVIDIA GPU found: Ollama will run on the CPU (slow).' }

    Invoke-Compose pull
    Start-Ollama
    if (Test-Quiet "docker exec ollama ollama show $($cfg.DEFAULT_MODEL)") {
        Write-Host "Model $($cfg.DEFAULT_MODEL): ok"
    } else {
        docker exec ollama ollama pull $cfg.DEFAULT_MODEL
        if ($LASTEXITCODE -ne 0) { throw "Pulling $($cfg.DEFAULT_MODEL) failed." }
    }

    $agents = Join-Path $cfg.OT_CWD 'AGENTS.md'
    if (Test-Path $agents) { Write-Host "Kept $agents" }
    else { Copy-Item (Join-Path $PSScriptRoot 'AGENTS.example.md') $agents; Write-Host "Created $agents" }

    Invoke-Compose up -d --remove-orphans
    Invoke-Configure
    Write-Host "Setup done: http://localhost:3000 (login: WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD in .env)."
}

# ---------------------------------------------------------------- actions

switch ($Action) {
    'setup' { Invoke-Setup }
    'configure' { Invoke-Configure }
    'up' {
        Invoke-Compose up -d --remove-orphans
        Write-Host 'Open WebUI: http://localhost:3000'
    }
    'down' { Invoke-Compose down --remove-orphans }
    'status' { docker compose @composeArgs ps --format 'table {{.Name}}\t{{.Status}}' }
    { $_ -in 'backup', 'restore' } {
        # Open WebUI is stopped for a consistent copy, and started again only if it was running.
        $running = [bool](docker ps -q --filter 'name=^open-webui$')
        if ($running) { Invoke-Compose stop open-webui }
        try { if ($Action -eq 'backup') { Backup-WebUi } else { Restore-WebUi $Arg } }
        finally { if ($running) { Invoke-Compose start open-webui } }
    }
    'import-models' {
        # One-off: copy Ollama models from a folder (layout <folder>\models\blobs, manifests) into the volume.
        if (-not $Arg -or -not (Test-Path (Join-Path $Arg 'models'))) { throw 'Usage: agent.ps1 import-models <folder with a models subfolder>' }
        Invoke-Compose create ollama
        Invoke-Compose stop ollama
        Write-Host "Copying $Arg into the ollama_data volume (a Windows folder reads slowly, ~140 MB/s)..."
        docker run --rm -v "$($Arg):/src:ro" -v local-agent_ollama_data:/dst $alpine cp -a /src/models /dst/
        if ($LASTEXITCODE -ne 0) { throw 'Copy failed.' }
        Start-Ollama
        docker exec ollama ollama list
    }
    'pull' {
        if (-not $Arg) { throw 'Usage: agent.ps1 pull <model>' }
        Start-Ollama
        docker exec ollama ollama pull $Arg
    }
}
