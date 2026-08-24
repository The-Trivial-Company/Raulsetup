<#
Setup-RAUL-Programs-Only.ps1

Purpose:
  Only sets up RAUL 2.0 programs:
    - Downloads RAUL 2.0.zip
    - Extracts RAULDASH and RAULMANUAL
    - Updates settings.xml in both folders
    - Repairs RAULMANUAL Flask template/settings layout when needed
    - Updates RAULMANUAL raul_config.xml tab_name
    - Optionally changes RAULMANUAL port
    - Installs shared RAUL requirements.txt once from RAULDASH
    - Installs Flask for RAULMANUAL
    - Creates startup BAT for both RAUL programs

Run:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-RAUL-Programs-Only.ps1
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===== RAUL DOWNLOAD LINK =====
$RaulZipUrl = "https://drive.google.com/file/d/1VpRz3Wj2xd3TcItPsMvSAF9Kv6BVnPRH/view?usp=sharing"

# ===== PATHS =====
$InstallRoot = Join-Path $env:USERPROFILE "Downloads\RAUL 2.0"
$WorkDir = Join-Path $env:TEMP "RAUL_Setup"
$ZipPath = Join-Path $WorkDir "RAUL 2.0.zip"
$ExtractPath = Join-Path $WorkDir "Extracted"
$StartupBatName = "Start_RAUL_Apps.bat"

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

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

function Get-GoogleDriveFileId {
    param([string]$Url)

    if ($Url -match "/d/([A-Za-z0-9_-]+)") {
        return $Matches[1]
    }

    if ($Url -match "id=([A-Za-z0-9_-]+)") {
        return $Matches[1]
    }

    throw "Could not find Google Drive file ID in URL: $Url"
}

function Test-ZipMagic {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $stream = [IO.File]::Open($Path, "Open", "Read", "Read")
        $reader = New-Object IO.BinaryReader($stream)
        $bytes = $reader.ReadBytes(4)
        $reader.Close()
        $stream.Close()

        return ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
    }
    catch {
        return $false
    }
}

function Download-GoogleDriveFile {
    param(
        [string]$ShareUrl,
        [string]$DestinationPath
    )

    $fileId = Get-GoogleDriveFileId -Url $ShareUrl
    $baseUrl = "https://docs.google.com/uc?export=download&id=$fileId"

    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $headers = @{
        "User-Agent" = "Mozilla/5.0"
        "Accept" = "*/*"
    }

    Write-Info "Downloading RAUL 2.0.zip..."

    $session = $null
    $response = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -Headers $headers -SessionVariable session -TimeoutSec 3600

    $confirmToken = $null

    foreach ($cookie in $session.Cookies.GetCookies([Uri]$baseUrl)) {
        if ($cookie.Name -like "download_warning*") {
            $confirmToken = $cookie.Value
            break
        }
    }

    if (-not $confirmToken) {
        if ($response.Content -match "confirm=([0-9A-Za-z_-]+)") {
            $confirmToken = $Matches[1]
        }
        elseif ($response.Content -match 'name="confirm"\s+value="([0-9A-Za-z_-]+)"') {
            $confirmToken = $Matches[1]
        }
        elseif ($response.Content -match 'href="[^"]*?confirm=([0-9A-Za-z_-]+)[^"]*"') {
            $confirmToken = $Matches[1]
        }
    }

    if ($confirmToken) {
        $downloadUrl = "$baseUrl&confirm=$confirmToken"
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -WebSession $session -Headers $headers -OutFile $DestinationPath -TimeoutSec 3600
    }
    else {
        Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -WebSession $session -Headers $headers -OutFile $DestinationPath -TimeoutSec 3600
    }

    if (-not (Test-ZipMagic -Path $DestinationPath)) {
        throw "Downloaded file is not a valid ZIP. Check Google Drive sharing permissions."
    }

    Write-OK "Downloaded ZIP: $DestinationPath"
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

function Ensure-RaulManualPackageLayout {
    param(
        [string]$ManualFolder,
        [string]$DashFolder
    )

    # Flask render_template() expects templates in a "templates" subfolder.
    $templatesFolder = Join-Path $ManualFolder "templates"
    New-Item -ItemType Directory -Path $templatesFolder -Force | Out-Null

    foreach ($templateName in @("raul_manual.html", "settings.html")) {
        $rootTemplate = Join-Path $ManualFolder $templateName
        $templateTarget = Join-Path $templatesFolder $templateName

        if ((Test-Path $rootTemplate) -and -not (Test-Path $templateTarget)) {
            Copy-Item -Path $rootTemplate -Destination $templateTarget -Force
            Write-OK "Placed $templateName in Flask templates folder."
        }
    }

    # The updated RAUL Manual backend reads ProjectName from settings.xml.
    # If Manual does not contain it, seed it from RAULDASH.
    $manualSettings = Join-Path $ManualFolder "settings.xml"

    if (-not (Test-Path $manualSettings)) {
        $dashSettings = Get-FirstExistingPath @(
            (Join-Path $DashFolder "settings.xml"),
            (Join-Path $DashFolder "settings")
        )

        if (-not $dashSettings) {
            throw "Could not create RAULMANUAL settings.xml because RAULDASH settings.xml/settings was not found."
        }

        Copy-Item -Path $dashSettings -Destination $manualSettings -Force
        Write-OK "Created missing RAULMANUAL settings.xml from RAULDASH settings."
    }
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

    if (-not $xml.raul_config.history.tab_name) {
        throw "Invalid raul_config file. Could not find <history><tab_name>"
    }

    $xml.raul_config.history.tab_name = $TabName

    Save-XmlDocument -Xml $xml -Path $configPath

    Write-OK "Updated $configPath"
}

function Get-RaulManualPort {
    param([string]$ManualFolder)

    $manualPy = Join-Path $ManualFolder "raul_manual.py"

    if (-not (Test-Path $manualPy)) {
        return $null
    }

    $content = [System.IO.File]::ReadAllText($manualPy, [System.Text.Encoding]::UTF8)

    $match = [regex]::Match($content, 'app\.run\((?s).*?port\s*=\s*(\d+).*?\)')

    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }

    return $null
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

    $pattern = 'app\.run\s*\((?<args>(?s:.*?))\)'
    $match = [regex]::Match($content, $pattern)

    if (-not $match.Success) {
        throw "Could not find app.run(...) in raul_manual.py"
    }

    $args = $match.Groups["args"].Value

    if ($args -match '\bport\s*=\s*\d+') {
        $newArgs = [regex]::Replace($args, '\bport\s*=\s*\d+', "port=$Port", 1)
    }
    else {
        if ([string]::IsNullOrWhiteSpace($args)) {
            $newArgs = "port=$Port"
        }
        else {
            $newArgs = "$args, port=$Port"
        }
    }

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

    Write-OK "Updated RAULMANUAL port to $Port"
}

function Test-PythonCommand {
    param([string]$PythonCommand)

    try {
        if ($PythonCommand -eq "py -3") {
            $output = & py -3 --version 2>&1
        }
        else {
            $output = & $PythonCommand --version 2>&1
        }

        if ($LASTEXITCODE -eq 0 -and ($output -join " ") -match "Python\s+3\.") {
            return $true
        }
    }
    catch {}

    return $false
}

function Get-PythonCommand {
    if ((Get-Command py -ErrorAction SilentlyContinue) -and (Test-PythonCommand "py -3")) {
        return "py -3"
    }

    if ((Get-Command python -ErrorAction SilentlyContinue) -and (Test-PythonCommand "python")) {
        return "python"
    }

    return $null
}

function Invoke-Python {
    param(
        [string]$PythonCommand,
        [string[]]$Arguments
    )

    if ($PythonCommand -eq "py -3") {
        & py -3 @Arguments
    }
    else {
        & $PythonCommand @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $PythonCommand $($Arguments -join ' ')"
    }
}

function Install-PythonRequirements {
    param(
        [string]$PythonCommand,
        [string]$DashFolder
    )

    $requirements = Join-Path $DashFolder "requirements.txt"

    Write-Info "Upgrading pip..."
    Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "pip", "install", "--upgrade", "pip")

    if (Test-Path $requirements) {
        Write-Info "Installing requirements.txt from RAULDASH..."
        Push-Location $DashFolder

        try {
            Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "pip", "install", "-r", "requirements.txt")
        }
        finally {
            Pop-Location
        }

        Write-OK "Installed RAULDASH requirements.txt"
    }
    else {
        Write-Warn "requirements.txt not found in $DashFolder"
    }

    Write-Info "Installing Flask..."
    Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "pip", "install", "flask")
    Write-OK "Installed Flask"
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
            -ErrorAction SilentlyContinue | Out-Null

        Write-OK "Created firewall rule for port $Port"
    }
    else {
        Write-OK "Firewall rule already exists for port $Port"
    }
}

function Create-StartupBat {
    param(
        [string]$PythonCommand,
        [string]$DashFolder,
        [string]$ManualFolder,
        [int]$Port
    )

    $startupFolder = [Environment]::GetFolderPath("Startup")
    $batPath = Join-Path $startupFolder $StartupBatName
    $manualUrl = "http://127.0.0.1:$Port"

    $bat = @"
@echo off

REM Start RAUL Dash
start "RAUL Dash" cmd /k "title RAUL Dash && cd /d ""$DashFolder"" && $PythonCommand raultodash.py"

REM Wait for RAULDASH menu to load
timeout /t 3 /nobreak >nul

REM Select option 5 in RAUL Dash
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName Microsoft.VisualBasic; Add-Type -AssemblyName System.Windows.Forms; [Microsoft.VisualBasic.Interaction]::AppActivate('RAUL Dash'); Start-Sleep -Milliseconds 500; [System.Windows.Forms.SendKeys]::SendWait('5{ENTER}')"

REM Start RAUL Manual server
start "RAUL Manual" cmd /k "title RAUL Manual && cd /d ""$ManualFolder"" && $PythonCommand raul_manual.py"

REM Wait for manual server to start
timeout /t 5 /nobreak >nul

REM Open RAUL Manual locally
start "" "$manualUrl"
"@

    $bat | Out-File -FilePath $batPath -Encoding ASCII -Force

    Write-OK "Created startup file: $batPath"
}

# ================= MAIN =================

Write-Host ""
Write-Host "RAUL PROGRAMS ONLY SETUP" -ForegroundColor Cyan
Write-Host ""

$tabName = Read-Host "Enter LocationLog tab name"
$projectName = Read-Host "Enter ProjectName / Job name"
$portInput = Read-Host "Enter RAULMANUAL port, or press ENTER to leave default/current port"

$tabName = $tabName.Trim()
$projectName = $projectName.Trim()

if ([string]::IsNullOrWhiteSpace($tabName)) {
    throw "LocationLog tab name cannot be blank."
}

if ([string]::IsNullOrWhiteSpace($projectName)) {
    throw "ProjectName / Job name cannot be blank."
}

$changePort = $false
$selectedPort = $null

if (-not [string]::IsNullOrWhiteSpace($portInput)) {
    $parsedPort = 0

    if (-not [int]::TryParse($portInput.Trim(), [ref]$parsedPort)) {
        throw "RAULMANUAL port must be a number between 1 and 65535."
    }

    if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "Invalid port number: $parsedPort"
    }

    $selectedPort = $parsedPort
    $changePort = $true
}

$pythonCommand = Get-PythonCommand

if (-not $pythonCommand) {
    throw "Python was not found. Install Python first and make sure it is available from PATH."
}

Write-OK "Python found: $pythonCommand"

Download-GoogleDriveFile -ShareUrl $RaulZipUrl -DestinationPath $ZipPath

if (Test-Path $ExtractPath) {
    Remove-Item $ExtractPath -Recurse -Force
}

New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null

Write-Info "Extracting RAUL 2.0.zip..."
Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

$dashSource = Get-ChildItem -Path $ExtractPath -Directory -Recurse | Where-Object { $_.Name -ieq "RAULDASH" } | Select-Object -First 1
$manualSource = Get-ChildItem -Path $ExtractPath -Directory -Recurse | Where-Object { $_.Name -ieq "RAULMANUAL" } | Select-Object -First 1

if (-not $dashSource) {
    throw "RAULDASH folder was not found inside the ZIP."
}

if (-not $manualSource) {
    throw "RAULMANUAL folder was not found inside the ZIP."
}

if (Test-Path $InstallRoot) {
    $backup = "$InstallRoot.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -Path $InstallRoot -Destination $backup
    Write-Warn "Existing RAUL install was backed up to:"
    Write-Warn $backup
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

Copy-Item -Path $dashSource.FullName -Destination $InstallRoot -Recurse -Force
Copy-Item -Path $manualSource.FullName -Destination $InstallRoot -Recurse -Force

$DashFolder = Join-Path $InstallRoot "RAULDASH"
$ManualFolder = Join-Path $InstallRoot "RAULMANUAL"

# Install shared Python requirements first so a configuration/layout issue cannot
# leave RAULMANUAL without its dependencies.
Install-PythonRequirements -PythonCommand $pythonCommand -DashFolder $DashFolder

# Configure RAULDASH first, then repair/seed the current RAULMANUAL package layout.
Update-SettingsXml -Folder $DashFolder -TabName $tabName -ProjectName $projectName
Ensure-RaulManualPackageLayout -ManualFolder $ManualFolder -DashFolder $DashFolder
Update-SettingsXml -Folder $ManualFolder -TabName $tabName -ProjectName $projectName
Update-RaulConfig -ManualFolder $ManualFolder -TabName $tabName

if ($changePort) {
    Update-RaulManualPort -ManualFolder $ManualFolder -Port $selectedPort
    $finalPort = $selectedPort
}
else {
    $detectedPort = Get-RaulManualPort -ManualFolder $ManualFolder

    if ($detectedPort) {
        $finalPort = $detectedPort
        Write-Info "Port left unchanged. Detected current port: $finalPort"
    }
    else {
        $finalPort = 5000
        Write-Warn "Could not detect packaged RAULMANUAL port. Using default port 5000."
    }
}

Update-FirewallForPort -Port $finalPort
Create-StartupBat -PythonCommand $pythonCommand -DashFolder $DashFolder -ManualFolder $ManualFolder -Port $finalPort

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "RAUL PROGRAM SETUP COMPLETE" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Install folder: $InstallRoot"
Write-Host "LocationLog: $tabName!A:D"
Write-Host "ProjectName / Job name: $projectName"
Write-Host "RAULMANUAL local URL: http://127.0.0.1:$finalPort"
Write-Host ""
Write-Host "For network access, use:"
Write-Host "http://THIS-COMPUTER-IP:$finalPort"
Write-Host ""
Read-Host "Press ENTER to close"
