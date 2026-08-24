
<#
Update-RAUL-Settings.ps1

Purpose:
  Change RAUL tab name, project/job name, computer name, and RAULMANUAL port.

Run as Administrator:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-RAUL-Settings.ps1
#>

$ErrorActionPreference = "Stop"

# Default RAUL install path
$RaulRoot = Join-Path $env:USERPROFILE "Downloads\RAUL 2.0"
$DashFolder = Join-Path $RaulRoot "RAULDASH"
$ManualFolder = Join-Path $RaulRoot "RAULMANUAL"
$StartupBatName = "Start_RAUL_Apps.bat"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator, then run this script again."
    }
}

function Get-FirstExistingPath {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Save-XmlDocument {
    param(
        [xml]$Xml,
        [string]$Path
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = $utf8NoBom

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Xml.Save($writer)
    }
    finally {
        $writer.Close()
    }
}

function Get-CurrentSettings {
    param(
        [string]$DashFolder,
        [string]$ManualFolder
    )

    $result = @{
        TabName = ""
        ProjectName = ""
    }

    $dashSettingsPath = Get-FirstExistingPath @(
        (Join-Path $DashFolder "settings.xml"),
        (Join-Path $DashFolder "settings")
    )

    if ($dashSettingsPath) {
        try {
            [xml]$xml = Get-Content $dashSettingsPath -Raw -Encoding UTF8

            if ($xml.Settings.LocationLog) {
                $locationLog = [string]$xml.Settings.LocationLog
                if ($locationLog -match '^(.*?)!A:D$') {
                    $result.TabName = $Matches[1]
                }
            }

            if ($xml.Settings.ProjectName) {
                $result.ProjectName = [string]$xml.Settings.ProjectName
            }
        }
        catch {
            Write-Warn "Could not read current settings from $dashSettingsPath"
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.TabName)) {
        $configPath = Get-FirstExistingPath @(
            (Join-Path $ManualFolder "raul_config.xml"),
            (Join-Path $ManualFolder "raul_config")
        )

        if ($configPath) {
            try {
                [xml]$xml = Get-Content $configPath -Raw -Encoding UTF8
                if ($xml.raul_config.history.tab_name) {
                    $result.TabName = [string]$xml.raul_config.history.tab_name
                }
            }
            catch {}
        }
    }

    return $result
}

function Update-SettingsXml {
    param(
        [string]$Folder,
        [string]$TabName,
        [string]$ProjectName
    )

    $settingsPath = Get-FirstExistingPath @(
        (Join-Path $Folder "settings.xml"),
        (Join-Path $Folder "settings")
    )

    if (-not $settingsPath) {
        throw "Could not find settings.xml or settings in $Folder"
    }

    [xml]$xml = Get-Content $settingsPath -Raw -Encoding UTF8

    if (-not $xml.Settings) {
        throw "Invalid settings file. Missing <Settings> root in $settingsPath"
    }

    $xml.Settings.LocationLog = "$TabName!A:D"
    $xml.Settings.ProjectName = $ProjectName

    Save-XmlDocument -Xml $xml -Path $settingsPath

    Write-OK "Updated $settingsPath"
}

function Update-RaulConfig {
    param(
        [string]$ManualFolder,
        [string]$TabName
    )

    $configPath = Get-FirstExistingPath @(
        (Join-Path $ManualFolder "raul_config.xml"),
        (Join-Path $ManualFolder "raul_config")
    )

    if (-not $configPath) {
        throw "Could not find raul_config.xml or raul_config in $ManualFolder"
    }

    [xml]$xml = Get-Content $configPath -Raw -Encoding UTF8

    if (-not $xml.raul_config.history) {
        throw "Invalid raul_config file. Could not find <history>"
    }

    if (-not $xml.raul_config.history.tab_name) {
        throw "Invalid raul_config file. Could not find <history><tab_name>"
    }

    $xml.raul_config.history.tab_name = $TabName

    Save-XmlDocument -Xml $xml -Path $configPath

    Write-OK "Updated $configPath"
}

function Get-CurrentRaulManualPort {
    param([string]$ManualFolder)

    $manualPy = Join-Path $ManualFolder "raul_manual.py"

    if (Test-Path $manualPy) {
        try {
            $content = [System.IO.File]::ReadAllText($manualPy, [System.Text.Encoding]::UTF8)

            # Handles app.run(... port=5000 ...), regardless of argument order/spacing.
            $match = [regex]::Match(
                $content,
                'app\.run\s*\((?s:.*?)\bport\s*=\s*(\d+)(?s:.*?)\)'
            )

            if ($match.Success) {
                $detectedPort = [int]$match.Groups[1].Value
                if ($detectedPort -ge 1 -and $detectedPort -le 65535) {
                    return $detectedPort
                }
            }
        }
        catch {
            Write-Warn "Could not detect current port from raul_manual.py"
        }
    }

    # Fallback to the startup BAT if the Python file does not expose the port.
    $startupFolder = [Environment]::GetFolderPath("Startup")
    $batPath = Join-Path $startupFolder $StartupBatName

    if (Test-Path $batPath) {
        try {
            $batContent = Get-Content $batPath -Raw
            $match = [regex]::Match($batContent, 'http://127\.0\.0\.1:(\d+)')

            if ($match.Success) {
                $detectedPort = [int]$match.Groups[1].Value
                if ($detectedPort -ge 1 -and $detectedPort -le 65535) {
                    return $detectedPort
                }
            }
        }
        catch {}
    }

    return 5000
}

function Update-RaulManualPort {
    param(
        [string]$ManualFolder,
        [int]$Port
    )

    $manualPy = Join-Path $ManualFolder "raul_manual.py"

    if (-not (Test-Path $manualPy)) {
        throw "Could not find raul_manual.py at $manualPy"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $content = [System.IO.File]::ReadAllText($manualPy, [System.Text.Encoding]::UTF8)

    # Find the complete app.run(...) call.
    $pattern = 'app\.run\s*\((?<args>(?s:.*?))\)'
    $match = [regex]::Match($content, $pattern)

    if (-not $match.Success) {
        throw "Could not find app.run(...) in raul_manual.py"
    }

    $oldCall = $match.Value
    $args = $match.Groups["args"].Value

    if ($args -match '\bport\s*=\s*\d+') {
        $newArgs = [regex]::Replace(
            $args,
            '\bport\s*=\s*\d+',
            "port=$Port",
            1
        )
    }
    else {
        if ([string]::IsNullOrWhiteSpace($args)) {
            $newArgs = "host=`"0.0.0.0`", port=$Port"
        }
        else {
            $newArgs = "$args, port=$Port"
        }
    }

    # Make sure the Flask server remains reachable from the network.
    if ($newArgs -match '\bhost\s*=\s*["''][^"'']*["'']') {
        $newArgs = [regex]::Replace(
            $newArgs,
            '\bhost\s*=\s*["''][^"'']*["'']',
            'host="0.0.0.0"',
            1
        )
    }
    else {
        $newArgs = "host=`"0.0.0.0`", $newArgs"
    }

    $newCall = "app.run($newArgs)"
    $newContent = $content.Remove($match.Index, $match.Length).Insert($match.Index, $newCall)

    [System.IO.File]::WriteAllText($manualPy, $newContent, $utf8NoBom)

    Write-OK "Updated RAULMANUAL port to $Port in raul_manual.py"
    Write-Info "Old app.run call: $oldCall"
    Write-Info "New app.run call: $newCall"
}

function Update-FirewallForPort {
    param([int]$Port)

    $ruleName = "RAUL Manual Flask Port $Port"

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if (-not $existing) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -Profile Any `
            -ErrorAction Stop | Out-Null

        Write-OK "Created firewall rule for port $Port"
    }
    else {
        Write-OK "Firewall rule already exists for port $Port"
    }
}

function Get-PythonCommandForStartup {
    $startupFolder = [Environment]::GetFolderPath("Startup")
    $batPath = Join-Path $startupFolder $StartupBatName

    # Preserve whichever Python command the installer already placed in the BAT.
    if (Test-Path $batPath) {
        try {
            $content = Get-Content $batPath -Raw

            if ($content -match '&&\s*(py\s+-3)\s+raultodash\.py') {
                return "py -3"
            }

            if ($content -match '&&\s*(python(?:\.exe)?)\s+raultodash\.py') {
                return $Matches[1]
            }
        }
        catch {}
    }

    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            & py -3 --version *> $null
            if ($LASTEXITCODE -eq 0) {
                return "py -3"
            }
        }
        catch {}
    }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        return "python"
    }

    throw "Could not locate Python for the RAUL startup BAT."
}

function Update-StartupBat {
    param(
        [string]$DashFolder,
        [string]$ManualFolder,
        [int]$Port
    )

    $startupFolder = [Environment]::GetFolderPath("Startup")
    $batPath = Join-Path $startupFolder $StartupBatName
    $manualUrl = "http://127.0.0.1:$Port"
    $pythonCommand = Get-PythonCommandForStartup

    $bat = @"
@echo off

REM Start RAUL Dash
start "RAUL Dash" cmd /k "title RAUL Dash && cd /d ""$DashFolder"" && $pythonCommand raultodash.py"

REM Wait for RAULDASH menu to load
timeout /t 3 /nobreak >nul

REM Select option 5 in RAUL Dash
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName Microsoft.VisualBasic; Add-Type -AssemblyName System.Windows.Forms; [Microsoft.VisualBasic.Interaction]::AppActivate('RAUL Dash'); Start-Sleep -Milliseconds 500; [System.Windows.Forms.SendKeys]::SendWait('5{ENTER}')"

REM Start RAUL Manual server
start "RAUL Manual" cmd /k "title RAUL Manual && cd /d ""$ManualFolder"" && $pythonCommand raul_manual.py"

REM Wait for manual server to start
timeout /t 5 /nobreak >nul

REM Open RAUL Manual locally
start "" "$manualUrl"
"@

    $bat | Out-File -FilePath $batPath -Encoding ASCII -Force

    Write-OK "Updated startup file: $batPath"
    Write-Info "Startup Python command: $pythonCommand"
}

function Rename-ThisComputer {
    param([string]$NewComputerName)

    if ([string]::IsNullOrWhiteSpace($NewComputerName)) {
        Write-Info "Computer name left unchanged."
        return $false
    }

    $NewComputerName = $NewComputerName.Trim()

    if ($NewComputerName -eq $env:COMPUTERNAME) {
        Write-Info "Computer name is already $NewComputerName"
        return $false
    }

    Rename-Computer -NewName $NewComputerName -Force
    Write-OK "Computer rename scheduled: $env:COMPUTERNAME -> $NewComputerName"
    return $true
}

# ---------------- MAIN ----------------

Assert-Admin

Write-Host ""
Write-Host "RAUL SETTINGS UPDATE" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $RaulRoot)) {
    Write-Warn "Default RAUL folder not found:"
    Write-Warn $RaulRoot
    $customRoot = Read-Host "Enter RAUL 2.0 folder path manually"

    if ([string]::IsNullOrWhiteSpace($customRoot) -or -not (Test-Path $customRoot)) {
        throw "Valid RAUL folder path was not provided."
    }

    $RaulRoot = $customRoot.Trim()
    $DashFolder = Join-Path $RaulRoot "RAULDASH"
    $ManualFolder = Join-Path $RaulRoot "RAULMANUAL"
}

if (-not (Test-Path $DashFolder)) {
    throw "RAULDASH folder not found: $DashFolder"
}

if (-not (Test-Path $ManualFolder)) {
    throw "RAULMANUAL folder not found: $ManualFolder"
}

Write-Info "RAUL folder: $RaulRoot"

$currentSettings = Get-CurrentSettings -DashFolder $DashFolder -ManualFolder $ManualFolder
$currentPort = Get-CurrentRaulManualPort -ManualFolder $ManualFolder

Write-Info "Current LocationLog tab: $($currentSettings.TabName)"
Write-Info "Current ProjectName: $($currentSettings.ProjectName)"
Write-Info "Current RAULMANUAL port: $currentPort"
Write-Host ""

$newComputerName = Read-Host "Enter new computer name, or press ENTER to keep $env:COMPUTERNAME"

$tabPrompt = if ($currentSettings.TabName) {
    "Enter LocationLog tab name, or press ENTER to keep '$($currentSettings.TabName)'"
}
else {
    "Enter LocationLog tab name"
}
$tabInput = Read-Host $tabPrompt

$projectPrompt = if ($currentSettings.ProjectName) {
    "Enter ProjectName / Job name, or press ENTER to keep '$($currentSettings.ProjectName)'"
}
else {
    "Enter ProjectName / Job name"
}
$projectInput = Read-Host $projectPrompt

$portInput = Read-Host "Enter RAULMANUAL port, or press ENTER to keep $currentPort"

$tabName = if ([string]::IsNullOrWhiteSpace($tabInput)) {
    $currentSettings.TabName
}
else {
    $tabInput.Trim()
}

$projectName = if ([string]::IsNullOrWhiteSpace($projectInput)) {
    $currentSettings.ProjectName
}
else {
    $projectInput.Trim()
}

if ([string]::IsNullOrWhiteSpace($portInput)) {
    $port = $currentPort
    $changePort = $false
}
else {
    $parsedPort = 0

    if (-not [int]::TryParse($portInput.Trim(), [ref]$parsedPort)) {
        throw "RAULMANUAL port must be a number between 1 and 65535."
    }

    if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "Invalid port number: $parsedPort"
    }

    $port = $parsedPort
    $changePort = ($port -ne $currentPort)
}

if ([string]::IsNullOrWhiteSpace($tabName)) {
    throw "LocationLog tab name cannot be blank."
}

if ([string]::IsNullOrWhiteSpace($projectName)) {
    throw "ProjectName / Job name cannot be blank."
}

Write-Host ""
Write-Info "Applying changes..."

$needsReboot = Rename-ThisComputer -NewComputerName $newComputerName

Update-SettingsXml -Folder $DashFolder -TabName $tabName -ProjectName $projectName
Update-SettingsXml -Folder $ManualFolder -TabName $tabName -ProjectName $projectName
Update-RaulConfig -ManualFolder $ManualFolder -TabName $tabName

if ($changePort) {
    Update-RaulManualPort -ManualFolder $ManualFolder -Port $port
    Update-FirewallForPort -Port $port
    Update-StartupBat -DashFolder $DashFolder -ManualFolder $ManualFolder -Port $port
}
else {
    Write-Info "RAULMANUAL port left unchanged at $port."

    # Make sure the firewall rule exists even when the port is unchanged.
    Update-FirewallForPort -Port $port
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "RAUL SETTINGS UPDATED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Computer name: $env:COMPUTERNAME"
if ($newComputerName -and $newComputerName.Trim() -ne $env:COMPUTERNAME) {
    Write-Host "New computer name after reboot: $($newComputerName.Trim())"
}
Write-Host "LocationLog: $tabName!A:D"
Write-Host "ProjectName / Job name: $projectName"
Write-Host "RAULMANUAL local URL: http://127.0.0.1:$port"
Write-Host ""
Write-Host "For network access, use:"
Write-Host "http://THIS-COMPUTER-IP:$port"
Write-Host ""

if ($needsReboot) {
    Write-Warn "A reboot is required for the computer name change."
    $restart = Read-Host "Restart now? Y/N"

    if ($restart -match "^[Yy]") {
        Restart-Computer -Force
    }
}

Read-Host "Press ENTER to close"
