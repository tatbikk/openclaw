[CmdletBinding()]
param(
  [ValidateSet('install', 'use-codex-login', 'preflight', 'smoke', 'harden', 'login', 'login-device', 'start', 'dashboard', 'auth', 'status', 'models', 'audit', 'audit-deep', 'doctor', 'relay-status', 'relay-write-on', 'relay-write-off')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

$OpenClawVersion = '2026.7.2-beta.7'
$CodexPluginVersion = '2026.7.2-beta.7'
$AcpxPluginVersion = '2026.7.2-beta.7'
$NodeVersion = '24.18.1'
$NodeArchiveSha256 = 'EC56B84A7551893AB2324EBDFDC4AB974A63B4781162600B68A1293CC3E53765'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LocalRoot = Join-Path $RepoRoot '.local\openclaw'
$NodeRoot = Join-Path $LocalRoot "node-v$NodeVersion-win-x64"
$RuntimeRoot = Join-Path $LocalRoot "runtime-$OpenClawVersion"
$StateDir = Join-Path $LocalRoot "state-$OpenClawVersion"
$ConfigPath = Join-Path $StateDir 'openclaw.json'
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$CliPath = Join-Path $RuntimeRoot 'node_modules\openclaw\dist\index.js'
$NodeExe = Join-Path $NodeRoot 'node.exe'
$NpmCmd = Join-Path $NodeRoot 'npm.cmd'
$NodeMarker = Join-Path $LocalRoot "node-$NodeVersion.installed"
$RuntimeMarker = Join-Path $LocalRoot "runtime-$OpenClawVersion.installed"
$PluginMarker = Join-Path $LocalRoot "codex-plugin-$CodexPluginVersion.installed"
$AcpxPluginMarker = Join-Path $LocalRoot "acpx-plugin-$AcpxPluginVersion.installed"
$ConfigMarker = Join-Path $LocalRoot "config-$OpenClawVersion.initialized"
$CodeWorkspace = Join-Path $LocalRoot 'code'
$AcpxStateDir = Join-Path $LocalRoot 'acpx'

function Set-OpenClawEnvironment {
  $env:PATH = "$NodeRoot;$env:PATH"
  $env:OPENCLAW_HOME = Join-Path $LocalRoot 'home'
  $env:XDG_CONFIG_HOME = Join-Path $LocalRoot 'config'
  $env:OPENCLAW_STATE_DIR = $StateDir
  $env:OPENCLAW_CONFIG_PATH = $ConfigPath
  $env:OPENCLAW_CONFIG_DIR = $StateDir
  $env:OPENCLAW_WORKSPACE_DIR = Join-Path $StateDir 'workspace'
  # Codex on Windows does not always infer the desktop app's home from USERPROFILE.
  # Pinning it makes the managed app-server see the existing ChatGPT subscription login.
  $env:CODEX_HOME = $CodexHome
}

function Invoke-OpenClaw {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)

  if (-not (Test-Path -LiteralPath $NodeExe) -or -not (Test-Path -LiteralPath $CliPath)) {
    throw 'OpenClaw is not installed. Run this script with the install action first.'
  }
  & $NodeExe $CliPath @CliArgs
  if ($LASTEXITCODE -ne 0) {
    throw "OpenClaw exited with code $LASTEXITCODE."
  }
}

function New-RandomHex {
  param([int]$ByteCount)

  $bytes = New-Object byte[] $ByteCount
  $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
  } finally {
    $generator.Dispose()
  }
  return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-ManagedCodexExe {
  $projectsRoot = Join-Path $StateDir 'npm\projects'
  if (-not (Test-Path -LiteralPath $projectsRoot)) {
    throw 'The managed Codex plugin is not installed. Run the install action first.'
  }

  $codexExe = [System.IO.Directory]::EnumerateFiles(
    $projectsRoot,
    'codex.exe',
    [System.IO.SearchOption]::AllDirectories
  ) | Where-Object { $_ -match '[\\/]@openai[\\/]codex-win32-x64[\\/]' } | Select-Object -First 1
  if (-not $codexExe) {
    throw 'The Codex plugin is installed without its managed Windows binary. Re-run install.'
  }
  return $codexExe
}

function Test-CodexSubscriptionPreflight {
  if ($env:OPENAI_API_KEY) {
    throw 'OPENAI_API_KEY is set. Remove it from this terminal before using subscription-only mode.'
  }
  $homeScope = ((& $NodeExe $CliPath config get plugins.entries.codex.config.appServer.homeScope 2>&1) -join "`n").Trim().Trim('"')
  if ($LASTEXITCODE -ne 0 -or $homeScope -eq 'user') {
    if (-not (Test-Path -LiteralPath (Join-Path $CodexHome 'auth.json'))) {
      throw "No Codex login exists under $CodexHome. Sign in to Codex with ChatGPT first."
    }

    $codexExe = Get-ManagedCodexExe
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $codexExe
    $startInfo.Arguments = 'login status'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $loginStatus = ($stdout + $stderr).Trim()
    $loginStatus | Write-Output
    if ($process.ExitCode -ne 0 -or $loginStatus -notmatch 'Logged in using ChatGPT') {
      throw "The managed Codex runtime cannot use the ChatGPT login under $CodexHome."
    }
  } else {
    $authStatus = ((& $NodeExe $CliPath models auth list --provider openai 2>&1) -join "`n").Trim()
    $authStatus | Write-Output
    if ($LASTEXITCODE -ne 0 -or $authStatus -notmatch 'openai') {
      throw 'No agent-scoped OpenAI OAuth profile is available. Run login or login-device first.'
    }
  }

  Invoke-OpenClaw config validate
  $primaryModel = ((& $NodeExe $CliPath config get agents.defaults.model.primary 2>&1) -join "`n").Trim().Trim('"')
  if ($LASTEXITCODE -ne 0 -or $primaryModel -notmatch '^openai/gpt-5\.(6-(sol|terra|luna)|5)$') {
    throw "Expected a subscription-backed OpenAI model, got: $primaryModel"
  }
  $runtimePath = 'agents.defaults.models["' + $primaryModel + '"].agentRuntime.id'
  $runtimeId = ((& $NodeExe $CliPath config get $runtimePath 2>&1) -join "`n").Trim().Trim('"')
  if ($LASTEXITCODE -ne 0 -or $runtimeId -ne 'codex') {
    throw "$primaryModel is not pinned to the Codex runtime."
  }
}

function Set-PrivateStateAcl {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    throw 'OpenClaw state does not exist. Run the install action first.'
  }
  $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & "$env:SystemRoot\System32\icacls.exe" $StateDir `
    '/inheritance:r' `
    '/grant:r' "*${userSid}:(OI)(CI)F" `
    '*S-1-5-18:(OI)(CI)F' | Write-Output
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to restrict the OpenClaw state ACL (icacls exit $LASTEXITCODE)."
  }
}

function Install-PortableNode {
  if ((Test-Path -LiteralPath $NodeMarker) -and (Test-Path -LiteralPath $NodeExe)) {
    return
  }

  New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null
  if (Test-Path -LiteralPath $NodeExe) {
    $installedVersion = (& $NodeExe --version).TrimStart('v')
    if ($LASTEXITCODE -eq 0 -and $installedVersion -eq $NodeVersion) {
      New-Item -ItemType File -Force -Path $NodeMarker | Out-Null
      return
    }
  }
  $expectedNodeRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $RepoRoot ".local\openclaw\node-v$NodeVersion-win-x64")
  )
  if ([System.IO.Path]::GetFullPath($NodeRoot) -ne $expectedNodeRoot) {
    throw "Refusing to replace unexpected Node path: $NodeRoot"
  }
  if (Test-Path -LiteralPath $NodeRoot) {
    Remove-Item -LiteralPath $NodeRoot -Recurse -Force
  }
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-node-" + [guid]::NewGuid().ToString('N'))
  $archivePath = Join-Path $tempRoot "node-v$NodeVersion-win-x64.zip"
  try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    & curl.exe --fail --location --silent --show-error `
      --output $archivePath `
      "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
    if ($LASTEXITCODE -ne 0) {
      throw "Node download exited with code $LASTEXITCODE."
    }
    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
    if ($actualSha256 -ne $NodeArchiveSha256) {
      throw "Node archive checksum mismatch: expected $NodeArchiveSha256, got $actualSha256."
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $LocalRoot
    $installedVersion = (& $NodeExe --version).TrimStart('v')
    if ($LASTEXITCODE -ne 0 -or $installedVersion -ne $NodeVersion) {
      throw "The extracted Node runtime did not report version $NodeVersion."
    }
    New-Item -ItemType File -Force -Path $NodeMarker | Out-Null
  } finally {
    if (Test-Path -LiteralPath $archivePath) {
      Remove-Item -LiteralPath $archivePath -Force
    }
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Force
    }
  }
}

function Initialize-OpenClawConfig {
  if ((Test-Path -LiteralPath $ConfigMarker) -and (Test-Path -LiteralPath $ConfigPath)) {
    return
  }

  $operations = @()
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    # A fresh config is one product artifact. Writing it atomically avoids loading
    # every plugin just to execute eight first-boot `config set` operations.
    $initialConfig = [ordered]@{
      gateway = [ordered]@{
        mode = 'local'
        bind = 'loopback'
        auth = [ordered]@{
          mode = 'token'
          token = (New-RandomHex -ByteCount 32)
        }
      }
      agents = [ordered]@{
        defaults = [ordered]@{
          model = [ordered]@{ primary = 'openai/gpt-5.6-sol' }
          models = [ordered]@{
            'openai/gpt-5.6-sol' = [ordered]@{
              agentRuntime = [ordered]@{ id = 'codex' }
            }
          }
        }
      }
      # Relay path: acpx runs the real Codex CLI and Claude Code as ACP
      # harnesses, and a bound conversation forwards messages to them without an
      # OpenClaw model turn. Local default stays read-only; use relay-write-on to
      # let a harness write files and run commands on this machine.
      acp = [ordered]@{
        enabled = $true
        dispatch = [ordered]@{ enabled = $true }
        backend = 'acpx'
        defaultAgent = 'codex'
        allowedAgents = @('codex', 'claude')
        stream = [ordered]@{ deliveryMode = 'live' }
      }
      plugins = [ordered]@{
        allow = @('openai', 'codex', 'acpx')
        entries = [ordered]@{
          codex = [ordered]@{ enabled = $true }
          acpx = [ordered]@{
            enabled = $true
            config = [ordered]@{
              cwd = $CodeWorkspace
              stateDir = $AcpxStateDir
              probeAgent = 'codex'
              permissionMode = 'approve-reads'
              nonInteractivePermissions = 'deny'
            }
          }
        }
      }
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $initialPath = Join-Path $StateDir ('.openclaw-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
      [System.IO.File]::WriteAllText(
        $initialPath,
        (ConvertTo-Json -InputObject $initialConfig -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
      )
      Move-Item -LiteralPath $initialPath -Destination $ConfigPath
      New-Item -ItemType File -Force -Path $ConfigMarker | Out-Null
    } finally {
      if (Test-Path -LiteralPath $initialPath) {
        Remove-Item -LiteralPath $initialPath -Force
      }
    }
    return
  } else {
    $defaults = @(
      @{ path = 'gateway.mode'; value = 'local' }
      @{ path = 'gateway.bind'; value = 'loopback' }
      @{ path = 'gateway.auth.mode'; value = 'token' }
      @{ path = 'gateway.auth.token'; value = $null }
      @{ path = 'agents.defaults.model.primary'; value = 'openai/gpt-5.6-sol' }
      @{ path = 'agents.defaults.models["openai/gpt-5.6-sol"].agentRuntime.id'; value = 'codex' }
      @{ path = 'plugins.allow'; value = @('openai', 'codex', 'acpx') }
      @{ path = 'plugins.entries.codex.enabled'; value = $true }
      @{ path = 'acp.enabled'; value = $true }
      @{ path = 'acp.dispatch.enabled'; value = $true }
      @{ path = 'acp.backend'; value = 'acpx' }
      @{ path = 'acp.defaultAgent'; value = 'codex' }
      @{ path = 'acp.allowedAgents'; value = @('codex', 'claude') }
      @{ path = 'acp.stream.deliveryMode'; value = 'live' }
      @{ path = 'plugins.entries.acpx.enabled'; value = $true }
      @{ path = 'plugins.entries.acpx.config.cwd'; value = $CodeWorkspace }
      @{ path = 'plugins.entries.acpx.config.stateDir'; value = $AcpxStateDir }
      @{ path = 'plugins.entries.acpx.config.probeAgent'; value = 'codex' }
      @{ path = 'plugins.entries.acpx.config.permissionMode'; value = 'approve-reads' }
      @{ path = 'plugins.entries.acpx.config.nonInteractivePermissions'; value = 'deny' }
    )
    foreach ($default in $defaults) {
      & $NodeExe $CliPath config get $default.path *> $null
      if ($LASTEXITCODE -eq 0) {
        continue
      }
      $value = $default.value
      if ($default.path -eq 'gateway.auth.token') {
        $value = New-RandomHex -ByteCount 32
      }
      $operations += @{ path = $default.path; value = $value }
    }
  }

  if ($operations.Count -eq 0) {
    New-Item -ItemType File -Force -Path $ConfigMarker | Out-Null
    return
  }

  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $batchPath = Join-Path $LocalRoot ("initial-config-" + [guid]::NewGuid().ToString('N') + '.json')
  try {
    [System.IO.File]::WriteAllText(
      $batchPath,
      (ConvertTo-Json -InputObject $operations -Compress),
      [System.Text.UTF8Encoding]::new($false)
    )
    Invoke-OpenClaw config set --batch-file $batchPath
    New-Item -ItemType File -Force -Path $ConfigMarker | Out-Null
  } finally {
    if (Test-Path -LiteralPath $batchPath) {
      Remove-Item -LiteralPath $batchPath -Force
    }
  }
}

function Get-OpenClawConfigValue {
  param([Parameter(Mandatory = $true)][string]$Path)

  $value = ((& $NodeExe $CliPath config get $Path 2>&1) -join "`n").Trim().Trim('"')
  if ($LASTEXITCODE -ne 0) {
    return '<unset>'
  }
  return $value
}

function Show-RelayStatus {
  $paths = @(
    'acp.enabled'
    'acp.backend'
    'acp.defaultAgent'
    'acp.allowedAgents'
    'plugins.entries.acpx.enabled'
    'plugins.entries.acpx.config.cwd'
    'plugins.entries.acpx.config.permissionMode'
    'plugins.entries.acpx.config.nonInteractivePermissions'
  )
  foreach ($path in $paths) {
    '{0} = {1}' -f $path, (Get-OpenClawConfigValue -Path $path) | Write-Output
  }

  if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
    'claude auth: CLAUDE_CODE_OAUTH_TOKEN is set in this terminal' | Write-Output
  } elseif ($env:ANTHROPIC_API_KEY) {
    'claude auth: ANTHROPIC_API_KEY is set in this terminal (API billing, not subscription)' | Write-Output
  } else {
    'claude auth: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; the claude harness will fail' | Write-Output
  }

  'Bind a relay from the Control UI chat with: /acp spawn codex --bind here' | Write-Output
}

function Set-RelayWriteAccess {
  param([Parameter(Mandatory = $true)][bool]$Enabled)

  # An ACP harness has no TTY, so approve-all is the only mode that lets it write
  # files and run commands. OpenClaw does not sandbox ACP harness execution, so on
  # this machine approve-all means the coding CLI acts with your account's rights.
  if ($Enabled) {
    Invoke-OpenClaw config set plugins.entries.acpx.config.permissionMode approve-all
    Invoke-OpenClaw config set plugins.entries.acpx.config.nonInteractivePermissions fail
    'Relay harnesses may now write files and run commands as your Windows account. Restart the gateway.' | Write-Output
  } else {
    Invoke-OpenClaw config set plugins.entries.acpx.config.permissionMode approve-reads
    Invoke-OpenClaw config set plugins.entries.acpx.config.nonInteractivePermissions deny
    'Relay harnesses are read-only again; writes and exec are declined. Restart the gateway.' | Write-Output
  }
}

function Install-LocalOpenClaw {
  Install-PortableNode
  Set-OpenClawEnvironment

  if (-not (Test-Path -LiteralPath $RuntimeMarker)) {
    $expectedRuntimeRoot = [System.IO.Path]::GetFullPath(
      (Join-Path $RepoRoot ".local\openclaw\runtime-$OpenClawVersion")
    )
    if ([System.IO.Path]::GetFullPath($RuntimeRoot) -ne $expectedRuntimeRoot) {
      throw "Refusing to replace unexpected runtime path: $RuntimeRoot"
    }
    if (Test-Path -LiteralPath $RuntimeRoot) {
      Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
    & $NpmCmd install --prefix $RuntimeRoot --ignore-scripts "openclaw@$OpenClawVersion"
    if ($LASTEXITCODE -ne 0) {
      throw "npm install exited with code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $CliPath)) {
      throw "npm completed without installing the OpenClaw CLI at $CliPath."
    }
    & $NodeExe $CliPath --version
    if ($LASTEXITCODE -ne 0) {
      throw "The installed OpenClaw CLI failed its version check with code $LASTEXITCODE."
    }
    New-Item -ItemType File -Force -Path $RuntimeMarker | Out-Null
  }

  New-Item -ItemType Directory -Force -Path $CodeWorkspace | Out-Null
  New-Item -ItemType Directory -Force -Path $AcpxStateDir | Out-Null
  Initialize-OpenClawConfig
  if (-not (Test-Path -LiteralPath $PluginMarker)) {
    Invoke-OpenClaw plugins install "@openclaw/codex@$CodexPluginVersion" --pin
    New-Item -ItemType File -Force -Path $PluginMarker | Out-Null
  }
  if (-not (Test-Path -LiteralPath $AcpxPluginMarker)) {
    Invoke-OpenClaw plugins install "@openclaw/acpx@$AcpxPluginVersion" --pin
    New-Item -ItemType File -Force -Path $AcpxPluginMarker | Out-Null
  }
  Set-PrivateStateAcl
  Invoke-OpenClaw config validate
  Invoke-OpenClaw --version
}

Set-OpenClawEnvironment

switch ($Action) {
  'install' { Install-LocalOpenClaw }
  'use-codex-login' {
    Invoke-OpenClaw config set plugins.entries.codex.config.appServer.homeScope user
    Test-CodexSubscriptionPreflight
  }
  'preflight' { Test-CodexSubscriptionPreflight }
  'smoke' {
    Test-CodexSubscriptionPreflight
    Invoke-OpenClaw agent --local --agent main --message 'Reply exactly: OK' --json --timeout 120
  }
  'harden' { Set-PrivateStateAcl }
  'login' {
    Invoke-OpenClaw config set plugins.entries.codex.config.appServer.homeScope agent
    Invoke-OpenClaw models auth login --provider openai --method oauth
  }
  'login-device' {
    Invoke-OpenClaw config set plugins.entries.codex.config.appServer.homeScope agent
    Invoke-OpenClaw models auth login --provider openai --device-code
  }
  'start' { Invoke-OpenClaw gateway --bind loopback --port 18789 }
  'dashboard' { Invoke-OpenClaw dashboard }
  'auth' { Invoke-OpenClaw models auth list --provider openai }
  'status' { Invoke-OpenClaw models status }
  'models' { Invoke-OpenClaw models list --provider openai }
  'audit' { Invoke-OpenClaw security audit }
  'audit-deep' { Invoke-OpenClaw security audit --deep }
  'doctor' { Invoke-OpenClaw doctor --fix }
  'relay-status' { Show-RelayStatus }
  'relay-write-on' { Set-RelayWriteAccess -Enabled $true }
  'relay-write-off' { Set-RelayWriteAccess -Enabled $false }
}
