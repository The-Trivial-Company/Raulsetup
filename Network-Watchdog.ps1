# Trivial LLC - Network Recovery Watchdog (Windows 10/11, Windows PowerShell 5.1)
# Runs as SYSTEM every 2 minutes. Does not use Tailscale.
# Reconnects to existing ALL-USER saved Wi-Fi profiles when Wi-Fi is disconnected.
# Only reboots after 15 minutes without Wi-Fi AND without usable routed Ethernet.
$ErrorActionPreference = 'Stop'
$Root = 'C:\ProgramData\Trivial\NetworkRecovery'
$StateFile = Join-Path $Root 'state.json'
$LogFile = Join-Path $Root 'network-recovery.log'
$FailureMinutes = 15
$MinMinutesAfterBoot = 15
$MaxRebootsPer24Hours = 2
$MinimumRebootSpacingMinutes = 45
$WifiTrySeconds = 8
New-Item -ItemType Directory -Path $Root -Force | Out-Null

$mutex = New-Object System.Threading.Mutex($false, 'Global\TrivialNetworkRecoveryWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    function Log([string]$message) {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    function Load-State {
        if (Test-Path -LiteralPath $StateFile) {
            try { return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) } catch { Log "State reset: $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ OfflineSince = $null; RebootTimes = @() }
    }
    function Save-State($state) {
        $tmp = "$StateFile.tmp"
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $StateFile -Force
    }
    function Get-WifiAdapter {
        @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11|WLAN' -or
            $_.Name -match 'Wi-?Fi|WLAN|Wireless' -or
            [string]$_.NdisPhysicalMedium -eq 'Native802_11'
        } | Select-Object -First 1)[0]
    }
    function Get-RoutedEthernet {
        # An Ethernet link to a PLC with no default gateway is NOT a routed Ethernet connection.
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch 'PLC|Wi-?Fi|WLAN|Wireless|Bluetooth' -and
            $_.InterfaceDescription -notmatch 'Wireless|Wi-?Fi|802\.11|WLAN|Bluetooth' -and
            ($_.NdisPhysicalMedium -eq '802.3' -or $_.InterfaceDescription -match 'Ethernet|Realtek|Intel|USB.*LAN')
        })
        foreach ($a in $adapters) {
            $routes = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object {
                $_.NextHop -and $_.NextHop -ne '0.0.0.0'
            })
            $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'
            })
            if ($routes.Count -gt 0 -and $ips.Count -gt 0) { return $a }
        }
        return $null
    }
    function Test-WifiAssociated($adapter) {
        if (-not $adapter) { return $false }
        $profiles = @(Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -and $_.Name -ne 'Unidentified network' -and $_.IPv4Connectivity -ne 'Disconnected'
        })
        if ($profiles.Count -gt 0) { return $true }
        # Extra check for networks that Windows NLA has not identified yet.
        $output = (& netsh.exe wlan show interfaces 2>&1) -join "`n"
        return ($output -match '(?im)^\s*State\s*:\s*connected\s*$')
    }
    function Get-SavedWifiProfiles {
        $output = (& netsh.exe wlan show profiles 2>&1) -join "`n"
        $names = @()
        foreach ($line in ($output -split "`r?`n")) {
            if ($line -match '^\s*All User Profile\s*:\s*(.+?)\s*$') {
                $name = $Matches[1].Trim()
                if ($name -and $name -notin $names) { $names += $name }
            }
        }
        return $names
    }

    $now = Get-Date
    $state = Load-State
    $recent = @($state.RebootTimes | Where-Object {
        try { ([datetime]$_) -gt $now.AddHours(-24) } catch { $false }
    })
    $state.RebootTimes = $recent

    $ethernet = Get-RoutedEthernet
    if ($ethernet) {
        if ($state.OfflineSince) { Log "Recovery: routed Ethernet available ($($ethernet.Name)); cleared outage." }
        $state.OfflineSince = $null
        Save-State $state
        exit 0
    }

    $wifi = Get-WifiAdapter
    if (-not $wifi) {
        Log 'No physical Wi-Fi adapter found; skipping recovery and reboot.'
        $state.OfflineSince = $null
        Save-State $state
        exit 0
    }
    if ($wifi.Status -eq 'Disabled') {
        try { Enable-NetAdapter -Name $wifi.Name -Confirm:$false -ErrorAction Stop; Log "Enabled Wi-Fi adapter: $($wifi.Name)"; Start-Sleep -Seconds 3 } catch { Log "Cannot enable Wi-Fi adapter: $($_.Exception.Message)" }
    }
    if (Test-WifiAssociated $wifi) {
        if ($state.OfflineSince) { Log 'Recovery: Wi-Fi associated; cleared outage.' }
        $state.OfflineSince = $null
        Save-State $state
        exit 0
    }

    if (-not $state.OfflineSince) {
        $state.OfflineSince = $now.ToString('o')
        Log 'Wi-Fi disconnected and no routed Ethernet; starting outage timer.'
    }
    $profiles = @(Get-SavedWifiProfiles)
    if ($profiles.Count -eq 0) {
        Log 'No ALL-USER saved Wi-Fi profiles found; will NOT reboot (cannot reconnect automatically).'
        $state.OfflineSince = $null
        Save-State $state
        exit 0
    }
    try { Start-Service -Name WlanSvc -ErrorAction SilentlyContinue } catch {}
    foreach ($profile in $profiles) {
        if (Get-RoutedEthernet) { Log 'Ethernet connected during Wi-Fi recovery; stopping.'; $state.OfflineSince = $null; Save-State $state; exit 0 }
        if (Test-WifiAssociated $wifi) { break }
        Log "Trying saved Wi-Fi profile: $profile"
        # Avoid passing credentials or secrets. Uses Windows saved network profile only.
        $result = (& netsh.exe wlan connect name="$profile" interface="$($wifi.Name)" 2>&1) -join ' '
        Log "netsh: $result"
        for ($i = 0; $i -lt $WifiTrySeconds; $i += 2) {
            Start-Sleep -Seconds 2
            if (Test-WifiAssociated $wifi) { break }
        }
        if (Test-WifiAssociated $wifi) { Log "Connected to Wi-Fi with profile: $profile"; break }
    }
    if ((Get-RoutedEthernet) -or (Test-WifiAssociated $wifi)) {
        $state.OfflineSince = $null
        Save-State $state
        exit 0
    }

    $offlineFor = ($now - [datetime]$state.OfflineSince).TotalMinutes
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $minutesSinceBoot = ($now - $bootTime).TotalMinutes
    Log ('Still disconnected. Outage {0:N1} min; uptime {1:N1} min; restarts in 24h: {2}.' -f $offlineFor, $minutesSinceBoot, $recent.Count)
    Save-State $state
    if ($offlineFor -lt $FailureMinutes -or $minutesSinceBoot -lt $MinMinutesAfterBoot) { exit 0 }
    if ($recent.Count -ge $MaxRebootsPer24Hours) { Log 'Restart limit reached; refusing reboot.'; exit 0 }
    if ($recent.Count -gt 0 -and ([datetime]$recent[-1]) -gt $now.AddMinutes(-$MinimumRebootSpacingMinutes)) {
        Log 'Restart cooldown active; refusing reboot.'; exit 0
    }
    # Final immediate check prevents rebooting just as Ethernet or Wi-Fi reconnects.
    if ((Get-RoutedEthernet) -or (Test-WifiAssociated $wifi)) { $state.OfflineSince = $null; Save-State $state; exit 0 }
    $state.RebootTimes = @($recent) + @($now.ToString('o'))
    Save-State $state
    Log '15-minute network outage threshold met; restarting Windows.'
    & shutdown.exe /r /t 30 /c 'Trivial network watchdog: network recovery restart' /f
}
catch {
    try { Add-Content -LiteralPath $LogFile -Value "[$(Get-Date)] ERROR: $($_.Exception.Message)" -Encoding UTF8 } catch {}
    exit 1
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
