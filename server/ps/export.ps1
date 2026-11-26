# SOLIDWORKS Composer MCP - SVG export through the Technical Illustration workshop.
# Composer's COM API cannot write vector files, so this drives the workshop's own controls with
# Win32 messages: pick the profile, tick Multiple > Views, press "Save As..." and fill in the save dialog.
# Works without moving the mouse or needing keyboard focus.

function global:Initialize-CrUi {
  if (-not ('CrUi' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition (Get-Content -Raw (Join-Path $global:CrPsRoot 'uiexport.cs'))
  }
}

function global:Get-TiPanel($app) {
  $main = [IntPtr]([int64]$app.MainWindowHandle)
  $det = [CrUi]::FindChild($main, 'Button', 'Detail view', 0)
  if ($det -ne [IntPtr]::Zero -and [CrUi]::IsWindowVisible($det)) { return [CrUi]::GetParent($det) }
  return [IntPtr]::Zero
}

function global:Show-TechnicalIllustration($app) {
  $p = Get-TiPanel $app
  if ($p -ne [IntPtr]::Zero) { return $p }
  $null = $app.SetActiveWorkShop(7)
  Start-Sleep -Milliseconds 600
  $p = Get-TiPanel $app
  if ($p -eq [IntPtr]::Zero) { $null = $app.RunRibbonCommand(279); Start-Sleep -Milliseconds 800; $p = Get-TiPanel $app }
  if ($p -eq [IntPtr]::Zero) { throw 'Technical Illustration workshop did not appear.' }
  return $p
}

function global:Get-ToolbarButton($panel, [string]$text) {
  foreach ($tb in [CrUi]::Children($panel)) {
    if ([CrUi]::Class($tb) -ne 'ToolbarWindow32' -or [CrUi]::GetParent($tb) -ne $panel) { continue }
    foreach ($b in [CrUi]::ToolbarButtons($tb)) {
      $f = $b.Split('|')
      if ($f[3].Trim() -like $text) {
        $r = $f[4].Split(',')
        return @{ Toolbar = $tb; Command = [int]$f[1]; X = [int](([int]$r[0] + [int]$r[2]) / 2); Y = [int](([int]$r[1] + [int]$r[3]) / 2) }
      }
    }
  }
  return $null
}

function global:Set-TiProfile($panel, [string]$profile) {
  $combo = [CrUi]::FindChild($panel, 'ComboBox', $null, 13705)
  if ($combo -eq [IntPtr]::Zero) { throw 'Profile list not found in the Technical Illustration workshop.' }
  $idx = [int][CrUi]::SendMessageW($combo, 0x014C, [IntPtr](-1), $profile)   # CB_FINDSTRING (prefix)
  if ($idx -lt 0) {
    $n = [int][CrUi]::SendMessage($combo, 0x0146, [IntPtr]0, [IntPtr]0)
    $names = @(); for ($i = 0; $i -lt $n; $i++) { $names += Get-ComboText $combo $i }
    throw "Profile '$profile' not found. Available: " + ($names -join '; ')
  }
  $null = [CrUi]::SendMessage($combo, 0x014E, [IntPtr]$idx, [IntPtr]0)       # CB_SETCURSEL
  $wp = [IntPtr]((1 -shl 16) -bor 13705)                                        # CBN_SELCHANGE
  $null = [CrUi]::SendMessage([CrUi]::GetParent($combo), 0x0111, $wp, $combo)
  Start-Sleep -Milliseconds 300
  return (Get-ComboText $combo $idx).Trim()
}

function global:Get-ComboText($combo, [int]$i) {
  $len = [int][CrUi]::SendMessage($combo, 0x0149, [IntPtr]$i, [IntPtr]0)       # CB_GETLBTEXTLEN
  $sb = New-Object string ([char]' '), ([Math]::Max($len, 0) + 1)
  $null = [CrUi]::SendMessageW($combo, 0x0148, [IntPtr]$i, $sb)                # CB_GETLBTEXT
  return $sb.Substring(0, [Math]::Max($len, 0))
}

function global:Set-TiMultipleViews($app, [bool]$on) {
  $main = [IntPtr]([int64]$app.MainWindowHandle)
  $btn = [CrUi]::FindChild($main, 'Button', 'Views', 14150)
  if ($btn -eq [IntPtr]::Zero) { throw 'Multiple > Views option not found.' }
  $chk = [int][CrUi]::SendMessage($btn, 0x00F0, [IntPtr]0, [IntPtr]0)          # BM_GETCHECK
  if (($chk -eq 1) -ne $on) {
    $null = [CrUi]::SendMessage($btn, 0x00F1, [IntPtr]([int]$on), [IntPtr]0)  # BM_SETCHECK
    $null = [CrUi]::SendMessage([CrUi]::GetParent($btn), 0x0111, [IntPtr]14150, $btn)  # BN_CLICKED
    Start-Sleep -Milliseconds 200
  }
}

function global:Wait-ProcessDialog([uint32]$cpid, [string]$titleLike, [int]$seconds) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
    foreach ($d in [CrUi]::ProcessDialogs($cpid)) { if ([CrUi]::Text($d) -like $titleLike) { return $d } }
    Start-Sleep -Milliseconds 200
  }
  return [IntPtr]::Zero
}

function global:Invoke-CrSvgExport($app, $A) {
  Initialize-CrUi
  if ($A.views) {
    $all = @(); $t0 = Get-Date; $errs = @()
    foreach ($v in @($A.views)) {
      $one = Invoke-CrSvgExport $app ([pscustomobject]@{ folder = $A.folder; view = [string]$v; profile = $A.profile; timeout_s = $A.timeout_s })
      if ($one.ok) { $all += $one.files } else { $errs += "$v : $($one.error)" }
    }
    return [ordered]@{ ok = ($errs.Count -eq 0); folder = [string]$A.folder; mode = 'views'; profile = $A.profile
      seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); count = $all.Count; files = $all; errors = $errs }
  }
  $doc = $app.GetActiveDocument()
  if ($null -eq $doc) { throw 'No document is open in Composer.' }
  $folder = [string]$A.folder
  if (-not $folder) { throw 'folder is required' }
  $null = New-Item -ItemType Directory -Force -Path $folder
  $mode = if ($A.view) { 'view' } else { 'all' }

  $panel = Show-TechnicalIllustration $app
  $profileUsed = $null
  if ($A.profile) { $profileUsed = Set-TiProfile $panel ([string]$A.profile) }
  if ($mode -eq 'view') {
    if (-not $doc.GoToView([string]$A.view)) { throw "View '$($A.view)' not found." }
    Start-Sleep -Milliseconds 500
  }
  Set-TiMultipleViews $app ($mode -eq 'all')

  $save = Get-ToolbarButton $panel 'Save As*'
  if (-not $save) { throw 'Save As button not found in the Technical Illustration workshop.' }
  $cpid = [CrUi]::ProcessOf([IntPtr]([int64]$app.MainWindowHandle))
  $start = Get-Date
  # The toolbar command is sent to the workshop panel (a mouse click on the toolbar is not always picked up).
  $null = [CrUi]::PostMessage([CrUi]::GetParent($save.Toolbar), 0x0111, [IntPtr]$save.Command, $save.Toolbar)   # WM_COMMAND
  $dlg = Wait-ProcessDialog $cpid 'Save*' 5
  if ($dlg -eq [IntPtr]::Zero) { [CrUi]::Click($save.Toolbar, $save.X, $save.Y); $dlg = Wait-ProcessDialog $cpid 'Save*' 10 }
  if ($dlg -eq [IntPtr]::Zero) { throw 'The save dialog did not appear.' }

  $name = if ($mode -eq 'view') { ([string]$A.view) + '.svg' } else { 'views.svg' }
  $target = Join-Path $folder $name
  $edit = [CrUi]::GetDlgItem($dlg, 1152)
  if ($edit -eq [IntPtr]::Zero) { $edit = [CrUi]::FindChild([CrUi]::GetDlgItem($dlg, 1148), 'Edit', $null, 0) }
  if ($edit -eq [IntPtr]::Zero) { throw 'File name box not found in the save dialog.' }
  $null = [CrUi]::SendMessageW($edit, 0x000C, [IntPtr]0, $target)            # WM_SETTEXT
  $null = [CrUi]::PostMessage([CrUi]::GetDlgItem($dlg, 1), 0x00F5, [IntPtr]0, [IntPtr]0)  # BM_CLICK Save

  # Answer "replace existing file?" prompts and wait until Composer is done writing.
  $timeout = if ($A.timeout_s) { [int]$A.timeout_s } else { 600 }
  $lastCount = -1; $stableSince = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $timeout) {
    foreach ($d in [CrUi]::ProcessDialogs($cpid)) {
      $yes = [CrUi]::GetDlgItem($d, 6)                                         # IDYES
      if ($yes -ne [IntPtr]::Zero -and $d -ne $dlg) { $null = [CrUi]::PostMessage($yes, 0x00F5, [IntPtr]0, [IntPtr]0) }
    }
    $files = @(Get-ChildItem -LiteralPath $folder -Filter *.svg -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-1) })
    $busy = $false
    try { $null = $app.GetActiveWorkShop() } catch { $busy = $true }
    if ($files.Count -ne $lastCount) { $lastCount = $files.Count; $stableSince = Get-Date }
    $dlgOpen = @([CrUi]::ProcessDialogs($cpid)).Count -gt 0
    if (-not $busy -and -not $dlgOpen -and $files.Count -gt 0 -and ((Get-Date) - $stableSince).TotalSeconds -ge 3) { break }
    if ($mode -eq 'view' -and $files.Count -ge 1 -and -not $dlgOpen -and ((Get-Date) - $stableSince).TotalSeconds -ge 2) { break }
    Start-Sleep -Milliseconds 500
  }
  $files = @(Get-ChildItem -LiteralPath $folder -Filter *.svg -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-1) } | Sort-Object Name)
  return [ordered]@{
    ok = ($files.Count -gt 0); folder = $folder; mode = $mode; profile = $profileUsed
    seconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1); count = $files.Count
    files = @($files | ForEach-Object { $_.Name })
    error = $(if ($files.Count -eq 0) { 'No SVG files were written (timed out or cancelled).' } else { $null })
  }
}
