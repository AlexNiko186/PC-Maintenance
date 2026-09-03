# =========================================================================
# ClinicOptimizer-GUI.ps1
# Interactive GUI Deployment Script with Auto-Resume State Tracking
# =========================================================================

# --- Pre-flight Check: Ensure Admin Rights ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[-] This script requires Administrator privileges. Please run PowerShell as Admin." -ForegroundColor Red
    exit
}

# --- Unlock Registry "God Mode" (SeTakeOwnershipPrivilege) ---
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
[PrivilegeManager]::EnablePrivilege("SeTakeOwnershipPrivilege")
[PrivilegeManager]::EnablePrivilege("SeRestorePrivilege")

# --- Load Windows Forms Framework ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- GUI Logging & Helper Functions ---
function Write-Log ([string]$Message, [string]$Color = "Black", [switch]$Bold) {
    if ($RichTextBox.InvokeRequired) {
        $RichTextBox.Invoke([action]{ Write-Log -Message $Message -Color $Color -Bold:$Bold })
        return
    }
    $RichTextBox.SelectionStart = $RichTextBox.TextLength
    $RichTextBox.SelectionLength = 0
    $RichTextBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
    if ($Bold) { $RichTextBox.SelectionFont = New-Object System.Drawing.Font($RichTextBox.Font, [System.Drawing.FontStyle]::Bold) }
    else { $RichTextBox.SelectionFont = New-Object System.Drawing.Font($RichTextBox.Font, [System.Drawing.FontStyle]::Regular) }
    $RichTextBox.AppendText("$Message`n")
    $RichTextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-Step ([string]$Message) { Write-Log "`n[*] $Message..." "Blue" -Bold }
function Write-Success ([string]$Message) { Write-Log "[+] $Message" "Green" }
function Write-ErrorMsg ([string]$Message) { Write-Log "[-] $Message" "Red" }
function Write-WarningMsg ([string]$Message) { Write-Log "[!] $Message" "DarkOrange" }

function Set-RegKey {
    param ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        try {
            # Bypass TrustedInstaller to force protected keys
            $acl = Get-Acl $Path
            $adminGroup = New-Object System.Security.Principal.NTAccount("Administrators")
            $acl.SetOwner($adminGroup)
            $accessRule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $acl.SetAccessRule($accessRule)
            Set-Acl -Path $Path -AclObject $acl
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Get-RegKey {
    param ([string]$Path, [string]$Name, $Default)
    try {
        $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ($null -eq $val) { return $Default }
        return $val
    } catch { return $Default }
}

# --- INDIVIDUAL STEP TRACKING MECHANISM ---
$StateDir = "C:\ITDepartment\Step Check"
$StateFile = Join-Path $StateDir "progress.txt"

function Save-StepState ([int]$StepNum) {
    if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }

    $existing = @()
    if (Test-Path $StateFile) { $existing = Get-Content $StateFile -ErrorAction SilentlyContinue }
    if ($existing -notcontains $StepNum) { Add-Content -Path $StateFile -Value $StepNum -Force -ErrorAction SilentlyContinue }
}

function Get-StepState {
    if (Test-Path $StateFile) {
        return @(Get-Content $StateFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '\d' } | ForEach-Object { [int]$_ })
    }
    return @()
}

# --- SELF-DELETION AFTER RESTART ---
function Schedule-SelfDeleteAndRestart {
    $scriptPath = $MyInvocation.MyCommand.Path
    $batPath = "$env:TEMP\delete_self.bat"

    # Create batch file that waits for script to exit then deletes it
    $batContent = "@echo off
:wait
timeout /t 2 >nul
if exist `"$scriptPath`" (
    del `"$scriptPath`"
) else (
    goto :eof
)
goto :wait"

    Set-Content -Path $batPath -Value $batContent -Encoding ASCII -Force
    Start-Process -FilePath $batPath -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null

    # Restart the computer
    Write-WarningMsg "Scheduling self-deletion and restarting PC..."
    Start-Sleep -Seconds 2
    Restart-Computer -Force
}

# function for the user to manually restart when needed
function Restart-Computer-Manually {
    Schedule-SelfDeleteAndRestart
}

# ==========================================
# SCRIPT MODULES (The 7 Steps)
# ==========================================

function Run-Step1 {
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $SetForm = New-Object System.Windows.Forms.Form
    $SetForm.Text = "Configure Windows Settings"
    $SetForm.Size = New-Object System.Drawing.Size(540, 1000) # Made tall enough to fit the new Permissions row
    $SetForm.StartPosition = "CenterParent"
    $SetForm.FormBorderStyle = "FixedDialog"
    $SetForm.MaximizeBox = $false

    $script:yOffset = 20

    function Add-SettingRow ([string]$LabelText, [string]$Opt0_Text, [string]$Opt0_Desc, [string]$Opt1_Text, [string]$Opt1_Desc, [int]$StandardIndex, [int]$CurrentIndex) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText; $lbl.Location = New-Object System.Drawing.Point(20, $script:yOffset); $lbl.Size = New-Object System.Drawing.Size(160, 25)
        $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $SetForm.Controls.Add($lbl)

        $cmb = New-Object System.Windows.Forms.ComboBox
        $cmb.DropDownStyle = "DropDownList"
        $cmb.Items.Add($Opt0_Text) | Out-Null
        $cmb.Items.Add($Opt1_Text) | Out-Null
        $cmb.Location = New-Object System.Drawing.Point(190, ($script:yOffset - 3)); $cmb.Size = New-Object System.Drawing.Size(280, 25)
        $SetForm.Controls.Add($cmb)

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Location = New-Object System.Drawing.Point(190, ($script:yOffset + 24))
        $lblDesc.Size = New-Object System.Drawing.Size(290, 40)
        $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
        $SetForm.Controls.Add($lblDesc)

        $cmb.Add_SelectedIndexChanged({
            if ($this.SelectedIndex -eq 0) { $lblDesc.Text = $Opt0_Desc }
            else { $lblDesc.Text = $Opt1_Desc }

            if ($this.SelectedIndex -eq $StandardIndex) { $lblDesc.ForeColor = [System.Drawing.Color]::Blue }
            else { $lblDesc.ForeColor = [System.Drawing.Color]::Red }
        }.GetNewClosure())

        $cmb.SelectedIndex = $CurrentIndex
        $script:yOffset += 85
        return $cmb
    }

    # --- READ CURRENT SYSTEM SETTINGS ---
    $curTheme = Get-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" 1
    if ($curTheme -ne 0) { $curTheme = 1 }

    $curTaskbar = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0
    if ($curTaskbar -ne 0) { $curTaskbar = 1 }

    $curNotif = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1
    if ($curNotif -ne 0) { $curNotif = 1 }

    $curRDP = Get-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 1
    if ($curRDP -ne 0) { $curRDP = 1 }

    $curStorage = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 0
    if ($curStorage -ne 0) { $curStorage = 1 }

    $curPrivacyVal = Get-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 1
    $curPrivacy = if ($curPrivacyVal -eq 0) { 0 } else { 1 }

    $curWinPermVal = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1
    $curWinPerm = if ($curWinPermVal -eq 0) { 0 } else { 1 }

    $curGaming = Get-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 1
    if ($curGaming -ne 0) { $curGaming = 1 }

    $curWifiVal = Get-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 2
    $curWifi = if ($curWifiVal -eq 4) { 0 } else { 1 }

    $curBTVal = Get-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 3
    $curBT = if ($curBTVal -eq 4) { 0 } else { 1 }

    # --- BUILD THE DYNAMIC MENUS ---
    $cmbTheme = Add-SettingRow "System Theme:" "Dark Mode" "Sets Windows apps and system background to Dark Mode." "Light Mode (Comodo Standard)" "Sets standard Windows app and system background colors." 1 $curTheme
    $cmbTaskbar = Add-SettingRow "Taskbar Alignment:" "Left (Comodo Standard)" "Aligns taskbar left and hides Widgets, Chat, and Search box." "Center" "Aligns taskbar to the center and leaves Widgets/Search enabled." 0 $curTaskbar
    $cmbNotif = Add-SettingRow "Notifications:" "Disabled (Comodo Standard)" "Turns off notification center tracking and toast pop-ups." "Enabled" "Leaves Windows notifications and toast pop-ups turned on." 0 $curNotif
    $cmbRDP = Add-SettingRow "Remote Desktop:" "Enabled (Comodo Standard)" "Allows RDP access and securely configures Windows Firewall." "Disabled" "Blocks incoming Remote Desktop connections to this PC." 0 $curRDP
    $cmbStorage = Add-SettingRow "Storage Sense:" "Disabled" "Turns off automated Storage Sense background cleanup." "Enabled (Comodo Standard)" "Auto-deletes Recycle Bin (1 Day) and Downloads folder (14 Days)." 1 $curStorage
    $cmbPrivacy = Add-SettingRow "Privacy Tracking:" "Secure/Disabled (Comodo Standard)" "Disables diagnostic data, search history, speech targeting, & inking." "Windows Default (Enabled)" "Allows Microsoft to collect telemetry, inking, and diagnostic data." 0 $curPrivacy
    $cmbWinPerm = Add-SettingRow "Windows Permissions:" "Disabled (Comodo Standard)" "Turns off Ad ID, Activity History, App Launch tracking, and Tailored Experiences." "Windows Default (Enabled)" "Leaves standard Windows behavior tracking active." 0 $curWinPerm
    $cmbGaming = Add-SettingRow "Gaming Features:" "Disabled (Comodo Standard)" "Turns off Game Mode, Xbox Game Bar, Game DVR, and background recording." "Enabled" "Leaves Game Mode, Xbox Game Bar, and background recording on." 0 $curGaming
    $cmbWifi = Add-SettingRow "Wi-Fi Capabilities:" "Disabled (Comodo Standard)" "Stops and disables the WLAN AutoConfig service." "Enabled" "Leaves Wi-Fi services running normally." 0 $curWifi
    $cmbBT = Add-SettingRow "Bluetooth Radios:" "Disabled (Comodo Standard)" "Stops and disables the Bluetooth Support service." "Enabled" "Leaves Bluetooth services running normally." 0 $curBT

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply Settings"
    $btnApply.Size = New-Object System.Drawing.Size(250, 40)
    $btnApply.Location = New-Object System.Drawing.Point(125, ($script:yOffset + 10))
    $btnApply.BackColor = [System.Drawing.Color]::LightBlue
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $btnApply.Add_Click({
        $SetForm.Close()
        Write-Step "Applying custom Windows settings..."

        $idxTheme = $cmbTheme.SelectedIndex
        $themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Set-RegKey $themePath "AppsUseLightTheme" $idxTheme; Set-RegKey $themePath "SystemUsesLightTheme" $idxTheme

        $idxTaskbar = $cmbTaskbar.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" $idxTaskbar
        if ($idxTaskbar -eq 0) { Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 0; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0 }
        else { Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 1; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 1; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 2 }

        $idxNotif = $cmbNotif.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" $idxNotif
        $disableCenter = if ($idxNotif -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" $disableCenter

        $idxRDP = $cmbRDP.SelectedIndex
        Set-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" $idxRDP
        if ($idxRDP -eq 0) { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null } else { Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null }

        $idxStorage = $cmbStorage.SelectedIndex
        $storagePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        Set-RegKey $storagePath "01" $idxStorage
        if ($idxStorage -eq 1) { Set-RegKey $storagePath "08" 1; Set-RegKey $storagePath "256" 1; Set-RegKey $storagePath "32" 1; Set-RegKey $storagePath "512" 14 }
        else { Set-RegKey $storagePath "08" 0; Set-RegKey $storagePath "32" 0 }

        $idxPrivacy = $cmbPrivacy.SelectedIndex
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" $idxPrivacy
        $restrict = if ($idxPrivacy -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" $restrict; Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" $restrict

        $idxWinPerm = $cmbWinPerm.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" $idxWinPerm
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs" $idxWinPerm
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" $idxWinPerm
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" $idxWinPerm
        $optOut = if ($idxWinPerm -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" $optOut

        $idxGaming = $cmbGaming.SelectedIndex
        Set-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" $idxGaming; Set-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" $idxGaming; Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" $idxGaming; Set-RegKey "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" $idxGaming

        if ($cmbWifi.SelectedIndex -eq 0) { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 4; Stop-Service -Name "WlanSvc" -Force -ErrorAction SilentlyContinue }
        else { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 2; Start-Service -Name "WlanSvc" -ErrorAction SilentlyContinue }

        if ($cmbBT.SelectedIndex -eq 0) { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 4; Stop-Service -Name "bthserv" -Force -ErrorAction SilentlyContinue }
        else { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 3; Start-Service -Name "bthserv" -ErrorAction SilentlyContinue }

        Write-Success "Settings applied. Restarting Explorer..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

        # SAVE STATE & UPDATE GUI
        Save-StepState 1
        $script:btnStep1.Text = "âœ… 1. Configure Windows Settings"
    })

    $SetForm.Controls.Add($btnApply)
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $SetForm.ShowDialog() | Out-Null
}

function Run-Step2 {
    Write-Step "Step 2: Windows Updates"
    Write-Log "   -> Opening Settings and starting interactive scan..." "DarkGray"
    Write-Log "   -> Script paused. Waiting for IT to close the Settings app..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Start-Process "ms-settings:windowsupdate"
        Start-Sleep -Seconds 2
        Start-Process "usoclient" -ArgumentList "StartInteractiveScan" -WindowStyle Hidden -ErrorAction SilentlyContinue
        while (Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }

        Write-Success "Windows Settings closed. Step logged as complete."

        Save-StepState 2
        $script:btnStep2.Text = "âœ… 2. Run Windows Updates"
    } catch { Write-ErrorMsg "Failed to process Windows Updates: $_" }
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
    $lblInfo.Location = New-Object System.Drawing.Point(15, 15); $lblInfo.AutoSize = $true
    $lblInfo.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($lblInfo)

    $txtOutput = New-Object System.Windows.Forms.RichTextBox
    $txtOutput.Location = New-Object System.Drawing.Point(15, 40); $txtOutput.Size = New-Object System.Drawing.Size(600, 300)
    $txtOutput.Font = New-Object System.Drawing.Font("Consolas", 9); $txtOutput.ReadOnly = $true
    $txtOutput.BackColor = [System.Drawing.Color]::Black; $txtOutput.ForeColor = [System.Drawing.Color]::LimeGreen
    $txtOutput.Text = "Refreshing repositories and scanning for updates... Please wait.`n"
    $UpdateForm.Controls.Add($txtOutput)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = "Install All Updates"
    $btnUpdate.Location = New-Object System.Drawing.Point(15, 355); $btnUpdate.Size = New-Object System.Drawing.Size(180, 40)
    $btnUpdate.Enabled = $false; $btnUpdate.BackColor = [System.Drawing.Color]::LightGreen
    $btnUpdate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($btnUpdate)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close / Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(435, 355); $btnCancel.Size = New-Object System.Drawing.Size(180, 40)
    $btnCancel.Add_Click({ $UpdateForm.Close() })
    $UpdateForm.Controls.Add($btnCancel)

    $btnUpdate.Add_Click({
        $btnUpdate.Enabled = $false; $btnCancel.Enabled = $false
        $txtOutput.Text += "`n`nStarting silent background installation... Please wait."
        $UpdateForm.Update()

        Write-Step "Applying software updates via Winget..."
        $wingetArgs = @("upgrade", "--all", "--include-unknown", "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
        $wingetProc = Start-Process winget -ArgumentList $wingetArgs -Wait -NoNewWindow -PassThru

        if ($wingetProc.ExitCode -eq 0) { Write-Success "Winget successfully updated all software." }
        else { Write-WarningMsg "Winget completed with exit code: $($wingetProc.ExitCode). Some apps may require a reboot." }

        $UpdateForm.Close()

        Save-StepState 3
        $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)"
    })

    $UpdateForm.Add_Shown({
        $UpdateForm.Update()
        try {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                $txtOutput.Text = "Error: Winget is not installed or recognized on this PC."
            } else {
                Start-Process winget -ArgumentList "source update" -Wait -NoNewWindow | Out-Null
                $wingetOut = winget upgrade --accept-source-agreements | Out-String
                $cleanOut = $wingetOut -replace "\x1B\[[0-9;]*[a-zA-Z]", ""

                if ($cleanOut -match "No installed package found matching input criteria" -or $cleanOut -match "No available upgrades") {
                    $txtOutput.Text = "Scan Complete: All installed software is already up to date!"

                    # Mark step as completed if already updated
                    Save-StepState 3
                    $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)"
                } else {
                    $txtOutput.Text = $cleanOut
                    $btnUpdate.Enabled = $true
                }
            }
        } catch { $txtOutput.Text = "Failed to scan via Winget. Error: $_" }
    })

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $UpdateForm.ShowDialog() | Out-Null
}

function Run-Step4 {
    Write-Step "Step 4: Launching CCleaner"
    Write-Log "   -> Script paused. Waiting for IT to finish and close CCleaner..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $ccleanerExe = "C:\ITDepartment\CCleaner\CCleaner64.exe"
        if (Test-Path $ccleanerExe) {
            Start-Process $ccleanerExe -Wait
            Write-Success "CCleaner closed. Step logged as complete."

            Save-StepState 4
            $script:btnStep4.Text = "âœ… 4. Launch CCleaner"
        } else { Write-WarningMsg "CCleaner not found at $ccleanerExe." }
    } catch { Write-ErrorMsg "Failed to launch CCleaner: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step5 {
    Write-Step "Step 5: Launching Revo Uninstaller"
    Write-Log "   -> Script paused. Waiting for IT to finish and close Revo..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $revoExe = "C:\ITDepartment\Revo Uninstaller Pro\RevoUPPort.exe"
        if (Test-Path $revoExe) {
            Start-Process $revoExe -Wait
            Write-Success "Revo Uninstaller closed. Step logged as complete."

            Save-StepState 5
            $script:btnStep5.Text = "âœ… 5. Launch Revo Uninstaller"
        } else { Write-WarningMsg "Revo not found at $revoExe." }
    } catch { Write-ErrorMsg "Failed to launch Revo: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step6 {
    Write-Step "Step 6: Clinic PC Optimizations"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        powercfg.exe /change standby-timeout-ac 0
        powercfg.exe /change monitor-timeout-ac 0
        Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" -Name "DisableAutoplay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -ErrorAction SilentlyContinue
        Write-Success "PC Optimized for performance and stability."

        Save-StepState 6
        $script:btnStep6.Text = "âœ… 6. Apply Clinic Optimizations"
    } catch { Write-ErrorMsg "Error optimizing PC: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step7 {
    Write-Step "Step 7: Purging Temp, Cache, and Print Spooler"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-Log "   -> Resetting Print Spooler cache..." "DarkGray"
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path "C:\Windows\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue

        Write-Log "   -> Purging system and user temp folders..." "DarkGray"
        $junkPaths = @(
            $env:TEMP, "C:\Windows\Temp", "C:\Windows\Prefetch",
            "C:\Windows\SoftwareDistribution\Download", "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
        )
        foreach ($path in $junkPaths) {
            if (Test-Path $path) { Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }

        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Success "All temporary data and stuck print queues destroyed."

        $script:btnStep7.Text = "âœ… 7. Purge Temp & Spooler"

        $result = [System.Windows.Forms.MessageBox]::Show(
            "All optimization steps are completely finished! Would you like to restart the PC now to finalize everything?",
            "Final Restart",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($result -eq "Yes") {
            # Cleanup the Step Check folder permanently ONLY if they say yes
            if (Test-Path $StateDir) { Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
            Schedule-SelfDeleteAndRestart
        }

    } catch { Write-ErrorMsg "Error during final cleanup: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-AllSteps {
    $btnRunAll.Enabled = $false
    # Only run steps that don't have a checkmark yet
    if ($script:btnStep1.Text -notmatch "âœ…") { Run-Step1 }
    if ($script:btnStep2.Text -notmatch "âœ…") { Run-Step2 }
    if ($script:btnStep3.Text -notmatch "âœ…") { Run-Step3 }
    if ($script:btnStep4.Text -notmatch "âœ…") { Run-Step4 }
    if ($script:btnStep5.Text -notmatch "âœ…") { Run-Step5 }
    if ($script:btnStep6.Text -notmatch "âœ…") { Run-Step6 }
    if ($script:btnStep7.Text -notmatch "âœ…") { Run-Step7 }
    Write-Log "`n===============================" "DarkCyan" -Bold
    Write-Log " ALL PROCESSES COMPLETE!" "Green" -Bold
    Write-Log "===============================" "DarkCyan" -Bold
    $btnRunAll.Enabled = $true
}

# ==========================================
# UI CONSTRUCTION
# ==========================================
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "Clinic PC Maintenance Utility"
$MainForm.Size = New-Object System.Drawing.Size(750, 520) # Increased height to accommodate restart button
$MainForm.StartPosition = "CenterScreen"
$MainForm.FormBorderStyle = "FixedDialog"
$MainForm.MaximizeBox = $false

$TitleFont = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$BtnFont = New-Object System.Drawing.Font("Segoe UI", 9)
$LogFont = New-Object System.Drawing.Font("Consolas", 9)

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

function Add-GuiButton([string]$Text, [scriptblock]$Action) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text; $btn.Size = New-Object System.Drawing.Size(240, 35)
    $btn.Font = $BtnFont; $btn.Margin = New-Object System.Windows.Forms.Padding(0,0,0,5)
    $btn.Add_Click($Action)
    $Panel.Controls.Add($btn)
    return $btn
}

$btnRunAll = Add-GuiButton "â–¶ RUN ALL STEPS" { Run-AllSteps }
$btnRunAll.BackColor = [System.Drawing.Color]::LightGreen
$btnRunAll.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$script:btnStep1 = Add-GuiButton "1. Configure Windows Settings" { Run-Step1 }
$script:btnStep2 = Add-GuiButton "2. Run Windows Updates" { Run-Step2 }
$script:btnStep3 = Add-GuiButton "3. Update Apps (Winget)" { Run-Step3 }
$script:btnStep4 = Add-GuiButton "4. Launch CCleaner" { Run-Step4 }
$script:btnStep5 = Add-GuiButton "5. Launch Revo Uninstaller" { Run-Step5 }
$script:btnStep6 = Add-GuiButton "6. Apply Clinic Optimizations" { Run-Step6 }
$script:btnStep7 = Add-GuiButton "7. Purge Temp & Spooler" { Run-Step7 }

# Add restart button at the bottom
$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "ðŸ”„ Restart PC"
$btnRestart.Size = New-Object System.Drawing.Size(240, 35)
$btnRestart.Location = New-Object System.Drawing.Point(15, 440) # Below the panel
$btnRestart.Font = $BtnFont
$btnRestart.BackColor = [System.Drawing.Color]::LightPink
$btnRestart.Add_Click({ Restart-Computer-Manually })
$MainForm.Controls.Add($btnRestart)

$RichTextBox = New-Object System.Windows.Forms.RichTextBox
$RichTextBox.Location = New-Object System.Drawing.Point(280, 50)
$RichTextBox.Size = New-Object System.Drawing.Size(435, 370)
$RichTextBox.Font = $LogFont
$RichTextBox.ReadOnly = $true
$RichTextBox.BackColor = [System.Drawing.Color]::White
$RichTextBox.ScrollBars = "Vertical"
$MainForm.Controls.Add($RichTextBox)

Write-Log "Welcome to the Clinic PC Maintenance Utility." "DarkCyan" -Bold
Write-Log "Click an individual step or 'RUN ALL STEPS'." "Black"
Write-Log "Use the restart button below when you need to reboot the system (script will delete itself after restart)." "DarkGray"
Write-Log "Note: The script will pause while external tools are open.`n" "DarkGray"

# --- CHECK FOR PREVIOUS PROGRESS UPON LAUNCH ---
$completedSteps = Get-StepState
if ($completedSteps.Count -gt 0) {
    Write-Log "   -> Resuming session. Marking completed steps..." "DarkOrange" -Bold
    if ($completedSteps -contains 1) { $script:btnStep1.Text = "âœ… 1. Configure Windows Settings" }
    if ($completedSteps -contains 2) { $script:btnStep2.Text = "âœ… 2. Run Windows Updates" }
    if ($completedSteps -contains 3) { $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)" }
    if ($completedSteps -contains 4) { $script:btnStep4.Text = "âœ… 4. Launch CCleaner" }
    if ($completedSteps -contains 5) { $script:btnStep5.Text = "âœ… 5. Launch Revo Uninstaller" }
    if ($completedSteps -contains 6) { $script:btnStep6.Text = "âœ… 6. Apply Clinic Optimizations" }
    if ($completedSteps -contains 7) { $script:btnStep7.Text = "âœ… 7. Purge Temp & Spooler" }
}

# Render the GUI
$MainForm.ShowDialog() | Out-Null# =========================================================================
# ClinicOptimizer-GUI.ps1
# Interactive GUI Deployment Script with Auto-Resume State Tracking
# =========================================================================

# --- Pre-flight Check: Ensure Admin Rights ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[-] This script requires Administrator privileges. Please run PowerShell as Admin." -ForegroundColor Red
    exit
}

# --- Unlock Registry "God Mode" (SeTakeOwnershipPrivilege) ---
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
[PrivilegeManager]::EnablePrivilege("SeTakeOwnershipPrivilege")
[PrivilegeManager]::EnablePrivilege("SeRestorePrivilege")

# --- Load Windows Forms Framework ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- GUI Logging & Helper Functions ---
function Write-Log ([string]$Message, [string]$Color = "Black", [switch]$Bold) {
    if ($RichTextBox.InvokeRequired) {
        $RichTextBox.Invoke([action]{ Write-Log -Message $Message -Color $Color -Bold:$Bold })
        return
    }
    $RichTextBox.SelectionStart = $RichTextBox.TextLength
    $RichTextBox.SelectionLength = 0
    $RichTextBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
    if ($Bold) { $RichTextBox.SelectionFont = New-Object System.Drawing.Font($RichTextBox.Font, [System.Drawing.FontStyle]::Bold) }
    else { $RichTextBox.SelectionFont = New-Object System.Drawing.Font($RichTextBox.Font, [System.Drawing.FontStyle]::Regular) }
    $RichTextBox.AppendText("$Message`n")
    $RichTextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-Step ([string]$Message) { Write-Log "`n[*] $Message..." "Blue" -Bold }
function Write-Success ([string]$Message) { Write-Log "[+] $Message" "Green" }
function Write-ErrorMsg ([string]$Message) { Write-Log "[-] $Message" "Red" }
function Write-WarningMsg ([string]$Message) { Write-Log "[!] $Message" "DarkOrange" }

function Set-RegKey {
    param ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        try {
            # Bypass TrustedInstaller to force protected keys
            $acl = Get-Acl $Path
            $adminGroup = New-Object System.Security.Principal.NTAccount("Administrators")
            $acl.SetOwner($adminGroup)
            $accessRule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $acl.SetAccessRule($accessRule)
            Set-Acl -Path $Path -AclObject $acl
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Get-RegKey {
    param ([string]$Path, [string]$Name, $Default)
    try {
        $val = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ($null -eq $val) { return $Default }
        return $val
    } catch { return $Default }
}

# --- SELF-DELETION AFTER RESTART ---
function Schedule-SelfDeleteAndRestart {
    $scriptPath = $MyInvocation.MyCommand.Path
    $batPath = "$env:TEMP\delete_self.bat"

    # Create batch file that waits for script to exit then deletes it
    $batContent = "@echo off
:wait
timeout /t 2 >nul
if exist `"$scriptPath`" (
    del `"$scriptPath`"
) else (
    goto :eof
)
goto :wait"

    Set-Content -Path $batPath -Value $batContent -Encoding ASCII -Force
    Start-Process -FilePath $batPath -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null

    # Restart the computer
    Write-WarningMsg "Scheduling self-deletion and restarting PC..."
    Start-Sleep -Seconds 2
    Restart-Computer -Force
}

# --- INDIVIDUAL STEP TRACKING MECHANISM ---
$StateDir = "C:\ITDepartment\Step Check"
$StateFile = Join-Path $StateDir "progress.txt"

function Save-StepState ([int]$StepNum) {
    if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }

    $existing = @()
    if (Test-Path $StateFile) { $existing = Get-Content $StateFile -ErrorAction SilentlyContinue }
    if ($existing -notcontains $StepNum) { Add-Content -Path $StateFile -Value $StepNum -Force -ErrorAction SilentlyContinue }
}

function Get-StepState {
    if (Test-Path $StateFile) {
        return @(Get-Content $StateFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '\d' } | ForEach-Object { [int]$_ })
    }
    return @function for the user to manually restart when needed
function Restart-Computer-Manually {
    Schedule-SelfDeleteAndRestart
}

# ==========================================
# SCRIPT MODULES (The 7 Steps)
# ==========================================

function Run-Step1 {
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $SetForm = New-Object System.Windows.Forms.Form
    $SetForm.Text = "Configure Windows Settings"
    $SetForm.Size = New-Object System.Drawing.Size(540, 1000) # Made tall enough to fit the new Permissions row
    $SetForm.StartPosition = "CenterParent"
    $SetForm.FormBorderStyle = "FixedDialog"
    $SetForm.MaximizeBox = $false

    $script:yOffset = 20

    function Add-SettingRow ([string]$LabelText, [string]$Opt0_Text, [string]$Opt0_Desc, [string]$Opt1_Text, [string]$Opt1_Desc, [int]$StandardIndex, [int]$CurrentIndex) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText; $lbl.Location = New-Object System.Drawing.Point(20, $script:yOffset); $lbl.Size = New-Object System.Drawing.Size(160, 25)
        $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $SetForm.Controls.Add($lbl)

        $cmb = New-Object System.Windows.Forms.ComboBox
        $cmb.DropDownStyle = "DropDownList"
        $cmb.Items.Add($Opt0_Text) | Out-Null
        $cmb.Items.Add($Opt1_Text) | Out-Null
        $cmb.Location = New-Object System.Drawing.Point(190, ($script:yOffset - 3)); $cmb.Size = New-Object System.Drawing.Size(280, 25)
        $SetForm.Controls.Add($cmb)

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Location = New-Object System.Drawing.Point(190, ($script:yOffset + 24))
        $lblDesc.Size = New-Object System.Drawing.Size(290, 40)
        $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
        $SetForm.Controls.Add($lblDesc)

        $cmb.Add_SelectedIndexChanged({
            if ($this.SelectedIndex -eq 0) { $lblDesc.Text = $Opt0_Desc }
            else { $lblDesc.Text = $Opt1_Desc }

            if ($this.SelectedIndex -eq $StandardIndex) { $lblDesc.ForeColor = [System.Drawing.Color]::Blue }
            else { $lblDesc.ForeColor = [System.Drawing.Color]::Red }
        }.GetNewClosure())

        $cmb.SelectedIndex = $CurrentIndex
        $script:yOffset += 85
        return $cmb
    }

    # --- READ CURRENT SYSTEM SETTINGS ---
    $curTheme = Get-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" 1
    if ($curTheme -ne 0) { $curTheme = 1 }

    $curTaskbar = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" 0
    if ($curTaskbar -ne 0) { $curTaskbar = 1 }

    $curNotif = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1
    if ($curNotif -ne 0) { $curNotif = 1 }

    $curRDP = Get-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 1
    if ($curRDP -ne 0) { $curRDP = 1 }

    $curStorage = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 0
    if ($curStorage -ne 0) { $curStorage = 1 }

    $curPrivacyVal = Get-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 1
    $curPrivacy = if ($curPrivacyVal -eq 0) { 0 } else { 1 }

    $curWinPermVal = Get-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1
    $curWinPerm = if ($curWinPermVal -eq 0) { 0 } else { 1 }

    $curGaming = Get-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 1
    if ($curGaming -ne 0) { $curGaming = 1 }

    $curWifiVal = Get-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 2
    $curWifi = if ($curWifiVal -eq 4) { 0 } else { 1 }

    $curBTVal = Get-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 3
    $curBT = if ($curBTVal -eq 4) { 0 } else { 1 }

    # --- BUILD THE DYNAMIC MENUS ---
    $cmbTheme = Add-SettingRow "System Theme:" "Dark Mode" "Sets Windows apps and system background to Dark Mode." "Light Mode (Comodo Standard)" "Sets standard Windows app and system background colors." 1 $curTheme
    $cmbTaskbar = Add-SettingRow "Taskbar Alignment:" "Left (Comodo Standard)" "Aligns taskbar left and hides Widgets, Chat, and Search box." "Center" "Aligns taskbar to the center and leaves Widgets/Search enabled." 0 $curTaskbar
    $cmbNotif = Add-SettingRow "Notifications:" "Disabled (Comodo Standard)" "Turns off notification center tracking and toast pop-ups." "Enabled" "Leaves Windows notifications and toast pop-ups turned on." 0 $curNotif
    $cmbRDP = Add-SettingRow "Remote Desktop:" "Enabled (Comodo Standard)" "Allows RDP access and securely configures Windows Firewall." "Disabled" "Blocks incoming Remote Desktop connections to this PC." 0 $curRDP
    $cmbStorage = Add-SettingRow "Storage Sense:" "Disabled" "Turns off automated Storage Sense background cleanup." "Enabled (Comodo Standard)" "Auto-deletes Recycle Bin (1 Day) and Downloads folder (14 Days)." 1 $curStorage
    $cmbPrivacy = Add-SettingRow "Privacy Tracking:" "Secure/Disabled (Comodo Standard)" "Disables diagnostic data, search history, speech targeting, & inking." "Windows Default (Enabled)" "Allows Microsoft to collect telemetry, inking, and diagnostic data." 0 $curPrivacy
    $cmbWinPerm = Add-SettingRow "Windows Permissions:" "Disabled (Comodo Standard)" "Turns off Ad ID, Activity History, App Launch tracking, and Tailored Experiences." "Windows Default (Enabled)" "Leaves standard Windows behavior tracking active." 0 $curWinPerm
    $cmbGaming = Add-SettingRow "Gaming Features:" "Disabled (Comodo Standard)" "Turns off Game Mode, Xbox Game Bar, Game DVR, and background recording." "Enabled" "Leaves Game Mode, Xbox Game Bar, and background recording on." 0 $curGaming
    $cmbWifi = Add-SettingRow "Wi-Fi Capabilities:" "Disabled (Comodo Standard)" "Stops and disables the WLAN AutoConfig service." "Enabled" "Leaves Wi-Fi services running normally." 0 $curWifi
    $cmbBT = Add-SettingRow "Bluetooth Radios:" "Disabled (Comodo Standard)" "Stops and disables the Bluetooth Support service." "Enabled" "Leaves Bluetooth services running normally." 0 $curBT

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply Settings"
    $btnApply.Size = New-Object System.Drawing.Size(250, 40)
    $btnApply.Location = New-Object System.Drawing.Point(125, ($script:yOffset + 10))
    $btnApply.BackColor = [System.Drawing.Color]::LightBlue
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $btnApply.Add_Click({
        $SetForm.Close()
        Write-Step "Applying custom Windows settings..."

        $idxTheme = $cmbTheme.SelectedIndex
        $themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Set-RegKey $themePath "AppsUseLightTheme" $idxTheme; Set-RegKey $themePath "SystemUsesLightTheme" $idxTheme

        $idxTaskbar = $cmbTaskbar.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" $idxTaskbar
        if ($idxTaskbar -eq 0) { Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 0; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0 }
        else { Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 1; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" 1; Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 2 }

        $idxNotif = $cmbNotif.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" $idxNotif
        $disableCenter = if ($idxNotif -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" $disableCenter

        $idxRDP = $cmbRDP.SelectedIndex
        Set-RegKey "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" $idxRDP
        if ($idxRDP -eq 0) { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null } else { Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null }

        $idxStorage = $cmbStorage.SelectedIndex
        $storagePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        Set-RegKey $storagePath "01" $idxStorage
        if ($idxStorage -eq 1) { Set-RegKey $storagePath "08" 1; Set-RegKey $storagePath "256" 1; Set-RegKey $storagePath "32" 1; Set-RegKey $storagePath "512" 14 }
        else { Set-RegKey $storagePath "08" 0; Set-RegKey $storagePath "32" 0 }

        $idxPrivacy = $cmbPrivacy.SelectedIndex
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" $idxPrivacy
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDeviceSearchHistoryEnabled" $idxPrivacy
        $restrict = if ($idxPrivacy -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" $restrict; Set-RegKey "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" $restrict

        $idxWinPerm = $cmbWinPerm.SelectedIndex
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" $idxWinPerm
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs" $idxWinPerm
        Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" $idxWinPerm
        Set-RegKey "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" $idxWinPerm
        $optOut = if ($idxWinPerm -eq 0) { 1 } else { 0 }
        Set-RegKey "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" $optOut

        $idxGaming = $cmbGaming.SelectedIndex
        Set-RegKey "HKCU:\System\GameConfigStore" "GameDVR_Enabled" $idxGaming; Set-RegKey "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" $idxGaming; Set-RegKey "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" $idxGaming; Set-RegKey "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" $idxGaming

        if ($cmbWifi.SelectedIndex -eq 0) { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 4; Stop-Service -Name "WlanSvc" -Force -ErrorAction SilentlyContinue }
        else { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\WlanSvc" "Start" 2; Start-Service -Name "WlanSvc" -ErrorAction SilentlyContinue }

        if ($cmbBT.SelectedIndex -eq 0) { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 4; Stop-Service -Name "bthserv" -Force -ErrorAction SilentlyContinue }
        else { Set-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\bthserv" "Start" 3; Start-Service -Name "bthserv" -ErrorAction SilentlyContinue }

        Write-Success "Settings applied. Restarting Explorer..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

        # SAVE STATE & UPDATE GUI
        Save-StepState 1
        $script:btnStep1.Text = "âœ… 1. Configure Windows Settings"
    })

    $SetForm.Controls.Add($btnApply)
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $SetForm.ShowDialog() | Out-Null
}

function Run-Step2 {
    Write-Step "Step 2: Windows Updates"
    Write-Log "   -> Opening Settings and starting interactive scan..." "DarkGray"
    Write-Log "   -> Script paused. Waiting for IT to close the Settings app..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Start-Process "ms-settings:windowsupdate"
        Start-Sleep -Seconds 2
        Start-Process "usoclient" -ArgumentList "StartInteractiveScan" -WindowStyle Hidden -ErrorAction SilentlyContinue
        while (Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }

        Write-Success "Windows Settings closed. Step logged as complete."

        Save-StepState 2
        $script:btnStep2.Text = "âœ… 2. Run Windows Updates"
    } catch { Write-ErrorMsg "Failed to process Windows Updates: $_" }
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
    $lblInfo.Location = New-Object System.Drawing.Point(15, 15); $lblInfo.AutoSize = $true
    $lblInfo.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($lblInfo)

    $txtOutput = New-Object System.Windows.Forms.RichTextBox
    $txtOutput.Location = New-Object System.Drawing.Point(15, 40); $txtOutput.Size = New-Object System.Drawing.Size(600, 300)
    $txtOutput.Font = New-Object System.Drawing.Font("Consolas", 9); $txtOutput.ReadOnly = $true
    $txtOutput.BackColor = [System.Drawing.Color]::Black; $txtOutput.ForeColor = [System.Drawing.Color]::LimeGreen
    $txtOutput.Text = "Refreshing repositories and scanning for updates... Please wait.`n"
    $UpdateForm.Controls.Add($txtOutput)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = "Install All Updates"
    $btnUpdate.Location = New-Object System.Drawing.Point(15, 355); $btnUpdate.Size = New-Object System.Drawing.Size(180, 40)
    $btnUpdate.Enabled = $false; $btnUpdate.BackColor = [System.Drawing.Color]::LightGreen
    $btnUpdate.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $UpdateForm.Controls.Add($btnUpdate)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Close / Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(435, 355); $btnCancel.Size = New-Object System.Drawing.Size(180, 40)
    $btnCancel.Add_Click({ $UpdateForm.Close() })
    $UpdateForm.Controls.Add($btnCancel)

    $btnUpdate.Add_Click({
        $btnUpdate.Enabled = $false; $btnCancel.Enabled = $false
        $txtOutput.Text += "`n`nStarting silent background installation... Please wait."
        $UpdateForm.Update()

        Write-Step "Applying software updates via Winget..."
        $wingetArgs = @("upgrade", "--all", "--include-unknown", "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
        $wingetProc = Start-Process winget -ArgumentList $wingetArgs -Wait -NoNewWindow -PassThru

        if ($wingetProc.ExitCode -eq 0) { Write-Success "Winget successfully updated all software." }
        else { Write-WarningMsg "Winget completed with exit code: $($wingetProc.ExitCode). Some apps may require a reboot." }

        $UpdateForm.Close()

        Save-StepState 3
        $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)"
    })

    $UpdateForm.Add_Shown({
        $UpdateForm.Update()
        try {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                $txtOutput.Text = "Error: Winget is not installed or recognized on this PC."
            } else {
                Start-Process winget -ArgumentList "source update" -Wait -NoNewWindow | Out-Null
                $wingetOut = winget upgrade --accept-source-agreements | Out-String
                $cleanOut = $wingetOut -replace "\x1B\[[0-9;]*[a-zA-Z]", ""

                if ($cleanOut -match "No installed package found matching input criteria" -or $cleanOut -match "No available upgrades") {
                    $txtOutput.Text = "Scan Complete: All installed software is already up to date!"

                    # Mark step as completed if already updated
                    Save-StepState 3
                    $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)"
                } else {
                    $txtOutput.Text = $cleanOut
                    $btnUpdate.Enabled = $true
                }
            }
        } catch { $txtOutput.Text = "Failed to scan via Winget. Error: $_" }
    })

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    $UpdateForm.ShowDialog() | Out-Null
}

function Run-Step4 {
    Write-Step "Step 4: Launching CCleaner"
    Write-Log "   -> Script paused. Waiting for IT to finish and close CCleaner..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $ccleanerExe = "C:\ITDepartment\CCleaner\CCleaner64.exe"
        if (Test-Path $ccleanerExe) {
            Start-Process $ccleanerExe -Wait
            Write-Success "CCleaner closed. Step logged as complete."

            Save-StepState 4
            $script:btnStep4.Text = "âœ… 4. Launch CCleaner"
        } else { Write-WarningMsg "CCleaner not found at $ccleanerExe." }
    } catch { Write-ErrorMsg "Failed to launch CCleaner: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step5 {
    Write-Step "Step 5: Launching Revo Uninstaller"
    Write-Log "   -> Script paused. Waiting for IT to finish and close Revo..." "DarkGray"

    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $revoExe = "C:\ITDepartment\Revo Uninstaller Pro\RevoUPPort.exe"
        if (Test-Path $revoExe) {
            Start-Process $revoExe -Wait
            Write-Success "Revo Uninstaller closed. Step logged as complete."

            Save-StepState 5
            $script:btnStep5.Text = "âœ… 5. Launch Revo Uninstaller"
        } else { Write-WarningMsg "Revo not found at $revoExe." }
    } catch { Write-ErrorMsg "Failed to launch Revo: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step6 {
    Write-Step "Step 6: Clinic PC Optimizations"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        powercfg.exe /change standby-timeout-ac 0
        powercfg.exe /change monitor-timeout-ac 0
        Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" -Name "DisableAutoplay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -ErrorAction SilentlyContinue
        Write-Success "PC Optimized for performance and stability."

        Save-StepState 6
        $script:btnStep6.Text = "âœ… 6. Apply Clinic Optimizations"
    } catch { Write-ErrorMsg "Error optimizing PC: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-Step7 {
    Write-Step "Step 7: Purging Temp, Cache, and Print Spooler"
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Write-Log "   -> Resetting Print Spooler cache..." "DarkGray"
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path "C:\Windows\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue

        Write-Log "   -> Purging system and user temp folders..." "DarkGray"
        $junkPaths = @(
            $env:TEMP, "C:\Windows\Temp", "C:\Windows\Prefetch",
            "C:\Windows\SoftwareDistribution\Download", "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
        )
        foreach ($path in $junkPaths) {
            if (Test-Path $path) { Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }

        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Success "All temporary data and stuck print queues destroyed."

        $script:btnStep7.Text = "âœ… 7. Purge Temp & Spooler"

        $result = [System.Windows.Forms.MessageBox]::Show(
            "All optimization steps are completely finished! Would you like to restart the PC now to finalize everything?",
            "Final Restart",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($result -eq "Yes") {
            # Cleanup the Step Check folder permanently ONLY if they say yes
            if (Test-Path $StateDir) { Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
            Schedule-SelfDeleteAndRestart
        }

    } catch { Write-ErrorMsg "Error during final cleanup: $_" }
    $MainForm.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Run-AllSteps {
    $btnRunAll.Enabled = $false
    # Only run steps that don't have a checkmark yet
    if ($script:btnStep1.Text -notmatch "âœ…") { Run-Step1 }
    if ($script:btnStep2.Text -notmatch "âœ…") { Run-Step2 }
    if ($script:btnStep3.Text -notmatch "âœ…") { Run-Step3 }
    if ($script:btnStep4.Text -notmatch "âœ…") { Run-Step4 }
    if ($script:btnStep5.Text -notmatch "âœ…") { Run-Step5 }
    if ($script:btnStep6.Text -notmatch "âœ…") { Run-Step6 }
    if ($script:btnStep7.Text -notmatch "âœ…") { Run-Step7 }
    Write-Log "`n===============================" "DarkCyan" -Bold
    Write-Log " ALL PROCESSES COMPLETE!" "Green" -Bold
    Write-Log "===============================" "DarkCyan" -Bold
    $btnRunAll.Enabled = $true
}

# ==========================================
# UI CONSTRUCTION
# ==========================================
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "Clinic PC Maintenance Utility"
$MainForm.Size = New-Object System.Drawing.Size(750, 520) # Increased height to accommodate restart button
$MainForm.StartPosition = "CenterScreen"
$MainForm.FormBorderStyle = "FixedDialog"
$MainForm.MaximizeBox = $false

$TitleFont = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$BtnFont = New-Object System.Drawing.Font("Segoe UI", 9)
$LogFont = New-Object System.Drawing.Font("Consolas", 9)

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

function Add-GuiButton([string]$Text, [scriptblock]$Action) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text; $btn.Size = New-Object System.Drawing.Size(240, 35)
    $btn.Font = $BtnFont; $btn.Margin = New-Object System.Windows.Forms.Padding(0,0,0,5)
    $btn.Add_Click($Action)
    $Panel.Controls.Add($btn)
    return $btn
}

$btnRunAll = Add-GuiButton "â–¶ RUN ALL STEPS" { Run-AllSteps }
$btnRunAll.BackColor = [System.Drawing.Color]::LightGreen
$btnRunAll.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$script:btnStep1 = Add-GuiButton "1. Configure Windows Settings" { Run-Step1 }
$script:btnStep2 = Add-GuiButton "2. Run Windows Updates" { Run-Step2 }
$script:btnStep3 = Add-GuiButton "3. Update Apps (Winget)" { Run-Step3 }
$script:btnStep4 = Add-GuiButton "4. Launch CCleaner" { Run-Step4 }
$script:btnStep5 = Add-GuiButton "5. Launch Revo Uninstaller" { Run-Step5 }
$script:btnStep6 = Add-GuiButton "6. Apply Clinic Optimizations" { Run-Step6 }
$script:btnStep7 = Add-GuiButton "7. Purge Temp & Spooler" { Run-Step7 }

# Add restart button at the bottom
$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "ðŸ”„ Restart PC"
$btnRestart.Size = New-Object System.Drawing.Size(240, 35)
$btnRestart.Location = New-Object System.Drawing.Point(15, 440) # Below the panel
$btnRestart.Font = $BtnFont
$btnRestart.BackColor = [System.Drawing.Color]::LightPink
$btnRestart.Add_Click({ Restart-Computer-Manually })
$MainForm.Controls.Add($btnRestart)

$RichTextBox = New-Object System.Windows.Forms.RichTextBox
$RichTextBox.Location = New-Object System.Drawing.Point(280, 50)
$RichTextBox.Size = New-Object System.Drawing.Size(435, 370)
$RichTextBox.Font = $LogFont
$RichTextBox.ReadOnly = $true
$RichTextBox.BackColor = [System.Drawing.Color]::White
$RichTextBox.ScrollBars = "Vertical"
$MainForm.Controls.Add($RichTextBox)

Write-Log "Welcome to the Clinic PC Maintenance Utility." "DarkCyan" -Bold
Write-Log "Click an individual step or 'RUN ALL STEPS'." "Black"
Write-Log "Use the restart button below when you need to reboot the system (script will delete itself after restart)." "DarkGray"
Write-Log "Note: The script will pause while external tools are open.`n" "DarkGray"

# --- CHECK FOR PREVIOUS PROGRESS UPON LAUNCH ---
$completedSteps = Get-StepState
if ($completedSteps.Count -gt 0) {
    Write-Log "   -> Resuming session. Marking completed steps..." "DarkOrange" -Bold
    if ($completedSteps -contains 1) { $script:btnStep1.Text = "âœ… 1. Configure Windows Settings" }
    if ($completedSteps -contains 2) { $script:btnStep2.Text = "âœ… 2. Run Windows Updates" }
    if ($completedSteps -contains 3) { $script:btnStep3.Text = "âœ… 3. Update Apps (Winget)" }
    if ($completedSteps -contains 4) { $script:btnStep4.Text = "âœ… 4. Launch CCleaner" }
    if ($completedSteps -contains 5) { $script:btnStep5.Text = "âœ… 5. Launch Revo Uninstaller" }
    if ($completedSteps -contains 6) { $script:btnStep6.Text = "âœ… 6. Apply Clinic Optimizations" }
    if ($completedSteps -contains 7) { $script:btnStep7.Text = "âœ… 7. Purge Temp & Spooler" }
}

# Render the GUI
$MainForm.ShowDialog() | Out-Null
