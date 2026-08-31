<#
  .SYNOPSIS
      Clinic PC Maintenance Utility – Optimized Interactive Version
  .DESCRIPTION
      Provides a GUI for routine Windows maintenance tasks with safety checks,
      detailed logging, and manual control (no forced restarts).
  .NOTES
      Author: Optimized by assistant (based on user script)
      Requires: PowerShell 5.1+, Administrator rights
  #>

  #region ====================== Configuration ======================
  $SafeMode = $true   # Set $false to enable risky actions (use with caution)
  $LogFile  = Join-Path $env:ProgramData 'ClinicMaintenance\Maintenance.log'
  $StateDir = Join-Path $env:ProgramData 'ClinicMaintenance'
  $StateFile= Join-Path $StateDir 'progress.json'

  # Ensure folders exist
  if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
  #endregion ====================== Configuration ======================

  #region ====================== Helper Functions ======================
  function Write-Log {
      param(
          [Parameter(Mandatory)][string]$Message,
          [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info',
          [switch]$Timestamp
      )
      $time = if ($Timestamp) { "[{0:yyyy-MM-dd HH:mm:ss}] " -f (Get-Date) } else { '' }
      $color = switch ($Level) {
          'Info'    { [System.Drawing.Color]::Black }
          'Success' { [System.Drawing.Color]::Green }
          'Warning' { [System.Drawing.Color]::DarkOrange }
          'Error'   { [System.Drawing.Color]::Red }
      }
      $entry = "{0}{1}`n" -f $time,$Message
      if ($Host.UI -is [System.Management.Automation.Host.InternalHost]) {
          # GUI rich text box (will be filled later)
          $script:RichTextBox.AppendText($entry)
          $script:RichTextBox.ScrollToCaret()
      }
      # Also write to file
      Add-Content -Path $LogFile -Value $entry -Encoding UTF8
  }
  function Write-Info    { param([string]$m) Write-Log -Message $m -Level Info    -Timestamp }
  function Write-Success { param([string]$m) Write-Log -Message $m -Level Success -Timestamp }
  function Write-Warning { param([string]$m) Write-Log -Message $m -Level Warning -Timestamp }
  function Write-Error   { param([string]$m) Write-Log -Message $m -Level Error   -Timestamp }

  function Set-RegSafe {
      param(
          [string]$Path,
          [string]$Name,
          $Value,
          [ValidateSet('String','ExpandString','DWord','QWord','MultiString','Binary')][string]$Type = 'DWord'
      )
      try {
          if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
          Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
          Write-Success "Set HKLM/HKCU '$Path\$Name' = $Value"
      } catch {
          Write-Error "Failed to set '$Path\$Name': $_"
      }
  }
  function Get-RegSafe {
      param([string]$Path, [string]$Name, [object]$Default = $null)
      try {
          return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
      } catch { return $Default }
  }
  function Save-Progress {
      param([int]$Step)
      $data = @{}
      if (Test-Path $StateFile) { $data = Get-Content $StateFile -Raw | ConvertFrom-Json }
      if (-not $data.ContainsKey('Steps')) { $data.Steps = @() }
      if (-not ($data.Steps -contains $Step)) { $data.Steps += $Step }
      $data | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
  }
  function Get-Progress {
      if (Test-Path $StateFile) {
          try { return (Get-Content $StateFile -Raw | ConvertFrom-Json).Steps } catch { return @() }
      } else { return @() }
  }
  #endregion ====================== Helper Functions ======================

  #region ====================== Step Functions ======================
  function Run-Step1 {
      Write-Info "Step 1: Configure Windows Settings (Safe Mode)"
      # Theme & taskbar left as user preference.
      # Notifications left enabled (clinic may need alerts).
      if (-not $SafeMode) {
          Set-RegSafe "HKLM:\System\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 0
          Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
      }
      # Storage Sense – keep enabled but tune thresholds
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "01" 1
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "08" 1
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "256" 1
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "32" 1
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" "512" 14
      # Privacy – basic telemetry (1) to keep essential diagnostics
      Set-RegSafe "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 1
      Write-Success "Step 1 complete: conservative settings applied."
      Save-Progress -Step 1
  }
  function Run-Step2 {
      Write-Info "Step 2: Windows Updates (Notify Only)"
      Write-Warning "This step only opens Windows Update settings. Please review and install updates manually during a maintenance window."
      Start-Process "ms-settings:windowsupdate"
      Write-Success "Windows Update settings opened. Step logged as complete."
      Save-Progress -Step 2
  }
  function Run-Step3 {
      Write-Info "Step 3: Review Winget Updates (Safe Mode)"
      if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
          Write-Warning "Winget not installed – skipping."
          return
      }
      $list = winget upgrade --accept-source-agreements 2>$null
      if ($list) {
          Write-Info "Available upgrades:`n$list"
          Write-Warning "Review the list above. To install, run: winget upgrade --all --accept-source-agreements --accept-package-agreements (do this in a test environment first)."
      } else {
          Write-Info "No updates available or winget returned no data."
      }
      Save-Progress -Step 3
  }
  function Run-Step4 {
      Write-Info "Step 4: CCleaner (Limited Safe Mode)"
      $ccleaner = "C:\ITDepartment\CCleaner\CCleaner64.exe"
      if (-not (Test-Path $ccleaner)) {
          Write-Warning "CCleaner not found at $ccleaner – skipping."
          return
      }
      if ($SafeMode) {
          Write-Warning "Safe Mode: CCleaner will run but with restrictions. Please configure CCleaner to:"
          Write-Warning "  * Disable Registry Cleaning"
          Write-Warning "  * Only clean: Temporary Internet Files, Recycle Bin, Temp Files, Windows Logs"
          Write-Warning "  * Do NOT clean: Prefetch, Windows Update Cache, WER Reports"
      }
      Start-Process $ccleaner -Wait
      Write-Success "CCleaner closed. Step logged."
      Save-Progress -Step 4
  }
  function Run-Step5 {
      Write-Info "Step 5: Revo Uninstaller (Disabled by Default)"
      Write-Warning "This step is disabled in Safe Mode to prevent accidental removal of critical software."
      if (-not $SafeMode) {
          $revo = "C:\ITDepartment\Revo Uninstaller Pro\RevoUPPort.exe"
          if (Test-Path $revo) {
              Start-Process $revo -Wait
              Write-Success "Revo Uninstaller closed."
          } else {
              Write-Warning "Revo not found at $revo."
          }
      }
      Save-Progress -Step 5
  }
  function Run-Step6 {
      Write-Info "Step 6: Clinic PC Optimizations (Conservative)"
      # Power plan: high performance but keep reasonable timeouts
      powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null
      powercfg.exe /change monitor-timeout-ac 15   # 15 min monitor off
      powercfg.exe /change standby-timeout-ac 30   # 30 min sleep
      if ($SafeMode) {
          Write-Warning "Safe Mode: Leaving hibernation enabled. Set Set-ItemProperty ... HiberbootEnabled 1 if you want to disable."
      } else {
          Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord
      }
      Set-RegSafe "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" "DisableAutoplay" 1
      Set-RegSafe "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" 255
      Set-RegSafe "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2
      Write-Success "Step 6 applied: performance‑oriented power & visuals, AutoPlay disabled."
      Save-Progress -Step 6
  }
  function Run-Step7 {
      Write-Info "Step 7: Purge Temp & Cache (Selective)"
      $folders = @(
          $env:TEMP,
          "C:\Windows\Temp",
          if (-not $SafeMode) { "C:\Windows\Prefetch" } else { $null },
          "C:\Windows\SoftwareDistribution\Download",
          if (-not $SafeMode) { "C:\ProgramData\Microsoft\Windows\WER\ReportArchive" } else { $null }
      ) | Where-Object { $_ }

      foreach ($path in $folders) {
          if (Test-Path $path) {
              try {
                  Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                  Write-Info "Cleared: $path"
              } catch {
                  Write-Warning "Error clearing $path: $_"
              }
          }
      }
      try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Info "Recycle Bin emptied." }
      catch { Write-Warning "Failed to empty Recycle Bin: $_" }
      Write-Success "Step 7 complete: temp/cache cleared (selective)."
      Save-Progress -Step 7
  }
  #endregion ====================== Step Functions ======================

  #region ====================== UI Construction ======================
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $MainForm = New-Object System.Windows.Forms.Form
  $MainForm.Text = "Clinic PC Maintenance Utility (Optimized)"
  $MainForm.Size = New-Object System.Drawing.Size(800, 520)
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
  $Panel.Size = New-Object System.Drawing.Size(240, 400)
  $Panel.FlowDirection = "TopDown"
  $Panel.WrapContents = $false
  $MainForm.Controls.Add($Panel)

  function Add-GuiButton {
      param([string]$Text, [scriptblock]$Action)
      $btn = New-Object System.Windows.Forms.Button
      $btn.Text = $Text
      $btn.Size = New-Object System.Drawing.Size(220, 35)
      $btn.Font = $BtnFont
      $btn.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
      $btn.Add_Click($Action)
      $Panel.Controls.Add($btn)
      return $btn
  }

  # Manual Restart Button (top)
  $script:btnRestart = Add-GuiButton "🔄 Restart PC" {
      $answer = [System.Windows.Forms.MessageBox]::Show(
          "Are you sure you want to restart the computer now?",
          "Confirm Restart",
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Question
      )
      if ($answer -eq 'Yes') {
          Write-WarningMsg "Restarting PC..."
          Start-Sleep -Seconds 2
          Restart-Computer -Force
      }
  }
  $script:btnRestart.BackColor = [System.Drawing.Color]::LightSalmon
  $script:btnRestart.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

  # Run All Steps Button
  $btnRunAll = Add-GuiButton "▶ RUN ALL STEPS" {
      $done = Get-Progress
      for ($s=1; $s -le 7; $s++) {
          if (-not ($done -contains $s)) {
              &("Run-Step$s")
          }
      }
      Write-Info "All steps processed."
  }
  $btnRunAll.BackColor = [System.Drawing.Color]::LightGreen
  $btnRunAll.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

  # Individual Step buttons
  $script:btnStep1 = Add-GuiButton "1. Configure Windows Settings" { Run-Step1 }
  $script:btnStep2 = Add-GuiButton "2. Review Windows Updates"   { Run-Step2 }
  $script:btnStep3 = Add-GuiButton "3. Review Winget Updates"    { Run-Step3 }
  $script:btnStep4 = Add-GuiButton "4. Launch CCleaner (Limited)"{ Run-Step4 }
  $script:btnStep5 = Add-GuiButton "5. Revo Uninstaller (Disabled)" { Run-Step5 }
  $script:btnStep6 = Add-GuiButton "6. Apply Clinic Optimizations" { Run-Step6 }
  $script:btnStep7 = Add-GuiButton "7. Purge Temp & Cache (Selective)" { Run-Step7 }

  $RichTextBox = New-Object System.Windows.Forms.RichTextBox
  $RichTextBox.Location = New-Object System.Drawing.Point(270, 50)
  $RichTextBox.Size = New-Object System.Drawing.Size(500, 420)
  $RichTextBox.Font = $LogFont
  $RichTextBox.ReadOnly = $true
  $RichTextBox.BackColor = [System.Drawing.Color]::White
  $RichTextBox.ScrollBars = "Vertical"
  $MainForm.Controls.Add($RichTextBox)

  function Write-WarningMsg { param([string]$m) Write-Log -Message $m -Level Warning }

  Write-Info "Welcome to the Clinic PC Maintenance Utility (Optimized)."
  Write-Info "SafeMode = $SafeMode – risky actions are limited or disabled."
  Write-Info "Click a step or 'RUN ALL STEPS'. Logs are written to `$LogFile`."
  Write-Info "Note: Some steps may require a restart; use the manual Restart button when needed.``n"

  # Load previous progress on startup
  $completed = Get-Progress
  if ($completed.Count -gt 0) {
      Write-Info "Resuming session. Completed steps: $($completed -join ', ')"
      foreach ($step in $completed) {
          switch ($step) {
              1 { $script:btnStep1.Text = "✅ 1. Configure Windows Settings" }
              2 { $script:btnStep2.Text = "✅ 2. Review Windows Updates" }
              3 { $script:btnStep3.Text = "✅ 3. Review Winget Updates" }
              4 { $script:btnStep4.Text = "✅ 4. Launch CCleaner (Limited)" }
              5 { $script:btnStep5.Text = "✅ 5. Revo Uninstaller (Disabled)" }
              6 { $script:btnStep6.Text = "✅ 6. Apply Clinic Optimizations" }
              7 { $script:btnStep7.Text = "✅ 7. Purge Temp & Cache (Selective)" }
          }
      }
  }
  #endregion ====================== UI Construction ======================

  [void]$MainForm.ShowDialog()
