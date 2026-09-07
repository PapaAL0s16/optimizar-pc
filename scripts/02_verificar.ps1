<#
.SYNOPSIS
  Mide lo que el usuario siente: tiempo de arranque, RAM en reposo, disco libre,
  programas de arranque, procesos. Con -Etiqueta post compara contra la medición "pre"
  y escribe reporte.md.
.PARAMETER SinEspera
  No espera a que la PC lleve 2 minutos encendida (úsalo cuando lo llama el diagnóstico).
#>
param(
  [ValidateSet('pre', 'post')][string]$Etiqueta = 'pre',
  [string]$OutDir = "$env:USERPROFILE\Desktop\OptimizarPC",
  [switch]$SinEspera
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Esperar a que el sistema se asiente tras un reinicio (la RAM "en reposo" no es real el primer minuto)
if (-not $SinEspera) {
  $up = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  $falta = 120 - [int]$up.TotalSeconds
  if ($falta -gt 0 -and $falta -le 120) { Write-Host "Esperando $falta s a que el sistema se asiente…"; Start-Sleep -Seconds $falta }
}

function MB($b) { if ($null -eq $b) { 0 } else { [math]::Round($b / 1MB) } }

# Tiempo de arranque (Event 100 = duración del último arranque en ms)
$bootMs = $null; $bootFecha = $null
try {
  $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
  if ($e) {
    $x = [xml]$e.ToXml()
    $bt = $x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1
    if ($bt) { $bootMs = [int]$bt.'#text' }
    $bootFecha = $e.TimeCreated.ToString('s')
  }
} catch {}
$bootMetodo = 'evento100'
if (-not $bootMs) {
  # Ese log solo lo lee un Administrador. Plan B: del arranque del kernel al inicio de sesión (Winlogon 7001).
  try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    # -Oldest: el PRIMER inicio de sesión tras el arranque, no el último
    $logon = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Winlogon'; Id = 7001; StartTime = $boot } -MaxEvents 1 -Oldest -ErrorAction Stop
    if ($logon) { $bootMs = [int](($logon.TimeCreated - $boot).TotalMilliseconds); $bootFecha = $logon.TimeCreated.ToString('s'); $bootMetodo = 'hasta_logon' }
  } catch {}
}

# Conteo de arranque habilitado (mismo criterio que Administrador de tareas)
function Aprobado([string]$sub, [string]$name) {
  foreach ($h in 'HKCU', 'HKLM') {
    try {
      $v = (Get-ItemProperty "${h}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub" -ErrorAction Stop).$name
      if ($v -is [byte[]] -and $v.Length) { return (($v[0] % 2) -eq 0) }
    } catch {}
  }
  return $true
}
$arr = 0
foreach ($k in @(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'Run'), @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'Run'), @('HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Run32'))) {
  if (Test-Path $k[0]) { foreach ($n in (Get-Item $k[0]).GetValueNames()) { if ($n -and (Aprobado $k[1] $n)) { $arr++ } } }
}
foreach ($p in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
  if (Test-Path $p) { Get-ChildItem -LiteralPath $p -File -Force | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { if (Aprobado 'StartupFolder' $_.Name) { $arr++ } } }
}
try { $arr += @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' -and (@($_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -match 'Logon|Boot') }).Count } catch {}

$os = Get-CimInstance Win32_OperatingSystem
$c = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
$cpu = $null
try {
  # Sin contadores de rendimiento (fallan en muchas PCs y están localizados): suma de CPU de procesos en 3 s
  $t0 = (Get-Process | ForEach-Object { try { $_.TotalProcessorTime.TotalMilliseconds } catch { 0 } } | Measure-Object -Sum).Sum
  Start-Sleep -Seconds 3
  $t1 = (Get-Process | ForEach-Object { try { $_.TotalProcessorTime.TotalMilliseconds } catch { 0 } } | Measure-Object -Sum).Sum
  $cpu = [math]::Round([math]::Min(100, 100 * ($t1 - $t0) / 3000 / [Environment]::ProcessorCount))
} catch {}

$M = [ordered]@{
  etiqueta            = $Etiqueta
  fecha               = (Get-Date).ToString('s')
  uptime_min          = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes, 1)
  arranque_seg        = $(if ($bootMs) { [math]::Round($bootMs / 1000, 1) } else { $null })
  arranque_medido_en  = $bootFecha
  arranque_metodo     = $bootMetodo
  ram_total_gb        = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  ram_usada_mb        = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
  ram_usada_pct       = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
  disco_c_libre_gb    = $(if ($c) { [math]::Round($c.SizeRemaining / 1GB, 2) } else { $null })
  arranque_habilitados = $arr
  procesos            = (Get-Process).Count
  servicios_corriendo = @(Get-Service | Where-Object Status -eq 'Running').Count
  cpu_reposo_pct      = $cpu
}
$path = Join-Path $OutDir "verificar_$Etiqueta.json"
$M | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $path -Encoding UTF8
Write-Host "Medición '$Etiqueta' guardada en $path"
$M.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Key, $_.Value) }

if ($Etiqueta -eq 'post') {
  $prePath = Join-Path $OutDir 'verificar_pre.json'
  if (-not (Test-Path $prePath)) { Write-Warning 'No hay verificar_pre.json; no puedo comparar.'; return }
  $P = Get-Content -LiteralPath $prePath -Raw -Encoding UTF8 | ConvertFrom-Json
  function Fila($nombre, $a, $b, $unidad, $mejorSiBaja) {
    if ($null -eq $a -or $null -eq $b) { return "| $nombre | $a | $b | — |" }
    $d = [math]::Round($b - $a, 1)
    $pct = $(if ($a) { [math]::Round(100 * $d / $a) } else { 0 })
    $mejora = $(if ($mejorSiBaja) { $d -lt 0 } else { $d -gt 0 })
    $ico = $(if ([math]::Abs($pct) -lt 3) { '=' } elseif ($mejora) { '✅' } else { '⚠️' })
    "| $nombre | $a $unidad | $b $unidad | $ico $(if ($d -gt 0) {'+'})$d $unidad ($(if ($pct -gt 0) {'+'})$pct %) |"
  }
  $R = @()
  $R += "# Reporte de optimización — $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
  $R += ''
  $R += "Antes: $($P.fecha)   ·   Después: $($M.fecha)"
  $R += ''
  $R += '| Métrica | Antes | Después | Cambio |'
  $R += '|---|---|---|---|'
  $R += Fila 'Tiempo de arranque' $P.arranque_seg $M.arranque_seg 's' $true
  $R += Fila 'RAM usada en reposo' $P.ram_usada_mb $M.ram_usada_mb 'MB' $true
  $R += Fila 'RAM usada (%)' $P.ram_usada_pct $M.ram_usada_pct '%' $true
  $R += Fila 'Espacio libre en C:' $P.disco_c_libre_gb $M.disco_c_libre_gb 'GB' $false
  $R += Fila 'Programas al arrancar' $P.arranque_habilitados $M.arranque_habilitados '' $true
  $R += Fila 'Procesos en reposo' $P.procesos $M.procesos '' $true
  $R += Fila 'Servicios corriendo' $P.servicios_corriendo $M.servicios_corriendo '' $true
  $R += Fila 'CPU en reposo' $P.cpu_reposo_pct $M.cpu_reposo_pct '%' $true
  $R += ''
  if ($M.arranque_metodo -eq 'hasta_logon' -or $P.arranque_metodo -eq 'hasta_logon') {
    $R += "_Tiempo de arranque = del encendido al inicio de sesión (incluye lo que tardó la persona en escribir su contraseña). Es una aproximación; para la medida exacta corre la verificación como Administrador._"
  } else {
    $R += "_El tiempo de arranque se mide del último arranque registrado por Windows (Event 100). Si el 'después' no cambió, aún no ha reiniciado desde la optimización._"
  }
  $rep = Join-Path $OutDir 'reporte.md'
  $R -join "`r`n" | Out-File -LiteralPath $rep -Encoding UTF8
  Write-Host "`nReporte en $rep`n"
  Write-Host ($R -join "`n")
}
