#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Setup', 'Maintain', 'Status', 'Backup', 'Admin')]
    [string] $Action = 'Status',
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config/local.json'),
    [string] $WslDistribution = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7 may otherwise turn native stderr (including SSH diagnostics) into errors.
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'scripts/config.ps1')
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3')
$remoteDir = $null
$localDir = $null

function Invoke-Wsl([string[]] $Command) {
    $wslOptions = @()
    if ($WslDistribution) { $wslOptions += @('--distribution', $WslDistribution) }
    # Login Bash loads the Linux user's profile (including an existing agent setup).
    # Quote each argument for Bash; never interpolate paths into executable shell code.
    $shellCommand = ($Command | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
    & wsl.exe @wslOptions --exec bash -lc $shellCommand
    if ($LASTEXITCODE -ne 0) { throw "WSL $($Command[0]) failed (exit $LASTEXITCODE). Check the selected distribution and Linux SSH setup." }
}

function ConvertTo-WslPath([string] $Path) {
    $windowsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $output = Invoke-Wsl @('wslpath', '-a', '-u', $windowsPath)
    $linuxPath = ($output -join "`n").Trim()
    if (-not $linuxPath.StartsWith('/') -or $linuxPath.Contains("`n")) {
        throw "Unexpected wslpath output for $Path. Ensure the Linux login profile prints no banners."
    }
    return $linuxPath
}

function Invoke-PiAction([string] $RemoteAction) {
    Write-Host "AdGuard Home: $RemoteAction"
    # A real terminal permits sudo's password prompt; installer/package input is disabled on the Pi.
    Invoke-Wsl (@('ssh') + $sshOptions + @('-tt', 'dns-server', "sudo bash '$remoteDir/run.sh' '$RemoteAction' '$remoteDir'"))
}

function Save-PiBackup([switch] $AllowMissing) {
    if ($AllowMissing) { Invoke-PiAction 'backup-if-installed' } else { Invoke-PiAction 'backup' }
    $statePath = ConvertTo-WslPath (Join-Path $localDir 'backup-state')
    Invoke-Wsl (@('scp') + $sshOptions + @("dns-server:$remoteDir/backup-state", $statePath))
    $state = (Get-Content -Raw -LiteralPath (Join-Path $localDir 'backup-state')).Trim()
    if ($state -eq 'absent' -and $AllowMissing) { return }
    if ($state -ne 'ready') { throw "Unexpected backup result: $state" }
    $backupDir = Join-Path $PSScriptRoot ('backups/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $backupDir
    $zipPath = ConvertTo-WslPath (Join-Path $backupDir 'adguard-home.zip')
    Invoke-Wsl (@('scp') + $sshOptions + @("dns-server:$remoteDir/backup.zip", $zipPath))
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $backupDir 'adguard-home.zip'))
    try {
        if (-not ($zip.Entries.FullName -contains 'AdGuardHome/AdGuardHome.yaml') -or
            -not ($zip.Entries.FullName -contains 'AdGuardHome/AdGuardHome')) {
            throw 'Backup is missing AdGuard Home configuration or binary; stopping before changes.'
        }
    } finally { $zip.Dispose() }
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir 'local.json')
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $backupDir 'adguard-home.zip')
    Set-Content -Encoding Ascii -LiteralPath (Join-Path $backupDir 'SHA256.txt') -Value "$($hash.Hash)  adguard-home.zip"
    Write-Host "Backup saved: $backupDir"
}

try {
    $null = Get-Command wsl.exe -ErrorAction Stop
    if ($Action -eq 'Admin') {
        Write-Host 'Open http://127.0.0.1:3000 in your Windows browser. Keep this tunnel open; Ctrl+C closes it.'
        Invoke-Wsl (@('ssh') + $sshOptions + @('-N', '-o', 'ExitOnForwardFailure=yes', '-L', '127.0.0.1:3000:127.0.0.1:3000', 'dns-server'))
        return
    }
    $shellConfig = Read-PiConfiguration $ConfigPath
    $localDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dns-server-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $localDir
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $localDir 'config.env'), $shellConfig, $utf8)
    # Normalize even when Git for Windows checked Bash out with CRLF.
    $backend = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scripts/run.sh')).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText((Join-Path $localDir 'run.sh'), $backend, $utf8)
    $helper = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scripts/adguard.py')).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText((Join-Path $localDir 'adguard.py'), $helper, $utf8)
    $remoteOutput = Invoke-Wsl (@('ssh') + $sshOptions + @('dns-server', 'umask 077; mktemp -d /tmp/dns-server.XXXXXXXXXX'))
    $remoteDir = ($remoteOutput -join "`n").Trim()
    if ($remoteDir -cnotmatch '^/tmp/dns-server\.[a-zA-Z0-9]{10}$') {
        $remoteDir = $null
        throw 'Unexpected SSH output; ensure noninteractive shell startup prints no banners to stdout.'
    }
    $runPath = ConvertTo-WslPath (Join-Path $localDir 'run.sh')
    $envPath = ConvertTo-WslPath (Join-Path $localDir 'config.env')
    $helperPath = ConvertTo-WslPath (Join-Path $localDir 'adguard.py')
    Invoke-Wsl (@('scp') + $sshOptions + @($runPath, $envPath, $helperPath, "dns-server:$remoteDir/"))
    switch ($Action) {
        'Setup' { Save-PiBackup -AllowMissing; Invoke-PiAction 'setup' }
        'Maintain' { Save-PiBackup; Invoke-PiAction 'maintain' }
        'Status' { Invoke-PiAction 'status' }
        'Backup' { Save-PiBackup }
    }
    Write-Host "$Action completed."
} finally {
    # Only remove the exact random staging paths created by this invocation.
    if ($remoteDir -and $remoteDir -cmatch '^/tmp/dns-server\.[a-zA-Z0-9]{10}$') {
        try { Invoke-Wsl (@('ssh') + $sshOptions + @('dns-server', "rm -rf -- '$remoteDir'")) }
        catch { Write-Warning "Remote staging cleanup failed: $remoteDir. $_" }
    }
    if ($localDir) {
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedLocal = [System.IO.Path]::GetFullPath($localDir)
        if ($resolvedLocal.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($resolvedLocal) -match '^dns-server-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedLocal -Recurse -Force
        }
    }
}
