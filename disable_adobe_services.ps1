<#
disable_adobe_services.ps1 - turn Adobe's background services off, or back on.

  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.ps1 | iex"

There are no options. Run it, pick Disable or Enable from the menu. Use an
Administrator window to cover services, scheduled tasks and machine-wide
startup entries; without it those are skipped and the script says so.

What it covers:
  - Adobe services. Stopped and set to Disabled. The original start type is
    saved first, so Enable puts back Manual instead of forcing Automatic.
  - Adobe scheduled tasks (updaters, telemetry).
  - Run and RunOnce startup entries, flipped with the same StartupApproved
    flag Task Manager's Startup tab uses. Nothing is deleted.
  - Running helpers. Creative apps are never stopped.

If you downloaded this file, it deletes itself when it finishes.

Everything is in functions and the last line calls Invoke-Main, so a download
that gets cut off does nothing instead of half of it. It also never calls
`exit`, which would close the window of anyone who pasted this into a
PowerShell session they were already using.

NOTE: this has not yet been run on a real Windows machine.

macOS version: disable_adobe_services.sh
#>

$ErrorActionPreference = 'Stop'

# Original service start types live here so Enable can put them back. HKCU is
# writable without elevation and survives reboots.
$StateKey = 'HKCU:\Software\adobe_services_disabler'

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Never stopped, even though "adobe" appears in the name or path. Prefixes, so
# "Photoshop (Beta)" is covered too.
$NeverKill = @(
  'Photoshop', 'Illustrator', 'InDesign', 'AfterFX', 'Animate', 'Bridge',
  'Dreamweaver', 'Acrobat', 'AcroRd32', 'Adobe Premiere', 'Adobe Audition',
  'Adobe Media Encoder', 'Adobe Lightroom', 'Lightroom', 'Character Animator',
  'Adobe Dimension', 'Adobe Substance', 'Adobe Digital Editions'
)

# Folders that only ever hold background helpers, so anything running from
# them is fair game even when its name does not say Adobe.
$HelperPaths = @(
  '*\Common Files\Adobe\*',
  '*\Adobe\Adobe Creative Cloud*',
  '*\Adobe\Adobe Sync\*',
  '*\Adobe\Adobe Desktop Common\*'
)

# Startup locations, each with the StartupApproved key that holds its on/off flag.
$RunKeys = @(
  [pscustomobject]@{
    Label      = 'HKCU'
    Run        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Approved   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    NeedsAdmin = $false
  }
  [pscustomobject]@{
    Label      = 'HKCU-RunOnce'
    Run        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Approved   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    NeedsAdmin = $false
  }
  [pscustomobject]@{
    Label      = 'HKLM'
    Run        = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    Approved   = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    NeedsAdmin = $true
  }
  [pscustomobject]@{
    Label      = 'HKLM32'
    Run        = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'
    Approved   = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
    NeedsAdmin = $true
  }
)

function Get-AdobeServices {
  Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like '*adobe*' -or $_.DisplayName -like '*adobe*'
  }
}

function Get-AdobeTasks {
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like '*adobe*' -or $_.TaskPath -like '*adobe*'
  }
}

function Get-AdobeRunEntries {
  foreach ($key in $RunKeys) {
    if (-not (Test-Path $key.Run)) { continue }
    $item = $null
    try { $item = Get-Item $key.Run } catch { continue }
    foreach ($name in $item.GetValueNames()) {
      if (-not $name) { continue }
      $value = [string]$item.GetValue($name)
      if ($name -like '*adobe*' -or $value -like '*adobe*' -or
          $value -like '*creative cloud*') {
        [pscustomobject]@{ Key = $key; Name = $name; Value = $value }
      }
    }
  }
}

# No StartupApproved value means enabled. An odd first byte means disabled.
function Test-RunEntryDisabled($entry) {
  $bytes = $null
  if (Test-Path $entry.Key.Approved) {
    try { $bytes = (Get-Item $entry.Key.Approved).GetValue($entry.Name) } catch { }
  }
  ($bytes -is [byte[]]) -and $bytes.Length -ge 1 -and (($bytes[0] % 2) -eq 1)
}

function Set-RunEntryState($entry, [bool]$Disabled) {
  if ($Disabled) {
    $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTime()))
  } else {
    $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  }
  if (-not (Test-Path $entry.Key.Approved)) {
    New-Item -Path $entry.Key.Approved -Force | Out-Null
  }
  New-ItemProperty -Path $entry.Key.Approved -Name $entry.Name -Value $bytes `
    -PropertyType Binary -Force | Out-Null
}

# Win32_Service rather than Get-Service, because Windows PowerShell 5.1 has no
# StartType property and 5.1 is still the default on Windows.
function Get-ServiceStartType([string]$Name) {
  try {
    $mode = (Get-CimInstance Win32_Service -Filter "Name='$Name'").StartMode
    switch ($mode) {
      'Auto'   { return 'Automatic' }
      'Manual' { return 'Manual' }
      default  { return [string]$mode }
    }
  } catch {
    return 'Automatic'
  }
}

function Save-ServiceStartType([string]$Name, [string]$StartType) {
  if (-not (Test-Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
  New-ItemProperty -Path $StateKey -Name $Name -Value $StartType `
    -PropertyType String -Force | Out-Null
}

function Get-SavedServiceStartType([string]$Name) {
  if (-not (Test-Path $StateKey)) { return $null }
  try { return [string](Get-Item $StateKey).GetValue($Name) } catch { return $null }
}

function Get-AdobeProcesses {
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $p = $_
    if ($p.Id -eq $PID) { return $false }
    foreach ($safe in $NeverKill) {
      if ($p.Name -like "$safe*") { return $false }
    }
    if ($p.Name -like '*adobe*') { return $true }

    # Reading .Path on a protected process throws, and with ErrorAction Stop
    # that would abort the whole pipeline instead of skipping one process.
    $path = $null
    try { $path = $p.Path } catch { }
    if ($path) {
      foreach ($pattern in $HelperPaths) {
        if ($path -like $pattern) { return $true }
      }
    }
    # Path is unreadable for SYSTEM-owned processes, so match known names too.
    $p.Name -in @('CCXProcess', 'CCLibrary', 'CoreSync', 'Creative Cloud',
                  'Creative Cloud Helper', 'acrotray', 'armsvc', 'AGSService',
                  'AGMService', 'AdobeUpdateService', 'AdobeIPCBroker',
                  'AdobeGCClient', 'AdobeNotificationClient')
  }
}

function Show-Status($services, $tasks, $entries, $procs) {
  Write-Host 'Current Adobe startup items:'
  foreach ($s in @($services)) {
    $start = Get-ServiceStartType $s.Name
    $state = if ($start -eq 'Disabled') { 'disabled' } else { "enabled ($start)" }
    Write-Host ('  [service] {0,-46} {1}' -f $s.Name, $state)
  }
  foreach ($t in @($tasks)) {
    $state = if ($t.State -eq 'Disabled') { 'disabled' } else { 'enabled' }
    Write-Host ('  [task]    {0,-46} {1}' -f ($t.TaskPath + $t.TaskName), $state)
  }
  foreach ($e in @($entries)) {
    $state = if (Test-RunEntryDisabled $e) { 'disabled' } else { 'enabled' }
    Write-Host ('  [startup] {0,-46} {1}' -f "$($e.Key.Label)\$($e.Name)", $state)
  }
  foreach ($p in @($procs)) {
    Write-Host ('  [running] {0,-46} pid {1}' -f $p.Name, $p.Id)
  }
}

# Arrow-key menu. Returns the chosen index, or -1 if the user backs out.
function Read-Menu {
  $options = @('Disable Adobe startup services',
               'Enable Adobe startup services',
               'Quit')

  # Input is piped rather than typed: 1 disables, 2 enables.
  if ([Console]::IsInputRedirected) {
    switch ([Console]::In.ReadLine()) {
      '1' { return 0 }
      '2' { return 1 }
      default { return -1 }
    }
  }

  Write-Host 'Up/down to move, Enter to select, q to quit:'
  $selected = 0
  $choice = $null

  # Hide the cursor while the menu is up, otherwise it sits under the list as
  # a stray bar. Treat Ctrl-C as a keystroke for the duration, so it cannot
  # kill the script while the cursor is hidden; both settings are restored in
  # the finally block no matter how we leave. Every console call is guarded:
  # some hosts (ISE and friends) throw on cursor operations.
  $hadCtrlC = $false
  try { $hadCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }
  try { [Console]::CursorVisible = $false } catch { }
  try {
    while ($null -eq $choice) {
      for ($i = 0; $i -lt $options.Count; $i++) {
        if ($i -eq $selected) {
          Write-Host ('   {0} ' -f $options[$i]) -ForegroundColor Black -BackgroundColor Gray
        } else {
          Write-Host ('   {0} ' -f $options[$i])
        }
      }

      $key = [Console]::ReadKey($true)
      if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
        $choice = -1
        continue
      }
      switch ($key.Key) {
        'UpArrow'   { $selected = ($selected + $options.Count - 1) % $options.Count }
        'DownArrow' { $selected = ($selected + 1) % $options.Count }
        'Enter'     { $choice = $selected }
        'Escape'    { $choice = -1 }
        'Q'         { $choice = -1 }
      }

      # Back to the top of the list to redraw. Hosts that cannot move the
      # cursor, and the top of the buffer where the target would be negative,
      # just redraw below instead - noisier, but it still works.
      if ($null -eq $choice) {
        try {
          $top = [Console]::CursorTop - $options.Count
          if ($top -ge 0) { [Console]::SetCursorPosition(0, $top) }
        } catch { }
      }
    }
  } finally {
    try { [Console]::CursorVisible = $true } catch { }
    try { [Console]::TreatControlCAsInput = $hadCtrlC } catch { }
  }

  # The choice is made: wipe the menu and its instruction line so the
  # highlighted row does not sit in the output for the rest of the run.
  try {
    $rows = $options.Count + 1
    $top = [Console]::CursorTop - $rows
    if ($top -ge 0) {
      $blank = ' ' * ([Console]::WindowWidth - 1)
      [Console]::SetCursorPosition(0, $top)
      for ($i = 0; $i -lt $rows; $i++) { Write-Host $blank }
      [Console]::SetCursorPosition(0, $top)
    }
  } catch { }

  return $choice
}

function Invoke-Change([string]$Description, [scriptblock]$Action) {
  Write-Host "  $Description"
  try { & $Action } catch { Write-Host "    failed: $($_.Exception.Message)" }
}

# Delete the downloaded copy. $PSCommandPath is empty when the script arrived
# through `irm | iex`, so that path does nothing. A git checkout is someone's
# source, so leave it be. A running .ps1 can delete itself: PowerShell has
# already read the whole file.
function Remove-Self {
  $path = $PSCommandPath
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }

  $dir = Split-Path -Parent $path
  if ($dir -and (Test-Path -LiteralPath (Join-Path $dir '.git'))) { return }

  try {
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    Write-Host 'Removed the downloaded script.'
  } catch { }
}

# --- Main --------------------------------------------------------------------

function Invoke-Main {
  $services = @(Get-AdobeServices)
  $tasks    = @(Get-AdobeTasks)
  $entries  = @(Get-AdobeRunEntries)
  $procs    = @(Get-AdobeProcesses)

  if (-not $services -and -not $tasks -and -not $entries -and -not $procs) {
    Write-Host 'Nothing from Adobe found. Nothing to do.'
    Remove-Self
    return
  }

  Show-Status $services $tasks $entries $procs
  Write-Host ''

  $mode = switch (Read-Menu) {
    0 { 'disable' }
    1 { 'enable' }
    default { $null }
  }
  if (-not $mode) { Remove-Self; return }
  Write-Host ''

  if (-not $IsAdmin) {
    Write-Host 'Not an Administrator window: services, scheduled tasks and'
    Write-Host 'machine-wide startup entries will be skipped.'
    Write-Host ''
  }

  if ($services) {
    Write-Host '== Services =='
    if (-not $IsAdmin) {
      Write-Host '  skipped (needs Administrator)'
    } else {
      foreach ($s in $services) {
        if ($mode -eq 'disable') {
          $original = Get-ServiceStartType $s.Name
          Invoke-Change "Disabling $($s.Name) (was $original)" {
            if ($original -ne 'Disabled') { Save-ServiceStartType $s.Name $original }
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $s.Name -StartupType Disabled
          }
        } else {
          $saved = Get-SavedServiceStartType $s.Name
          $target = if ($saved) { $saved } else { 'Automatic' }
          Invoke-Change "Enabling $($s.Name) -> $target" {
            Set-Service -Name $s.Name -StartupType $target
            if ($target -eq 'Automatic') {
              Start-Service -Name $s.Name -ErrorAction SilentlyContinue
            }
          }
        }
      }
    }
  }

  if ($tasks) {
    Write-Host ''
    Write-Host '== Scheduled tasks =='
    if (-not $IsAdmin) {
      Write-Host '  skipped (needs Administrator)'
    } else {
      foreach ($t in $tasks) {
        if ($mode -eq 'disable') {
          Invoke-Change "Disabling $($t.TaskPath)$($t.TaskName)" {
            Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null
          }
        } else {
          Invoke-Change "Enabling $($t.TaskPath)$($t.TaskName)" {
            Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null
          }
        }
      }
    }
  }

  if ($entries) {
    Write-Host ''
    Write-Host '== Startup entries =='
    foreach ($e in $entries) {
      if ($e.Key.NeedsAdmin -and -not $IsAdmin) {
        Write-Host "  skipped $($e.Key.Label)\$($e.Name) (needs Administrator)"
        continue
      }
      $disable = ($mode -eq 'disable')
      $verb = if ($disable) { 'Disabling' } else { 'Enabling' }
      Invoke-Change "$verb $($e.Key.Label)\$($e.Name)" {
        Set-RunEntryState $e $disable
      }
    }
  }

  if ($mode -eq 'disable') {
    Write-Host ''
    Write-Host '== Stopping running Adobe processes =='
    # Re-read: the work above may have stopped some already.
    $live = @(Get-AdobeProcesses)
    if (-not $live) { Write-Host '  none running' }
    foreach ($p in $live) {
      Invoke-Change "Stopping $($p.Name) (pid $($p.Id))" {
        Stop-Process -Id $p.Id -Force
      }
    }
  }

  Write-Host ''
  if ($mode -eq 'disable') {
    Write-Host 'Done. Some helpers come back once when a Creative Cloud app is'
    Write-Host 'opened, but not at boot. Task Manager > Startup apps should now'
    Write-Host 'show the Adobe entries as Disabled. Re-run after an Adobe update.'
  } else {
    Write-Host 'Done. Everything starts again at your next boot or login.'
  }

  Remove-Self
}

Invoke-Main
