# =========================================================================
# ITcheck.ps1 - Clinic PC Maintenance Utility
# Interactive deployment script with auto-resume tracking
#
# Runs step by step (no Run All button).
#
# Changes in this revision:
#   - Step 1 now always removes Widgets, Task View (and Chat on Win 11) from the taskbar
#   - Auto-elevates instead of just exiting when not run as Admin
#   - Fixed self-delete in Step 8 ($MyInvocation.Path is empty inside functions)
#   - GUI stays responsive while winget / CCleaner / Revo / Settings are running
#   - Set-RegKey reports failures instead of silently swallowing them
#   - Step 1 dialog scrolls and fits small laptop screens
#   - Step 4 removes apps in-process (no extra PowerShell window per app)
#   - Step 7 uses Set-RegKey and creates the High Performance plan if missing
#   - Step 8 stops update services before purging, no longer wipes Prefetch
# =========================================================================

# --- Pre-flight: Ensure Admin Rights (auto-elevate if possible) ---
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($script:ScriptPath) {
        try {
            Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:ScriptPath)`""
        } catch {
            Write-Host "[-] Elevation was cancelled. Administrator rights are required." -ForegroundColor Red
        }
    } else {
        Write-Host "[-] This script requires Administrator privileges. Please run PowerShell as Admin." -ForegroundColor Red
    }
    exit
}

# --- Unlock Registry "God Mode" (SeTakeOwnershipPrivilege) ---
if (-not ([System.Management.Automation.PSTypeName]'PrivilegeManager').Type) {
    $TakeOwnershipCode = @'
using System;
using System.Runtime.InteropServices;
public class PrivilegeManager {
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    public static void EnablePrivilege(string privilege) {
        IntPtr htok = IntPtr.Zero;
        if (OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x00000028, ref htok)) {
            TokPriv1Luid tp = new TokPriv1Luid() { Count = 1, Luid = 0, Attr = 0x00000002 };
            if (LookupPrivilegeValue(null, privilege, ref tp.Luid)) {
                AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $TakeOwnershipCode
}
[PrivilegeManager]::EnablePrivilege("SeTakeOwnershipPrivilege")
[PrivilegeManager]::EnablePrivilege("SeRestorePrivilege")

# --- Load Windows Forms Framework ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================
# HELPERS
# ==========================================
$script:LogFonts = @{}

function Write-Log ([string]$Message, [string]$Color = "Black", [switch]$Bold) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $key = [string]$style
    if (-not $script:LogFonts.ContainsKey($key)) {
        $script:LogFonts[$key] = New-Object System.Drawing.Font($RichTextBox.Font, $style)
    }
    $RichTextBox.SelectionStart = $RichTextBox.TextLength
    $RichTextBox.SelectionLength = 0
    $RichTextBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
    $RichTextBox.SelectionFont = $script:LogFonts[$key]
    $RichTextBox.AppendText("$Message`n")
    $RichTextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-Step       ([string]$Message) { Write-Log "`n[*] $Message..." "Blue" -Bold }
function Write-Success    ([string]$Message) { Write-Log "[+] $Message" "Green" }
function Write-ErrorMsg   ([string]$Message) { Write-Log "[-] $Message" "Red" }
function Write-WarningMsg ([string]$Message) { Write-Log "[!] $Message" "DarkOrange" }

function Set-RegKey ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord", [switch]$Quiet) {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        return
    } catch {
        # Only machine-level keys get the take-ownership fallback
        if ($Path -like "HKLM:*") {
            try {
                $acl = Get-Acl $Path
                $acl.SetOwner((New-Object System.Security.Principal.NTAccount("Administrators")))
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
                $acl.SetAccessRule($rule)
                Set-Acl -Path $Path -AclObject $acl
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
                return
            } catch { }
        }
        if (-not $Quiet) { Write-WarningMsg "Could not set '$Name' at $Path" }
    }
}

function Get-RegKey ([string]$Path, [string]$Name, $Default) {
    try {
        $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ($null -eq $val) { return $Default }
        return [int]$val
    } catch {
        return $Default
    }
}

# Keeps the GUI responsive while an external process runs
function Wait-ProcessUI ([System.Diagnostics.Process]$Process) {
    $null = $Process.Handle   # cache handle so ExitCode is readable afterwards
    while (-not $Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { return }
    }
    Start-Process -FilePath "explorer.exe"
}

# ==========================================
# TRACKING & CLEANUP
# ==========================================
$StateDir       = "C:\ITDepartment\Step Check"
$StateFile      = Join-Path $StateDir "progress.txt"
$PublicDesktop  = [Environment]::GetFolderPath("CommonDesktopDirectory")
$ShortcutPath   = Join-Path $PublicDesktop "Resume PC Maintenance.lnk"

$script:StepNames = @{
    1 = "Configure Windows Settings"
    2 = "Run Windows Updates"
    3 = "Update Apps (Winget)"
    4 = "Remove Bloatware"
    5 = "Launch CCleaner"
    6 = "Launch Revo Uninstaller"
    7 = "Apply Clinic Optimizations"
    8 = "Purge Temp & Cache"
}
$script:StepButtons = @{}

function Save-StepState ([int]$StepNum) {
    if (-not (Test-Path $StateDir)) {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $existing = @()
    if (Test-Path $StateFile) { $existing = @(Get-Content $StateFile -ErrorAction SilentlyContinue) }
    if ($existing -notcontains [string]$StepNum) {
        Add-Content -Path $StateFile -Value $StepNum -Force -ErrorAction SilentlyContinue
    }
}

function Set-StepDone ([int]$StepNum) {
    Save-StepState $StepNum
    $script:StepButtons[$StepNum].Text = "[ DONE ] $StepNum. $($script:StepNames[$StepNum])"
}

function Get-StepState {
    if (Test-Path $StateFile) {
        $age = New-TimeSpan -Start (Get-Item $StateFile).LastWriteTime -End (Get-Date)

        # Tracking file older than 12 hours: nuke it and start over
        if ($age.TotalHours -gt 12) {
            Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $ShortcutPath) { Remove-Item -Path $ShortcutPath -Force -ErrorAction SilentlyContinue }
            return @()
        }
        return @(Get-Content $StateFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    }
    return @()
}

function Restart-PCNow {
    Write-WarningMsg "Restarting PC to apply changes..."
    Start-Sleep -Seconds 2
    Restart-Computer -Force
}

# ==========================================
# STEP MODULES
# ==========================================

function Run-Step1 {
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $isWin11 = [Environment]::OSVersion.Version.Build -ge 22000
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $SetForm = New-Object System.Windows.Forms.Form
    $SetForm.Text = "Configure Windows Settings"
    $SetForm.ClientSize = New-Object System.Drawing.Size(520, ([Math]::Min(790, $workArea.Height - 60)))
    $SetForm.StartPosition = "CenterParent"
    $SetForm.FormBorderStyle = "FixedDialog"
    $SetForm.MaximizeBox = $false

    # Scrollable settings area + fixed button bar (fits small laptop screens)
    $rowsPanel = New-Object System.Windows.Forms.Panel
    $rowsPanel.Dock = "Fill"
    $rowsPanel.AutoScroll = $true
    $SetForm.Controls.Add($rowsPanel)

    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = "Bottom"
    $btnPanel.Height = 70
    $SetForm.Controls.Add($btnPanel)
    $rowsPanel.BringToFront()

    $script:yOffset = 20

    function Add-SettingRow ([string]$LabelText, [string]$Opt0_Text, [string]$Opt0_Desc, [string]$Opt1_Text, [string]$Opt1_Desc, [int]$StandardIndex, [int]$CurrentIndex) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText
        $lbl.Location = New-Object System.Drawing.Point(20, $script:yOffset)
        $lbl.Size = New-Object System.Drawing.Size(160, 25)
        $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $rowsPanel.Controls.Add($lbl)

        $cmb = New-Object System.Windows.Forms.ComboBox
        $cmb.DropDownStyle = "DropDownList"
        $cmb.Items.Add($Opt0_Text) | Out-Null
        $cmb.Items.Add($Opt1_Text) | Out-Null
        $cmb.Location = New-Object System.Drawing.Point(190, ($script:yOffset - 3))
        $cmb.Size = New-Object System.Drawing.Size(280, 25)
        $rowsPanel.Controls.Add($cmb)

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Location = New-Object System.Drawing.Point(190, ($script:yOffset + 24))
        $lblDesc.Size = New-Object System.Drawing.Size(290, 40)
        $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
        $rowsPanel.Controls.Add($lblDesc)

        $cmb.Add_SelectedIndexChanged({
            $lblDesc.Text = if ($this.SelectedIndex -eq 0) { $Opt0_Desc } else { $Opt1_Desc }
            $lblDesc.ForeColor = if ($this.SelectedIndex -eq $StandardIndex) { [System.Drawing.Color]::Blue } else { [System.Drawing.Color]::Red }
        }.GetNewClosure())

        $cmb.SelectedIndex = $CurrentIndex
        $script:yOffset += 85
        return $cmb
    }

    # --- Read current state ---
    $curTheme   = if ((Get-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" 1) -eq 0) { 0 } else { 1 }
    $curNotif   = if ((Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1) -eq 0) { 0 } else { 1 }
    $curRDP     = if ((Get-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 1) -eq 0) { 0 } else { 1 }
    $curStorage = if ((Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 0) -eq 0) { 0 } else { 1 }
    $curPrivacy = if ((Get-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 3) -eq 0) { 0 } else { 1 }
    $curWinPerm = if ((Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1) -eq 0) { 0 } else { 1 }
    $curGaming  = if ((Get-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 1) -eq 0) { 0 } else { 1 }

    $curTaskbar = 0
    if ($isWin11) {
        $curTaskbar = if ((Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 1) -eq 0) { 0 } else { 1 }
    }

    # --- Build rows ---
    $cmbTheme   = Add-SettingRow "System Theme:" "Dark Mode" "Sets Windows apps and system background to Dark Mode." "Light Mode (Comodo Standard)" "Sets standard Windows app and system background colors." 1 $curTheme

    $taskbarLabel = if ($isWin11) { "Taskbar Alignment:" } else { "Taskbar (Win 11 Only):" }
    $cmbTaskbar = Add-SettingRow $taskbarLabel "Left (Comodo Standard)" "Aligns taskbar left. Widgets, Task View & Chat are always removed on Apply." "Center" "Aligns taskbar to the center. Widgets, Task View & Chat are always removed on Apply." 0 $curTaskbar
    if (-not $isWin11) { $cmbTaskbar.Enabled = $false }

    $cmbNotif   = Add-SettingRow "Notifications:" "Disabled (Comodo Standard)" "Turns off notification center tracking and toast pop-ups." "Enabled" "Leaves Windows notifications and toast pop-ups turned on." 0 $curNotif
    $cmbRDP     = Add-SettingRow "Remote Desktop:" "Enabled (Comodo Standard)" "Allows RDP access and securely configures Windows Firewall." "Disabled" "Blocks incoming Remote Desktop connections to this PC." 0 $curRDP
    $cmbStorage = Add-SettingRow "Storage Sense:" "Disabled" "Turns off automated Storage Sense background cleanup." "Enabled (Comodo Standard)" "Auto-deletes Recycle Bin (1 Day) and Downloads folder (14 Days)." 1 $curStorage
    $cmbPrivacy = Add-SettingRow "Privacy Tracking:" "Secure/Disabled (Comodo Standard)" "Disables diagnostic data, search history, speech targeting, & inking." "Windows Default (Enabled)" "Allows Microsoft to collect telemetry, inking, and diagnostic data." 0 $curPrivacy
    $cmbWinPerm = Add-SettingRow "Windows Permissions:" "Disabled (Comodo Standard)" "Turns off Ad ID, Activity History, App Launch tracking, and Tailored Experiences." "Windows Default (Enabled)" "Leaves standard Windows behavior tracking active." 0 $curWinPerm
    $cmbGaming  = Add-SettingRow "Gaming Features:" "Disabled (Comodo Standard)" "Turns off Game Mode, Xbox Game Bar, Game DVR, and background recording." "Enabled" "Leaves Game Mode, Xbox Game Bar, and background recording on." 0 $curGaming

    # --- Buttons ---
    $btnSetStandard = New-Object System.Windows.Forms.Button
    $btnSetStandard.Text = "Set All Standard"
    $btnSetStandard.Size = New-Object System.Drawing.Size(140, 40)
    $btnSetStandard.Location = New-Object System.Drawing.Point(20, 15)
    $btnSetStandard.BackColor = [System.Drawing.Color]::LightYellow
    $btnSetStandard.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSetStandard.Add_Click({
        $cmbTheme.SelectedIndex = 1
        if ($isWin11) { $cmbTaskbar.SelectedIndex = 0 }
        $cmbNotif.SelectedIndex = 0
        $cmbRDP.SelectedIndex = 0
        $cmbStorage.SelectedIndex = 1
        $cmbPrivacy.SelectedIndex = 0
        $cmbWinPerm.SelectedIndex = 0
        $cmbGaming.SelectedIndex = 0
    })
    $btnPanel.Controls.Add($btnSetStandard)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply Settings"
    $btnApply.Size = New-Object System.Drawing.Size(160, 40)
    $btnApply.Location = New-Object System.Drawing.Point(170, 15)
    $btnApply.BackColor = [System.Drawing.Color]::LightBlue
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnApply.Add_Click({
        $SetForm.Close()
        Write-Step "Applying custom Windows settings"

        # --- Theme ---
        $idxTheme  = $cmbTheme.SelectedIndex
        $themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Set-RegKey $themePath "AppsUseLightTheme" $idxTheme
        Set-RegKey $themePath "SystemUsesLightTheme" $idxTheme

        # --- Taskbar: always remove Task View + Widgets (+ Chat on Win 11) ---
        $advPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Set-RegKey $advPath "ShowTaskViewButton" 0

        if ($isWin11) {
            Set-RegKey $advPath "TaskbarAl" $cmbTaskbar.SelectedIndex
            Set-RegKey $advPath "TaskbarMn" 0 -Quiet                                  # Chat
            Set-RegKey $advPath "TaskbarDa" 0 -Quiet                                  # Widgets (can be blocked on newer builds)
            Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0   # Widgets (policy - reliable)
            Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" "ChatIcon" 3 -Quiet
            Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 3
        } else {
            # Windows 10: "News and Interests" is the equivalent of Widgets
            Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode" 2
            Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0 -Quiet
        }
        Write-Success "Widgets and Task View removed from taskbar."

        # --- Notifications ---
        $idxNotif = $cmbNotif.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" $idxNotif
        Set-RegKey "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" $(if ($idxNotif -eq 0) { 1 } else { 0 })

        # --- Remote Desktop ---
        $idxRDP = $cmbRDP.SelectedIndex
        Set-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" $idxRDP
        if ($idxRDP -eq 0) {
            Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
        } else {
            Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
        }

        # --- Storage Sense ---
        $idxStorage  = $cmbStorage.SelectedIndex
        $storagePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        Set-RegKey $storagePath "01" $idxStorage
        if ($idxStorage -eq 1) {
            Set-RegKey $storagePath "08" 1
            Set-RegKey $storagePath "256" 1
            Set-RegKey $storagePath "32" 1
            Set-RegKey $storagePath "512" 14
        } else {
            Set-RegKey $storagePath "08" 0
            Set-RegKey $storagePath "32" 0
        }

        # --- Privacy ---
        $idxPrivacy = $cmbPrivacy.SelectedIndex
        $restrict   = if ($idxPrivacy -eq 0) { 1 } else { 0 }
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" $restrict
        Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" $restrict

        # --- Windows Permissions ---
        $idxWinPerm = $cmbWinPerm.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" $idxWinPerm
        Set-RegKey $advPath "Start_TrackProgs" $idxWinPerm
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" $idxWinPerm
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" $idxWinPerm
        Set-RegKey "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" $(if ($idxWinPerm -eq 0) { 1 } else { 0 })

        # --- Gaming ---
        $idxGaming = $cmbGaming.SelectedIndex
        Set-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" $idxGaming
        Set-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" $idxGaming
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" $idxGaming
        Set-RegKey "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" $idxGaming

        Write-Success "Settings applied. Restarting Explorer..."
        Restart-Explorer

        Set-StepDone 1
    })
    $btnPanel.Controls.Add($btnApply)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close / Keep Current"
    $btnCancel.Size = New-Object System.Drawing.Size(160, 40)
    $btnCancel.Location = New-Object System.Drawing.Point(340, 15)
    $btnCancel.BackColor = [System.Drawing.Color]::LightGray
    $btnCancel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Add_Click({
        $SetForm.Close()
        Write-Success "Windows Settings reviewed and kept current."
        Set-StepDone 1
    })
    $btnPanel.Controls.Add($btnCancel)

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $SetForm.ShowDialog() | Out-Null
}

function Run-Step2 {
    Write-Step "Step 2: Windows Updates"
    Write-Log "   -> Opening Settings and starting interactive scan..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath "explorer.exe"
            Start-Sleep -Seconds 2
        }

        Start-Process -FilePath "ms-settings:windowsupdate" -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Process -FilePath "usoclient.exe" -ArgumentList "StartInteractiveScan" -WindowStyle Hidden -ErrorAction SilentlyContinue

        Write-Log "   -> Script paused. Waiting for IT to close the Settings app..." "DarkGray"
        while (Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
        }

        Write-Success "Windows Settings closed. Step logged as complete."
        Set-StepDone 2
    } catch {
        Write-ErrorMsg "Failed to process Windows Updates: $_"
    }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step3 {
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $UpdateForm = New-Object System.Windows.Forms.Form
    $UpdateForm.Text = "Software Updates (Winget)"
    $UpdateForm.Size = New-Object System.Drawing.Size(650, 450)
    $UpdateForm.StartPosition = "CenterParent"
    $UpdateForm.FormBorderStyle = "FixedDialog"
    $UpdateForm.MaximizeBox = $false

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Available Software Updates:"
    $lblInfo.Location = New-Object System.Drawing.Point(15, 15)
    $lblInfo.AutoSize = $true
    $lblInfo.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($lblInfo)

    $txtOutput = New-Object System.Windows.Forms.RichTextBox
    $txtOutput.Location = New-Object System.Drawing.Point(15, 40)
    $txtOutput.Size = New-Object System.Drawing.Size(600, 300)
    $txtOutput.Font = New-Object System.Drawing.Font("Consolas", 9)
    $txtOutput.ReadOnly = $true
    $txtOutput.BackColor = [System.Drawing.Color]::Black
    $txtOutput.ForeColor = [System.Drawing.Color]::LimeGreen
    $txtOutput.Text = "Refreshing repositories and scanning for updates... Please wait.`n"
    $UpdateForm.Controls.Add($txtOutput)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = "Install All Updates"
    $btnUpdate.Location = New-Object System.Drawing.Point(15, 355)
    $btnUpdate.Size = New-Object System.Drawing.Size(180, 40)
    $btnUpdate.Enabled = $false
    $btnUpdate.BackColor = [System.Drawing.Color]::LightGreen
    $btnUpdate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($btnUpdate)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close / Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(435, 355)
    $btnCancel.Size = New-Object System.Drawing.Size(180, 40)
    $btnCancel.Add_Click({ $UpdateForm.Close() })
    $UpdateForm.Controls.Add($btnCancel)

    $btnUpdate.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "WARNING: Winget will update ALL out-of-date software.`n`nIf it updates your remote access tool (e.g., AnyDesk, TeamViewer, Splashtop), YOUR REMOTE CONNECTION WILL DROP.`n`nDo you want to proceed?",
            "Remote Connection Warning",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq "No") { return }

        $btnUpdate.Enabled = $false
        $btnCancel.Enabled = $false
        $txtOutput.AppendText("`n`nStarting silent background installation... Please wait.")
        $UpdateForm.Update()

        Write-Step "Applying software updates via Winget"
        $proc = Start-Process -FilePath "winget.exe" -ArgumentList "upgrade --all --include-unknown --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru
        Wait-ProcessUI $proc

        # -1978335189 = "no applicable upgrade" (not an error)
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) {
            Write-Success "Winget successfully updated all software."
        } else {
            Write-WarningMsg "Winget completed with exit code: $($proc.ExitCode). Some apps may require a reboot."
        }

        $UpdateForm.Close()
        Set-StepDone 3
    })

    $UpdateForm.Add_Shown({
        $UpdateForm.Update()
        try {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                $txtOutput.Text = "Error: Winget is not installed or recognized on this PC."
            } else {
                $src = Start-Process -FilePath "winget.exe" -ArgumentList "source update" -NoNewWindow -PassThru
                Wait-ProcessUI $src

                # Same flags as the install step, so this list matches what will actually be updated
                $wingetOut = winget upgrade --include-unknown --accept-source-agreements | Out-String
                $cleanOut  = $wingetOut -replace "\x1B\[[0-9;]*[a-zA-Z]", ""

                if ($cleanOut -match "No installed package found matching input criteria" -or $cleanOut -match "No available upgrades" -or $cleanOut -match "No applicable upgrade") {
                    $txtOutput.Text = "Scan Complete: All installed software is already up to date!"
                    Set-StepDone 3
                } else {
                    $txtOutput.Text = $cleanOut
                    $btnUpdate.Enabled = $true
                }
            }
        } catch {
            $txtOutput.Text = "Failed to scan via Winget. Error: $_"
        }
    })

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $UpdateForm.ShowDialog() | Out-Null
}

function Run-Step4 {
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $bloatList = @(
        "Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GamingApp",
        "Microsoft.GetHelp", "Microsoft.Getstarted",
        "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.Xbox.TCUI",
        "Microsoft.XboxApp", "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay", "Microsoft.YourPhone",
        "Microsoft.ZuneMusic", "Microsoft.ZuneVideo", "Microsoft.549981C3F5F10"
    )

    Write-Step "Scanning for known Windows bloatware"
    $installedBloat = @($bloatList | Where-Object { Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue })

    if ($installedBloat.Count -eq 0) {
        Write-Success "No known bloatware found on this PC."
        Set-StepDone 4
        $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        return
    }

    $BloatForm = New-Object System.Windows.Forms.Form
    $BloatForm.Text = "Remove Bloatware"
    $BloatForm.Size = New-Object System.Drawing.Size(400, 450)
    $BloatForm.StartPosition = "CenterParent"
    $BloatForm.FormBorderStyle = "FixedDialog"
    $BloatForm.MaximizeBox = $false

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Select bloatware to remove:"
    $lblInfo.Location = New-Object System.Drawing.Point(15, 15)
    $lblInfo.AutoSize = $true
    $lblInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $BloatForm.Controls.Add($lblInfo)

    $chkList = New-Object System.Windows.Forms.CheckedListBox
    $chkList.Location = New-Object System.Drawing.Point(15, 40)
    $chkList.Size = New-Object System.Drawing.Size(350, 300)
    $chkList.CheckOnClick = $true
    foreach ($app in $installedBloat) { $chkList.Items.Add($app, $true) | Out-Null }
    $BloatForm.Controls.Add($chkList)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = "Uninstall Selected"
    $btnUninstall.Location = New-Object System.Drawing.Point(15, 355)
    $btnUninstall.Size = New-Object System.Drawing.Size(160, 40)
    $btnUninstall.BackColor = [System.Drawing.Color]::LightCoral
    $btnUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $BloatForm.Controls.Add($btnUninstall)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Skip / Keep All"
    $btnSkip.Location = New-Object System.Drawing.Point(205, 355)
    $btnSkip.Size = New-Object System.Drawing.Size(160, 40)
    $btnSkip.Add_Click({
        $BloatForm.Close()
        Set-StepDone 4
        Write-Log "   -> Bloatware removal skipped." "DarkGray"
    })
    $BloatForm.Controls.Add($btnSkip)

    $btnUninstall.Add_Click({
        $btnUninstall.Enabled = $false
        $btnSkip.Enabled = $false
        $BloatForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Write-Log "   -> Removing selected bloatware... this may take a moment." "DarkGray"
        $BloatForm.Update()

        foreach ($item in @($chkList.CheckedItems)) {
            Write-Log "   -> Removing $item" "DarkGray"
            try {
                Get-AppxPackage -Name $item -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq $item } |
                    Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Write-WarningMsg "Could not fully remove ${item}: $_"
            }
        }

        Write-Success "Selected bloatware removed."
        $BloatForm.Close()
        Set-StepDone 4
    })

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $BloatForm.ShowDialog() | Out-Null
}

# Makes sure a tool is present: if the exe is missing, finds its zip, extracts it, then returns the exe path
function Resolve-ToolPath ([string]$Exe, [string]$Label, [string]$ZipPattern) {
    if (Test-Path $Exe) { return $Exe }

    $root = "C:\ITDepartment"
    $searchDirs = @($root)
    if ($script:ScriptPath) { $searchDirs += (Split-Path $script:ScriptPath) }

    Write-Log "   -> $Label not found. Looking for a zip to extract..." "DarkGray"
    $zip = $null
    foreach ($dir in ($searchDirs | Select-Object -Unique)) {
        $zip = Get-ChildItem -Path $dir -Filter $ZipPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($zip) { break }
    }
    if (-not $zip) {
        Write-WarningMsg "No zip matching '$ZipPattern' found in $($searchDirs -join ', ')."
        return $null
    }

    Write-Log "   -> Extracting $($zip.Name)..." "DarkGray"
    $staging = Join-Path $env:TEMP ("ITtool_" + [guid]::NewGuid().ToString("N"))
    try {
        Expand-Archive -Path $zip.FullName -DestinationPath $staging -Force -ErrorAction Stop

        $targetDir = Split-Path $Exe
        if (Test-Path (Join-Path $staging (Split-Path $Exe -Leaf))) {
            # Zip contents are the app files themselves -> put them in the app folder
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $staging "*") -Destination $targetDir -Recurse -Force
        } else {
            # Zip contains the app folder -> extract into C:\ITDepartment
            Copy-Item -Path (Join-Path $staging "*") -Destination $root -Recurse -Force
        }
    } catch {
        Write-ErrorMsg "Failed to extract $($zip.Name): $_"
        return $null
    } finally {
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $Exe) { return $Exe }

    # Zip used a different folder layout: look for the exe anywhere under C:\ITDepartment
    $found = Get-ChildItem -Path $root -Filter (Split-Path $Exe -Leaf) -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    Write-WarningMsg "Extracted $($zip.Name) but could not find $(Split-Path $Exe -Leaf)."
    return $null
}

function Invoke-ExternalTool ([string]$Exe, [string]$Label, [int]$StepNum, [string]$ZipPattern) {
    Write-Step "Step ${StepNum}: Launching $Label"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $path = Resolve-ToolPath $Exe $Label $ZipPattern
        if ($path) {
            Write-Log "   -> Script paused. Waiting for IT to finish and close $Label..." "DarkGray"
            $proc = Start-Process -FilePath $path -PassThru
            Wait-ProcessUI $proc
            Write-Success "$Label closed. Step logged as complete."
            Set-StepDone $StepNum
        } else {
            Write-WarningMsg "$Label is not available. Step not marked complete."
        }
    } catch {
        Write-ErrorMsg "Failed to launch ${Label}: $_"
    }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step5 { Invoke-ExternalTool "C:\ITDepartment\CCleaner\CCleaner64.exe" "CCleaner" 5 "*CCleaner*.zip" }
function Run-Step6 { Invoke-ExternalTool "C:\ITDepartment\Revo Uninstaller Pro\RevoUPPort.exe" "Revo Uninstaller" 6 "Revo Uninstaller Pro Portable*.zip" }

function Run-Step7 {
    Write-Step "Step 7: Clinic PC Optimizations"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # Disable Fast Startup
        Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0

        # High Performance plan (create it if the OEM image removed it)
        $highPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        if (-not (powercfg /list 2>$null | Select-String $highPerf)) {
            powercfg /duplicatescheme $highPerf $highPerf 2>$null | Out-Null
        }
        powercfg /setactive $highPerf 2>$null
        powercfg /change standby-timeout-ac 0
        powercfg /change monitor-timeout-ac 0

        # Autoplay / AutoRun off
        Set-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
        Set-RegKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" 255

        # Visual effects: best performance
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2

        Write-Success "PC optimized for performance and stability."
        Set-StepDone 7
    } catch {
        Write-ErrorMsg "Error optimizing PC: $_"
    }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step8 {
    Write-Step "Step 8: Purging Temp & Cache"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-Log "   -> Purging system and user temp folders..." "DarkGray"

        # Stop update services so SoftwareDistribution\Download isn't locked; restart only what was running
        $svcs = @("wuauserv", "bits")
        $wasRunning = @($svcs | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq "Running" })
        Stop-Service -Name $svcs -Force -ErrorAction SilentlyContinue

        $junkPaths = @(
            $env:TEMP,
            "C:\Windows\Temp",
            "C:\Windows\SoftwareDistribution\Download",
            "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
        )
        foreach ($path in $junkPaths) {
            if (Test-Path $path) {
                Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        foreach ($s in $wasRunning) { Start-Service -Name $s -ErrorAction SilentlyContinue }
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue

        Write-Success "All temporary data and cache purged."
        Set-StepDone 8

        $result = [System.Windows.Forms.MessageBox]::Show(
            "All optimization steps are completely finished! Would you like to restart the PC now to finalize everything?",
            "Final Restart",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information)

        if ($result -eq "Yes") {
            # 1. Clean up tracking folder and shortcut
            if (Test-Path $StateDir)     { Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $ShortcutPath) { Remove-Item -Path $ShortcutPath -Force -ErrorAction SilentlyContinue }

            # 2. Delete this script (and browser-style duplicates like "ITcheck (1).ps1") before rebooting
            if ($script:ScriptPath) {
                $scriptDir = Split-Path $script:ScriptPath
                $baseName  = [IO.Path]::GetFileNameWithoutExtension($script:ScriptPath) -replace ' \(\d+\)$', ''
                $pattern   = "^$([regex]::Escape($baseName))( \(\d+\))?$"
                Get-ChildItem -Path $scriptDir -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -match $pattern } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }

            # 3. Restart
            Restart-PCNow
        }
    } catch {
        Write-ErrorMsg "Error during final cleanup: $_"
    }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

# ==========================================
# UI CONSTRUCTION
# ==========================================
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "Clinic PC Maintenance Utility"
$MainForm.Size = New-Object System.Drawing.Size(750, 520)
$MainForm.StartPosition = "CenterScreen"
$MainForm.FormBorderStyle = "FixedDialog"
$MainForm.MaximizeBox = $false

$TitleFont = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$BtnFont   = New-Object System.Drawing.Font("Segoe UI", 9)
$LogFont   = New-Object System.Drawing.Font("Consolas", 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "System Optimization Toolkit"
$lblTitle.Font = $TitleFont
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(15, 15)
$MainForm.Controls.Add($lblTitle)

$Panel = New-Object System.Windows.Forms.FlowLayoutPanel
$Panel.Location = New-Object System.Drawing.Point(15, 50)
$Panel.Size = New-Object System.Drawing.Size(250, 380)
$Panel.FlowDirection = "TopDown"
$Panel.WrapContents = $false
$MainForm.Controls.Add($Panel)

function Add-GuiButton ([string]$Text, [scriptblock]$Action) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size(240, 35)
    $btn.Font = $BtnFont
    $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 5)
    $btn.Add_Click($Action)
    $Panel.Controls.Add($btn)
    return $btn
}

$script:StepButtons[1] = Add-GuiButton "1. $($script:StepNames[1])" { Run-Step1 }
$script:StepButtons[2] = Add-GuiButton "2. $($script:StepNames[2])" { Run-Step2 }
$script:StepButtons[3] = Add-GuiButton "3. $($script:StepNames[3])" { Run-Step3 }
$script:StepButtons[4] = Add-GuiButton "4. $($script:StepNames[4])" { Run-Step4 }
$script:StepButtons[5] = Add-GuiButton "5. $($script:StepNames[5])" { Run-Step5 }
$script:StepButtons[6] = Add-GuiButton "6. $($script:StepNames[6])" { Run-Step6 }
$script:StepButtons[7] = Add-GuiButton "7. $($script:StepNames[7])" { Run-Step7 }
$script:StepButtons[8] = Add-GuiButton "8. $($script:StepNames[8])" { Run-Step8 }

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart PC"
$btnRestart.Size = New-Object System.Drawing.Size(240, 35)
$btnRestart.Location = New-Object System.Drawing.Point(15, 440)
$btnRestart.Font = $BtnFont
$btnRestart.BackColor = [System.Drawing.Color]::LightPink
$btnRestart.Add_Click({ Restart-PCNow })
$MainForm.Controls.Add($btnRestart)

$RichTextBox = New-Object System.Windows.Forms.RichTextBox
$RichTextBox.Location = New-Object System.Drawing.Point(280, 50)
$RichTextBox.Size = New-Object System.Drawing.Size(435, 370)
$RichTextBox.Font = $LogFont
$RichTextBox.ReadOnly = $true
$RichTextBox.BackColor = [System.Drawing.Color]::White
$RichTextBox.ScrollBars = "Vertical"
$MainForm.Controls.Add($RichTextBox)

# --- Desktop shortcut for easy resuming (runs as Admin) ---
if ($script:ScriptPath -and -not (Test-Path $ShortcutPath)) {
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$($script:ScriptPath)`""
        $Shortcut.IconLocation = "powershell.exe,0"
        $Shortcut.Save()

        # Force "Run as Administrator" via the LinkFlags byte
        $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
        $bytes[21] = $bytes[21] -bor 0x20
        [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
    } catch { }
}

Write-Log "Welcome to the Clinic PC Maintenance Utility." "DarkCyan" -Bold
Write-Log "Click each step in order, one at a time." "Black"
Write-Log "Use the restart button below when you need to reboot the system." "DarkGray"
Write-Log "Note: The script will pause while external tools are open.`n" "DarkGray"

# --- Check for previous progress on launch ---
$completedSteps = Get-StepState
if ($completedSteps.Count -gt 0) {
    Write-Log "   -> Resuming session. Marking completed steps..." "DarkOrange" -Bold
    foreach ($i in 1..8) {
        if ($completedSteps -contains $i) {
            $script:StepButtons[$i].Text = "[ DONE ] $i. $($script:StepNames[$i])"
        }
    }
}

# Render the GUI
$MainForm.ShowDialog() | Out-Null
