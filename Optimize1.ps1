# =========================================================================
# Optimize-ClinicPC-Lite.ps1
# Automated Script: Windows Settings & Software Updates Only
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
# FINALIZATION
# ==========================================
Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host " OS SETTINGS AND SOFTWARE UPDATES COMPLETE!" -ForegroundColor Green
Write-Host " A system restart is recommended to apply all changes." -ForegroundColor Yellow
Write-Host "=======================================================`n" -ForegroundColor Cyan