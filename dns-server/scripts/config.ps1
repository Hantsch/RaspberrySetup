Set-StrictMode -Version Latest

function ConvertTo-ShellLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-IPv4Number([string] $Value) {
    if ($Value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid IPv4 address: $Value" }
    $address = [System.Net.IPAddress]::Parse($Value)
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -ne $Value) {
        throw "Expected canonical dotted IPv4: $Value"
    }
    $bytes = $address.GetAddressBytes()
    return [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + $bytes[3]
}

function Read-PiConfiguration([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Create config/local.json from config/example.json and edit it first. Missing: $Path"
    }
    $config = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $keys = @('hostname', 'ipv4', 'interface', 'timezone', 'lan_subnet', 'upstream_dns', 'bootstrap_dns', 'dns_test_name')
    $actualKeys = @($config.PSObject.Properties.Name)
    foreach ($key in $keys) {
        if ($key -notin $actualKeys) { throw "Missing configuration key: $key" }
    }
    foreach ($key in $actualKeys) {
        if ($key -notin $keys) { throw "Unknown configuration key: $key" }
        if ($key -notin @('upstream_dns', 'bootstrap_dns') -and $config.$key -isnot [string]) { throw "$key must be a string." }
    }
    if ($config.hostname -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') { throw 'Invalid hostname.' }
    if ($config.interface -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$') { throw 'Invalid interface.' }
    if ($config.timezone -notmatch '^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$') { throw 'Invalid timezone.' }
    if ($config.dns_test_name.Length -gt 253 -or
        $config.dns_test_name -notmatch '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') {
        throw 'dns_test_name must be a fully qualified public DNS name.'
    }
    if ($config.lan_subnet -notmatch '^([^/]+)/([0-9]|[12][0-9]|30)$') { throw 'Use an IPv4 LAN CIDR with prefix 0..30.' }
    $network = Get-IPv4Number $Matches[1]
    $prefix = [int]$Matches[2]
    $size = [uint64][math]::Pow(2, 32 - $prefix)
    $ip = Get-IPv4Number $config.ipv4
    if ($network % $size -ne 0 -or $ip -le $network -or $ip -ge ($network + $size - 1)) {
        throw 'ipv4 must be a usable host inside lan_subnet; specify the canonical network CIDR.'
    }
    $private = ($ip -ge 167772160 -and $ip -le 184549375) -or
               ($ip -ge 2886729728 -and $ip -le 2887778303) -or
               ($ip -ge 3232235520 -and $ip -le 3232301055)
    if (-not $private) { throw 'Use an RFC1918 private IPv4 address for this home LAN setup.' }
    foreach ($key in @('upstream_dns', 'bootstrap_dns')) {
      if ($config.$key -isnot [array] -or $config.$key.Count -eq 0) {
          throw "$key must be a nonempty JSON array."
      }
      foreach ($upstream in $config.$key) {
        if ($upstream -isnot [string]) { throw 'Each resolver must be a string.' }
        $hostValue = $upstream
        if ($key -eq 'upstream_dns' -and $upstream -match '^(https|tls)://') {
            $uri = [uri]$upstream
            if (-not $uri.IsAbsoluteUri -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment -or
                $upstream -match '\s' -or ($uri.Scheme -eq 'tls' -and $uri.AbsolutePath -notin @('', '/'))) {
                throw 'Use an HTTPS or TLS resolver URL without credentials, fragments or whitespace.'
            }
            $hostValue = $uri.DnsSafeHost.Trim('[', ']')
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($hostValue, [ref]$parsed)) {
                if ($hostValue -notmatch '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') {
                    throw 'Resolver URL must contain a fully qualified hostname or IP address.'
                }
                continue
            }
        }
        $address = [System.Net.IPAddress]::Parse($hostValue)
        if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $null = Get-IPv4Number $hostValue
        }
        if ([System.Net.IPAddress]::IsLoopback($address) -or
            $address.Equals([System.Net.IPAddress]::Parse($config.ipv4)) -or
            $address.Equals([System.Net.IPAddress]::Any) -or $address.Equals([System.Net.IPAddress]::IPv6Any)) {
            throw 'Resolvers must not point to this Pi, loopback, or an unspecified address.'
        }
      }
    }
    $values = [ordered]@{
        PI_HOSTNAME = $config.hostname
        PI_IPV4 = $config.ipv4
        PI_INTERFACE = $config.interface
        PI_TIMEZONE = $config.timezone
        PI_CIDR = "$($config.ipv4)/$prefix"
        UPSTREAMS = ConvertTo-Json -InputObject @($config.upstream_dns) -Compress
        BOOTSTRAP_DNS = ConvertTo-Json -InputObject @($config.bootstrap_dns) -Compress
        LAN_SUBNET = $config.lan_subnet
        DNS_TEST_NAME = $config.dns_test_name
    }
    return (($values.GetEnumerator() | ForEach-Object {
        $_.Key + '=' + (ConvertTo-ShellLiteral ([string]$_.Value))
    }) -join "`n") + "`n"
}
