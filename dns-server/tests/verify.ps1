#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'scripts/config.ps1')

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-Throws([scriptblock] $Operation, [string] $Message) {
    $caught = $false
    try { & $Operation | Out-Null } catch { $caught = $true }
    Assert $caught $Message
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dns-server-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $codeFiles = @((Get-Item (Join-Path $project 'manage.ps1')))
    $codeFiles += @(Get-ChildItem -LiteralPath (Join-Path $project 'scripts'), (Join-Path $project 'tests') -Recurse -Filter *.ps1)
    foreach ($file in $codeFiles) {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        Assert ($errors.Count -eq 0) "PowerShell parse errors: $($file.FullName)"
    }
    $example = Join-Path $project 'config/example.json'
    $valid = Read-PiConfiguration $example
    Assert ($valid.Contains("PI_CIDR='192.168.50.2/24'")) 'CIDR conversion'
    Assert ($valid.Contains('UPSTREAMS=''["https://dns.quad9.net/dns-query"]''')) 'Encrypted upstream serialization'
    Assert ($valid.Contains('BOOTSTRAP_DNS=''["9.9.9.9","149.112.112.112"]''')) 'Bootstrap resolver serialization'
    $invalidPath = Join-Path $testRoot 'invalid.json'
    $invalidCases = @(
        @{ ipv4 = '192.168.51.2' },
        @{ ipv4 = '192.168.50.0' },
        @{ ipv4 = '192.168.50.255' },
        @{ ipv4 = '999.168.50.2' },
        @{ ipv4 = '192.168.50.02' },
        @{ lan_subnet = '192.168.50.2/24' },
        @{ lan_subnet = '192.168.50.0/33' },
        @{ upstream_dns = @() },
        @{ upstream_dns = @('127.0.0.1') },
        @{ upstream_dns = @('192.168.50.2') },
        @{ upstream_dns = '9.9.9.9' },
        @{ upstream_dns = @('https://127.0.0.1/dns-query') },
        @{ upstream_dns = @('http://dns.example.org/dns-query') },
        @{ upstream_dns = @('https://user:password@dns.example.org/dns-query') },
        @{ upstream_dns = @('tls://dns.example.org/bad-path') },
        @{ bootstrap_dns = @() },
        @{ bootstrap_dns = @('https://dns.example.org/dns-query') },
        @{ hostname = 'dns-server; touch /tmp/injected' },
        @{ timezone = '../etc/passwd' },
        @{ interface = 'eth0$(id)' },
        @{ dns_test_name = '-bad.example' }
    )
    foreach ($case in $invalidCases) {
        $config = Get-Content -Raw -LiteralPath $example | ConvertFrom-Json
        foreach ($key in $case.Keys) { $config.$key = $case[$key] }
        [IO.File]::WriteAllText($invalidPath, ($config | ConvertTo-Json))
        Assert-Throws { Read-PiConfiguration $invalidPath } "Reject invalid configuration: $($case | ConvertTo-Json -Compress)"
    }
    $config = Get-Content -Raw -LiteralPath $example | ConvertFrom-Json
    $config.upstream_dns = @('2606:4700:4700::1111')
    [IO.File]::WriteAllText($invalidPath, ($config | ConvertTo-Json))
    Assert ((Read-PiConfiguration $invalidPath).Contains('UPSTREAMS=''["2606:4700:4700::1111"]''')) 'Single IPv6 upstream remains an array'

    # Run the real entry point in an isolated copy with a WSL process stub.
    # No network commands execute, and test backups never enter the real repository.
    Copy-Item -LiteralPath (Join-Path $project 'manage.ps1') -Destination $testRoot
    Copy-Item -LiteralPath (Join-Path $project 'scripts') -Destination $testRoot -Recurse
    $null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'config')
    Copy-Item -LiteralPath $example -Destination (Join-Path $testRoot 'config/local.json')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $global:dnsServerTest = @{
        Calls = [Collections.Generic.List[string]]::new()
        Fail = ''; State = 'ready'; Distribution = ''; Paths = @{}
    }
    function ssh.exe { throw 'Windows SSH must never be used.' }
    function scp.exe { throw 'Windows SCP must never be used.' }
    function Invoke-TestSsh {
        $command = [string]$args[-1]
        $global:dnsServerTest.Calls.Add($command)
        $global:LASTEXITCODE = 0
        if ($command.Contains('mktemp')) {
            if ($global:dnsServerTest.Fail -eq 'stage') { '/unexpected/path' } else { '/tmp/dns-server.ABC123xyz0' }
        } elseif ($command.Contains("'maintain'") -and $global:dnsServerTest.Fail -eq 'maintain') {
            $global:LASTEXITCODE = 42
        }
    }
    function Invoke-TestScp {
        $source = [string]$args[-2]
        $destination = [string]$args[-1]
        $global:dnsServerTest.Calls.Add("scp $source")
        $global:LASTEXITCODE = 0
        Assert (-not ($source -match '^[A-Za-z]:')) 'SCP source must use a Linux path'
        Assert (-not ($destination -match '^[A-Za-z]:')) 'SCP destination must use a Linux path'
        if (-not $destination.StartsWith('dns-server:')) {
            Assert ($global:dnsServerTest.Paths.ContainsKey($destination)) 'Download destination translated with wslpath'
            $destination = $global:dnsServerTest.Paths[$destination]
        } else {
            foreach ($sourcePath in @($args[-3], $args[-2])) {
                Assert ($global:dnsServerTest.Paths.ContainsKey($sourcePath)) 'Upload source translated with wslpath'
            }
        }
        if ($source.EndsWith('/backup-state')) {
            [IO.File]::WriteAllText($destination, $global:dnsServerTest.State)
        } elseif ($source.EndsWith('/backup.zip')) {
            if ($global:dnsServerTest.Fail -eq 'download') { $global:LASTEXITCODE = 1; return }
            $archive = [IO.Compression.ZipFile]::Open($destination, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $null = $archive.CreateEntry('AdGuardHome/AdGuardHome.yaml')
                if ($global:dnsServerTest.Fail -ne 'invalid-zip') { $null = $archive.CreateEntry('AdGuardHome/AdGuardHome') }
            } finally { $archive.Dispose() }
        }
    }
    function wsl.exe {
        $offset = 0
        if ($global:dnsServerTest.Distribution) {
            Assert ($args[0] -eq '--distribution' -and $args[1] -eq $global:dnsServerTest.Distribution) 'Selected distribution used for every WSL call'
            $offset = 2
        }
        Assert ($args[$offset] -eq '--exec' -and $args[$offset + 1] -eq 'bash' -and $args[$offset + 2] -eq '-lc') 'WSL uses login Bash'
        $shellCommand = [string]$args[$offset + 3]
        # Decode the deliberately restricted shell-literal format produced by Invoke-Wsl.
        $parts = @([regex]::Matches($shellCommand, "'((?:[^']|'\\'')*)'") | ForEach-Object {
            $_.Groups[1].Value.Replace("'\''", "'")
        })
        Assert ((($parts | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' ') -ceq $shellCommand) 'Every WSL argument is shell-quoted'
        $global:LASTEXITCODE = 0
        $linuxArguments = @($parts[1..($parts.Count - 1)])
        switch ($parts[0]) {
            'ssh' { Invoke-TestSsh @linuxArguments }
            'scp' { Invoke-TestScp @linuxArguments }
            'wslpath' {
                if ($global:dnsServerTest.Fail -eq 'wslpath') { $global:LASTEXITCODE = 7; return }
                $windowsPath = $parts[-1]
                $linuxPath = '/mnt/test/' + $windowsPath.Replace('\', '/').Replace(':', '')
                $global:dnsServerTest.Paths[$linuxPath] = $windowsPath
                $linuxPath
            }
            default { throw "Unexpected Linux command: $($parts[0])" }
        }
    }
    $entryPoint = Join-Path $testRoot 'manage.ps1'
    & $entryPoint Maintain
    $calls = $global:dnsServerTest.Calls -join "`n"
    Assert ($calls.IndexOf('/backup.zip') -lt $calls.IndexOf("'maintain'")) 'Backup downloaded before maintenance'
    foreach ($failure in @('download', 'invalid-zip')) {
        $global:dnsServerTest.Calls.Clear()
        $global:dnsServerTest.Fail = $failure
        Assert-Throws { & $entryPoint Maintain } "Abort on $failure"
        Assert (-not (($global:dnsServerTest.Calls -join "`n").Contains("'maintain'"))) 'No update after backup failure'
    }
    $global:dnsServerTest.Fail = 'maintain'
    Assert-Throws { & $entryPoint Maintain } 'Propagate remote failure even after successful cleanup'
    $global:dnsServerTest.Fail = 'stage'
    $global:dnsServerTest.Calls.Clear()
    Assert-Throws { & $entryPoint Status } 'Reject unexpected remote staging path'
    Assert (-not (($global:dnsServerTest.Calls -join "`n").Contains('rm -rf'))) 'Never clean unexpected path'
    $global:dnsServerTest.Fail = ''
    $global:dnsServerTest.State = 'absent'
    & $entryPoint Setup
    $global:dnsServerTest.Calls.Clear()
    & $entryPoint Status
    Assert (-not (($global:dnsServerTest.Calls -join "`n").Contains("'backup'"))) 'Status does not export or update'
    $global:dnsServerTest.Distribution = 'Ubuntu Test'
    & $entryPoint Status -WslDistribution 'Ubuntu Test'
    $global:dnsServerTest.Calls.Clear()
    & $entryPoint Admin -WslDistribution 'Ubuntu Test'
    Assert (-not (($global:dnsServerTest.Calls -join "`n").Contains('mktemp'))) 'Admin only opens a tunnel'
    $global:dnsServerTest.Distribution = ''
    $oddRoot = Join-Path $testRoot 'checkout with spaces '' and dollar$'
    $null = New-Item -ItemType Directory -Path $oddRoot
    foreach ($item in @('manage.ps1', 'scripts', 'config')) {
        Copy-Item -LiteralPath (Join-Path $testRoot $item) -Destination $oddRoot -Recurse
    }
    $global:dnsServerTest.State = 'ready'
    & (Join-Path $oddRoot 'manage.ps1') Maintain
    $global:dnsServerTest.Fail = 'wslpath'
    $global:dnsServerTest.Calls.Clear()
    Assert-Throws { & $entryPoint Setup } 'Abort on path translation failure'
    Assert (-not (($global:dnsServerTest.Calls -join "`n").Contains("'setup'"))) 'No setup after path translation failure'
    Write-Host 'PASS: PowerShell syntax, configuration, WSL-only transport, distro selection, paths, backup ordering and failures.'
} finally {
    Remove-Variable -Name dnsServerTest -Scope Global -ErrorAction SilentlyContinue
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTest) -match '^dns-server-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
