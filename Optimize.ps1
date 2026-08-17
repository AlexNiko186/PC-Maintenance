# =========================================================================
# Optimize-ClinicPC.ps1
# Automated Deployment Script (Uses local C:\ITDepartment tools)
# =========================================================================

# --- Pre-flight Check: Ensure Admin Rights ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[-] This script requires Administrator privileges. Please run PowerShell as Admin." -ForegroundColor Red
    exit
}

# --- Helper Functions ---
function Write-Step ([string]$Message) { Write-Host "`n[*] $Message..." -ForegroundColor Cyan }
function Write-Success ([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-ErrorMsg ([string]$Message) { Write-Host "[-] $Message" -ForegroundColor Red }
function Write-WarningMsg ([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }

function Set-RegKey {
    param ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
}

# ==========================================
# STEP 1: Windows Settings & Updates
# ==========================================
Write-Step "Applying Windows Settings and Privacy Tweaks"
try {
    # 1. Turn off notifications
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0
    Set-RegKey "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1

    # 2. Storage Sense (Recycle Bin = 1 day, Downloads = 14 days)
    $storagePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
    Set-RegKey $storagePath "01" 1    
    Set-RegKey $storagePath "08" 1    
    Set-RegKey $storagePath "256" 1   
    Set-RegKey $storagePath "32" 1    
    Set-RegKey $storagePath "512" 14  

    # 3. Remote Desktop
    Set-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null

    # 4. Theme & Wallpaper
    $themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    Set-RegKey $themePath "AppsUseLightTheme" 1
    Set-RegKey $themePath "SystemUsesLightTheme" 1
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" "BackgroundType" 0

    # 5. Lockscreen
    $lockPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    Set-RegKey $lockPath "RotatingLockScreenEnabled" 0
    Set-RegKey $lockPath "RotatingLockScreenOverlayEnabled" 0

    # 6. Start Menu Recommendations
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackDocs" 0
    Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1

    # 7. Task View & Resume
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" 0
    Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
    Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0

    # 8. Taskbar Behavior
    $taskbarPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegKey $taskbarPath "TaskbarAl" 0           
    Set-RegKey $taskbarPath "TaskbarSd" 1           
    Set-RegKey $taskbarPath "TaskbarDa" 0           
    Set-RegKey $taskbarPath "TaskbarMn" 0           
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0 

    # 9. Gaming Features
    Set-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
    Set-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
    Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0

    # 10. Privacy Permissions
    Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0 
    Set-RegKey "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" 0 
    Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" 0 
    Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1 
    Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1 

    Write-Success "Settings and Registry modifications applied."
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    Write-Step "Checking for and installing Windows Updates natively"
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    Write-Host "   -> Scanning for updates..." -ForegroundColor DarkGray
    $SearchResult = $UpdateSearcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    
    if ($SearchResult.Updates.Count -eq 0) {
        Write-Success "Windows is already up to date."
    } else {
        Write-Host "   -> Found $($SearchResult.Updates.Count) updates. Downloading..." -ForegroundColor DarkGray
        $Downloader = $UpdateSession.CreateUpdateDownloader()
        $Downloader.Updates = $SearchResult.Updates
        $Downloader.Download() | Out-Null
        
        Write-Host "   -> Installing updates..." -ForegroundColor DarkGray
        $Installer = $UpdateSession.CreateUpdateInstaller()
        $Installer.Updates = $SearchResult.Updates
        $InstallResult = $Installer.Install()
        
        if ($InstallResult.ResultCode -eq 2) { Write-Success "Windows Updates installed successfully." }
        else { Write-WarningMsg "Updates finished (Code: $($InstallResult.ResultCode)). A reboot may be pending." }
    }
} catch {
    Write-ErrorMsg "Failed during Step 1. Error: $_"
}

# ==========================================
# STEP 2: Update Software via Winget
# ==========================================
Write-Step "Updating installed software via Winget"
try {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "Winget is not recognized on this PC."
    } else {
        Write-Host "   -> Refreshing Winget sources..." -ForegroundColor DarkGray
        Start-Process winget -ArgumentList "source update" -Wait -NoNewWindow -PassThru | Out-Null

        Write-Host "   -> Running Winget upgrade for all packages..." -ForegroundColor DarkGray
        $wingetArgs = @("upgrade", "--all", "--include-unknown", "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
        $wingetProc = Start-Process winget -ArgumentList $wingetArgs -Wait -NoNewWindow -PassThru

        if ($wingetProc.ExitCode -eq 0) { Write-Success "Winget successfully updated all software." }
        elseif ($wingetProc.ExitCode -match "-1978335189|-1978335198") { Write-Success "Winget scan complete: Software is up to date." }
        else { Write-WarningMsg "Winget completed with exit code: $($wingetProc.ExitCode). Some apps may require a reboot." }
    }
} catch {
    Write-ErrorMsg "Failed to execute Winget. Error: $_"
}

# ==========================================
# STEP 3: Safe Native Registry Cleanup
# ==========================================
Write-Step "Performing Safe Registry Cleanup"
try {
    Write-Host "   -> Clearing Explorer MRU and Run command history..." -ForegroundColor DarkGray
    $mruPaths = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs")
    foreach ($mru in $mruPaths) { if (Test-Path $mru) { Remove-ItemProperty -Path $mru -Name * -ErrorAction SilentlyContinue } }

    Write-Host "   -> Removing invalid Startup registry entries..." -ForegroundColor DarkGray
    $startupLocations = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce")
    foreach ($loc in $startupLocations) {
        if (Test-Path $loc) {
            $props = Get-ItemProperty -Path $loc
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -match "^PS") { continue }
                $cmd = [string]$prop.Value
                if ($cmd -match '(?:"([^"]+)"|([^\s]+))') {
                    $exePath = if ($matches[1]) { $matches[1] } else { $matches[2] }
                    $exePath = [System.Environment]::ExpandEnvironmentVariables($exePath)
                    if ($exePath -match '^[a-zA-Z]:\\' -and -not (Test-Path $exePath)) { Remove-ItemProperty -Path $loc -Name $prop.Name -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    Write-Host "   -> Removing invalid App Paths..." -ForegroundColor DarkGray
    $appPathsLoc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    if (Test-Path $appPathsLoc) {
        Get-ChildItem -Path $appPathsLoc | ForEach-Object {
            $defaultVal = (Get-ItemProperty -Path $_.PSPath).'(default)'
            if ($defaultVal) {
                $cleanPath = [System.Environment]::ExpandEnvironmentVariables($defaultVal.Trim('"'))
                if ($cleanPath -match '^[a-zA-Z]:\\' -and -not (Test-Path $cleanPath)) { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    Write-Success "Native registry cleanup completed safely."
} catch {
    Write-ErrorMsg "Error during registry cleanup: $_"
}

# ==========================================
# STEP 4: CCleaner Custom Clean
# ==========================================
Write-Step "Configuring and Running CCleaner"
try {
    $ccleanerDir = "C:\ITDepartment\CCleaner"
    $ccleanerExe = Join-Path $ccleanerDir "CCleaner64.exe"
    $ccleanerIni = Join-Path $ccleanerDir "ccleaner.ini"

    if (Test-Path $ccleanerExe) {
        Write-Host "   -> Configuring Edge Chromium exclusions..." -ForegroundColor DarkGray
        if (-not (Test-Path $ccleanerIni)) { Set-Content -Path $ccleanerIni -Value "[Options]" -Encoding UTF8 }

        $edgeRules = @{
            "(App)Edge Chromium - Saved Form Information" = "False"
            "(App)Edge Chromium - Saved Passwords"        = "False"
            "(App)Edge Chromium - Session"                = "False"
        }

        $iniContent = Get-Content $ccleanerIni
        foreach ($rule in $edgeRules.GetEnumerator()) {
            $key = $rule.Name; $value = $rule.Value
            if ($iniContent -match "^\[?.*$key.*\]?") {
                $iniContent = $iniContent -replace "^.*$key.*$", "$key=$value"
            } else {
                $iniContent += "$key=$value"
            }
        }
        Set-Content -Path $ccleanerIni -Value $iniContent -Encoding UTF8

        Write-Host "   -> Running CCleaner silently..." -ForegroundColor DarkGray
        $ccProc = Start-Process $ccleanerExe -ArgumentList "/AUTO" -Wait -NoNewWindow -PassThru
        
        if ($ccProc.ExitCode -eq 0) { Write-Success "CCleaner finished successfully." }
        else { Write-WarningMsg "CCleaner exited with code $($ccProc.ExitCode)." }
    } else {
        Write-WarningMsg "CCleaner executable not found at $ccleanerExe. Skipping."
    }
} catch {
    Write-ErrorMsg "Failed to configure or run CCleaner. Error: $_"
}

# ==========================================
# STEP 5: Deep System Disk Cleanup
# ==========================================
Write-Step "Running Windows Disk Cleanup silently"
try {
    $volumeCaches = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    if (Test-Path $volumeCaches) {
        Get-ChildItem -Path $volumeCaches | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name "StateFlags0001" -Value 2 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait -NoNewWindow
    Write-Success "Disk Cleanup finished."
} catch {
    Write-ErrorMsg "Error running Disk Cleanup: $_"
}

# ==========================================
# STEP 6: General PC Optimization (Clinic Tailored)
# ==========================================
Write-Step "Applying General PC Optimizations"
try {
    # 1. Disable Fast Startup (Hiberboot)
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue

    # 2. Configure Power Settings
    Write-Host "   -> Configuring power plan..." -ForegroundColor DarkGray
    powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    powercfg.exe /change standby-timeout-ac 0
    powercfg.exe /change monitor-timeout-ac 0 

    # 3. Disable AutoPlay/AutoRun
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" -Name "DisableAutoplay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -ErrorAction SilentlyContinue

    # 4. Optimize Visual Effects
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -ErrorAction SilentlyContinue

    Write-Success "PC Optimized for performance and remote stability."
} catch {
    Write-ErrorMsg "Error optimizing PC: $_"
}

# ==========================================
# STEP 7: Final Temp, Cache, and Spooler Cleanup
# ==========================================
Write-Step "Purging temporary files, update caches, and print queues"
try {
    # 1. Print Spooler cache
    Write-Host "   -> Resetting Print Spooler cache..." -ForegroundColor DarkGray
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path "C:\Windows\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Service -Name Spooler -ErrorAction SilentlyContinue

    # 2. Temp Folder Purge
    Write-Host "   -> Purging system and user temp folders..." -ForegroundColor DarkGray
    $junkPaths = @(
        $env:TEMP,
        "C:\Windows\Temp",
        "C:\Windows\Prefetch",
        "C:\Windows\SoftwareDistribution\Download",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
    )
    foreach ($path in $junkPaths) {
        if (Test-Path $path) { Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 3. Recycle Bin
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    Write-Success "All temporary data destroyed."
} catch {
    Write-ErrorMsg "Error during final cleanup: $_"
}

# ==========================================
# STEP 8: App Audit via Revo Uninstaller
# ==========================================
Write-Step "Launching Revo Uninstaller for App Audit"
try {
    $revoExe = "C:\ITDepartment\Revo Uninstaller Pro\RevoUPPort.exe"
    
    if (Test-Path $revoExe) {
        Write-Host "   -> Opening Revo Uninstaller so you can manually review installed apps..." -ForegroundColor DarkGray
        Start-Process $revoExe
        Write-Success "Revo Uninstaller launched."
    } else {
        Write-WarningMsg "Revo Uninstaller not found at $revoExe. Skipping app audit."
    }
} catch {
    Write-ErrorMsg "Failed to launch Revo Uninstaller: $_"
}

# ==========================================
# FINALIZATION
# ==========================================
Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host " SYSTEM OPTIMIZATION AND CLEANUP COMPLETE!" -ForegroundColor Green
Write-Host " A system restart is recommended to apply all changes." -ForegroundColor Yellow
Write-Host "=======================================================`n" -ForegroundColor Cyan