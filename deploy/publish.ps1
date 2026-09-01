<#
.SYNOPSIS
  Build and publish the RunPod images for this repository.

.DESCRIPTION
  Run this yourself: it needs a registry login that only you should perform.
  Authenticate first in your own terminal, so no credential is ever passed as an
  argument or stored in this repository:

      docker login ghcr.io          # or docker.io, or your private registry

  Then publish. RunPod runs linux/amd64, so both images are built for that
  platform explicitly.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy/publish.ps1 -Registry ghcr.io/tatbikk

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy/publish.ps1 -Registry ghcr.io/tatbikk -Target pod -SkipPush
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Registry,

  [string]$Tag = '2026.7.2-beta.7',

  [ValidateSet('pod', 'serverless', 'both')]
  [string]$Target = 'both',

  [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$Images = @(
  @{
    Key        = 'pod'
    Dockerfile = 'deploy/runpod/Dockerfile'
    Name       = 'openclaw-runpod'
    Purpose    = 'always-on Telegram Pod (paths 2 and 3)'
  }
  @{
    Key        = 'serverless'
    Dockerfile = 'deploy/runpod-serverless/Dockerfile'
    Name       = 'openclaw-serverless'
    Purpose    = 'stateless one-call endpoint (path 1)'
  }
)

# Windows PowerShell promotes any native stderr line to a terminating error while
# $ErrorActionPreference is 'Stop'. Docker writes progress to stderr, so every
# docker call runs with that promotion disabled and is judged by its exit code.
function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Command,
    [switch]$Quiet
  )

  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) {
      & $Command 2>&1 | Out-Null
    } else {
      & $Command 2>&1 | ForEach-Object { Write-Output $_ }
    }
  } finally {
    $ErrorActionPreference = $previous
  }
  return $LASTEXITCODE
}

function Assert-DockerReady {
  if ((Invoke-Native -Command { docker ps } -Quiet) -ne 0) {
    throw @'
The Docker daemon is not reachable.

Docker Desktop's Linux engine needs a WSL2 distribution. If `wsl -l -v` reports
no distributions, install the WSL kernel and let Docker Desktop recreate its
backend:

    wsl --install --no-distribution
    (reboot, then start Docker Desktop)

Alternatively switch Docker Desktop to the Hyper-V backend in
Settings > General.
'@
  }
}

function Invoke-BuildImage {
  param([hashtable]$Image)

  $reference = "$Registry/$($Image.Name):$Tag"
  $dockerfile = Join-Path $RepoRoot $Image.Dockerfile
  Write-Output ""
  Write-Output "==> building $reference  [$($Image.Purpose)]"
  $exitCode = Invoke-Native -Command {
    docker build --platform linux/amd64 -f $dockerfile -t $reference $RepoRoot
  }
  if ($exitCode -ne 0) {
    throw "docker build failed for $($Image.Dockerfile) (exit $exitCode)."
  }
  return $reference
}

function Invoke-PushImage {
  param([string]$Reference)

  Write-Output "==> pushing $Reference"
  $exitCode = Invoke-Native -Command { docker push $Reference }
  if ($exitCode -ne 0) {
    throw @"
docker push failed for $Reference (exit $exitCode).

If this is an authentication error, run 'docker login <registry>' in your own
terminal and retry. This script never handles credentials.
"@
  }
}

Assert-DockerReady

$selected = $Images | Where-Object { $Target -eq 'both' -or $_.Key -eq $Target }
$published = @()

foreach ($image in $selected) {
  $reference = Invoke-BuildImage -Image $image
  if ($SkipPush) {
    Write-Output "==> skipping push for $reference (-SkipPush)"
  } else {
    Invoke-PushImage -Reference $reference
  }
  $published += $reference
}

Write-Output ""
Write-Output "Done. Image references for the RunPod console:"
foreach ($reference in $published) {
  Write-Output "  $reference"
}
Write-Output ""
Write-Output "Next: create the RunPod Secrets (openclaw_gateway_token,"
Write-Output "telegram_bot_token, and claude_code_oauth_token for the Claude relay),"
Write-Output "then follow deploy/runpod/README.md and deploy/runpod-serverless/README.md."
