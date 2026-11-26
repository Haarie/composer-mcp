# SOLIDWORKS Composer MCP - persistent PowerShell host
# Reads one base64(JSON) request per line on stdin, writes "@@CRMCP@@" + base64(JSON) per response on stdout.
# Keeps the Composer COM object alive between calls. Composer does not register in the Running
# Object Table; all COM clients (also other MCPs) share one Composer process.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
$global:app = $null
$global:ApiDumpCs = $null
$global:CrInterop = $null
$global:CrPsRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'export.ps1')

function ConvertTo-Plain($v, [int]$depth = 0) {
  if ($null -eq $v) { return $null }
  if ($v -is [string] -or $v -is [ValueType]) { return $v }
  if ($v -is [psobject] -and $v.PSObject.Properties['__com']) { return '[Composer ' + $v.__type + ']' }
  if ($depth -gt 3) { return [string]$v }
  if ($v -is [System.__ComObject]) { return '[COM object]' }
  if ($v -is [Collections.IDictionary]) {
    $h = [ordered]@{}
    foreach ($k in $v.Keys) { $h[[string]$k] = ConvertTo-Plain $v[$k] ($depth + 1) }
    return $h
  }
  if ($v -is [Collections.IEnumerable]) { return @($v | ForEach-Object { ConvertTo-Plain $_ ($depth + 1) }) }
  return [string]$v
}

function global:Get-TypeLibPath {
  $key = Get-ChildItem 'Registry::HKEY_CLASSES_ROOT\TypeLib\{A71E1897-7597-441A-B1D8-725087CBF5FD}' | Select-Object -First 1
  if (-not $key) { throw 'Composer type library is not registered. Run composer.exe /regserver as administrator.' }
  $win = Get-ChildItem $key.PSPath -Recurse | Where-Object { $_.PSChildName -eq 'win64' -or $_.PSChildName -eq 'win32' } | Select-Object -First 1
  return (Get-ItemProperty $win.PSPath).'(default)'
}

# Interop types from the type library (IApplication, IDocument). Calls go through the vtable,
# because Composer's IDispatch does not resolve member names or DISPIDs.
function global:Initialize-CrInterop {
  if ($global:CrInterop) { return $global:CrInterop }
  if (-not ('ComposerImporter' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition (Get-Content -Raw (Join-Path $global:CrPsRoot 'interop.cs'))
  }
  $asm = [ComposerImporter]::Import((Get-TypeLibPath))
  $global:CrInterop = @{ App = $asm.GetType('ComposerInterop.IApplication'); Doc = $asm.GetType('ComposerInterop.IDocument') }
  return $global:CrInterop
}

function global:ConvertTo-CrArg($value, [Type]$t) {
  if ($null -eq $value) { return $null }
  if ($value -is [psobject] -and $value.PSObject.Properties['__com']) { return $value.__com }
  if ($value -is [System.__ComObject]) { return $value }
  if ($t -eq [object]) { return $value }
  return [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, $t)
}

function global:ConvertFrom-CrResult($r) {
  if ($null -eq $r) { return $null }
  if ($r -is [Enum]) { return [int]$r }
  if ($r -is [System.__ComObject]) { return New-CrWrapper $r $global:CrInterop.Doc }  # only IDocument is returned as an object
  return $r
}

function global:Invoke-CrMethod($com, [Reflection.MethodInfo]$mi, [object[]]$a) {
  $ps = $mi.GetParameters()
  if ($null -eq $a) { $a = @() }
  if ($a.Count -ne $ps.Count) {
    throw ("$($mi.Name) expects $($ps.Count) argument(s): " + (($ps | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', '))
  }
  $conv = New-Object object[] $ps.Count
  for ($i = 0; $i -lt $ps.Count; $i++) {
    $t = $ps[$i].ParameterType; if ($t.IsByRef) { $t = $t.GetElementType() }
    $conv[$i] = ConvertTo-CrArg $a[$i] $t
  }
  try { $r = $mi.Invoke($com, $conv) } catch [Reflection.TargetInvocationException] { throw $_.Exception.InnerException }
  if ($mi.ReturnType -eq [void]) { return }  # no stray $null in the output
  return (ConvertFrom-CrResult $r)
}

# PowerShell object with the interface's methods and properties, so scripts can write
# $app.Open($path), $doc.RenderMode = 3, $app.RunRibbonCommand(32) as usual.
function global:New-CrWrapper($com, [Type]$t) {
  $w = [pscustomobject]@{ __com = $com; __type = $t.Name }
  foreach ($p in $t.GetProperties()) {
    $pi = $p
    $getter = { ConvertFrom-CrResult ($pi.GetValue($this.__com, $null)) }.GetNewClosure()
    $setter = { param($v) $pi.SetValue($this.__com, (ConvertTo-CrArg $v $pi.PropertyType), $null) }.GetNewClosure()
    $w | Add-Member -MemberType ScriptProperty -Name $p.Name -Value $getter -SecondValue $setter
  }
  foreach ($m in ($t.GetMethods() | Where-Object { -not $_.IsSpecialName })) {
    $mi = $m
    $w | Add-Member -MemberType ScriptMethod -Name $m.Name -Value ({ Invoke-CrMethod $this.__com $mi $args }.GetNewClosure())
  }
  return $w
}

function Test-App {
  if ($null -eq $global:app) { return $false }
  try { $null = $global:CrInterop.App.GetProperty('Version').GetValue($global:app.__com, $null); return $true }
  catch { $global:app = $null; return $false }
}

function Get-App([bool]$start) {
  if (Test-App) { return $global:app }
  if (-not $start) {
    throw 'Composer is not connected. Call status with start=true: that opens a Composer window controlled by this MCP (a Composer you started yourself cannot be reached).'
  }
  $ci = Initialize-CrInterop
  $raw = New-Object -ComObject DSComposer.Application
  $global:app = New-CrWrapper $raw $ci.App
  try { $global:app.Visible = $true } catch { }
  return $global:app
}

function Get-Doc {
  if (-not (Test-App)) { return $null }
  try { return $global:app.GetActiveDocument() } catch { return $null }
}

function Get-ApiReference {
  if (-not $global:ApiDumpCs) {
    $global:ApiDumpCs = Get-Content -Raw (Join-Path $PSScriptRoot 'tlbdump.cs')
    Add-Type -TypeDefinition $global:ApiDumpCs -Language CSharp
  }
  $file = Get-TypeLibPath
  return [ComposerTlbDump]::Dump($file)
}

function Invoke-Request($A) {
  switch ($A.action) {
    'status' {
      $app = Get-App ([bool]$A.start)
      $docs = @()
      try {
        $n = $app.GetDocumentCount()
        for ($i = 1; $i -le $n; $i++) { try { $docs += [string]$app.GetDocument($i).FileName } catch { } }  # GetDocument is 1-based
      } catch { }
      $doc = Get-Doc; $active = $null
      if ($doc) { try { $active = [string]$doc.FileName } catch { } }
      return [ordered]@{ ok = $true; connected = $true; version = [string]$app.Version; activeDocument = $active; documents = $docs }
    }
    'open' {
      $app = Get-App $true
      $d = $app.Open([string]$A.path)
      if ($null -eq $d) { return [ordered]@{ ok = $false; error = 'Composer did not open the file (cancelled or failed).' } }
      try { $null = $app.SetActiveDocument($d) } catch { }
      return [ordered]@{ ok = $true; fileName = [string]$d.FileName }
    }
    'api_reference' {
      return [ordered]@{ ok = $true; result = (Get-ApiReference) }
    }
    'run_script' {
      $app = $null; $doc = $null
      if (Test-App) { $app = $global:app; $doc = Get-Doc }
      $sb = [ScriptBlock]::Create([string]$A.code)
      $out = & $sb
      return [ordered]@{ ok = $true; result = (ConvertTo-Plain $out) }
    }
    'export_svg' {
      $app = Get-App $false
      return (Invoke-CrSvgExport $app $A)
    }
    'diagnose' {
      $progids = @(Get-ChildItem 'Registry::HKEY_CLASSES_ROOT' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match 'Composer|3DVIA' } |
        ForEach-Object {
          $clsid = $null
          try { $clsid = (Get-ItemProperty -Path ($_.PSPath + '\CLSID') -ErrorAction Stop).'(default)' } catch { }
          [ordered]@{ progId = $_.PSChildName; clsid = $clsid }
        })
      $typelib = Test-Path 'Registry::HKEY_CLASSES_ROOT\TypeLib\{A71E1897-7597-441A-B1D8-725087CBF5FD}'
      $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'composer' } |
        ForEach-Object { [ordered]@{ name = $_.ProcessName; id = $_.Id; title = $_.MainWindowTitle } })
      return [ordered]@{ ok = $true; progIds = $progids; typeLibRegistered = $typelib; processes = $procs; mcpConnected = (Test-App) }
    }
    default { throw "Unknown action: $($A.action)" }
  }
}

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if (-not $line) { continue }
  $id = $null
  try {
    $A = $utf8.GetString([Convert]::FromBase64String($line)) | ConvertFrom-Json
    $id = $A.id
    $res = Invoke-Request $A
  } catch {
    $msg = $_.Exception.Message
    if ($_.InvocationInfo) { $msg += " (line $($_.InvocationInfo.ScriptLineNumber))" }
    $res = [ordered]@{ ok = $false; error = $msg }
  }
  $reply = [ordered]@{ id = $id; result = $res }
  $json = $reply | ConvertTo-Json -Depth 8 -Compress
  [Console]::Out.WriteLine('@@CRMCP@@' + [Convert]::ToBase64String($utf8.GetBytes($json)))
  [Console]::Out.Flush()
}
