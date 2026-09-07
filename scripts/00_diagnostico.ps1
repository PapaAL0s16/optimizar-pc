<#
.SYNOPSIS
  Diagnóstico de solo lectura de una PC con Windows. No cambia nada.
.DESCRIPTION
  Escribe en -OutDir:
    diagnostico.json    todo lo recolectado, para que el agente razone
    resumen.txt         resumen humano con el veredicto de hardware
    verificar_pre.json  medición base (la escribe 02_verificar.ps1)
  Compatible con Windows PowerShell 5.1. Se recomienda correrlo como Administrador
  (sin admin funciona, pero SMART, TPM y algunos logs quedan vacíos).
.PARAMETER Rapido
  Omite medir carpetas de usuario (Descargas, Documentos…) y buscar archivos grandes.
#>
param(
  [string]$OutDir = "$env:USERPROFILE\Desktop\OptimizarPC",
  [switch]$Rapido
)

$ErrorActionPreference = 'Continue'
$inicio = Get-Date
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$refDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'referencias'
$advertencias = New-Object System.Collections.ArrayList
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Warn($msg) { [void]$advertencias.Add($msg); Write-Host "  ! $msg" -ForegroundColor Yellow }
function Paso($msg) { Write-Host "[$((Get-Date) - $inicio | % { $_.ToString('mm\:ss') })] $msg" -ForegroundColor Cyan }
function MB($bytes) { if ($null -eq $bytes) { return 0 }; [math]::Round($bytes / 1MB, 1) }
function GB($bytes) { if ($null -eq $bytes) { return 0 }; [math]::Round($bytes / 1GB, 2) }

function Get-DirSizeMB([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 0 }
  try {
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
      Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    return (MB $sum)
  } catch { return 0 }
}

function Load-Patterns([string]$file) {
  $p = Join-Path $refDir $file
  if (-not (Test-Path $p)) { Warn "No encontré referencias\$file; no se etiquetará."; return @() }
  Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object {
    $parts = $_.Split('|', 3)
    if ($parts.Count -ge 2) {
      [pscustomobject]@{ etiqueta = $parts[0].Trim(); patron = $parts[1].Trim(); nota = $(if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }) }
    }
  }
}
function Tag([string]$texto, $patrones) {
  if (-not $texto) { return $null }
  foreach ($p in $patrones) { if ($texto.IndexOf($p.patron, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $p } }
  return $null
}

$pups = @(Load-Patterns 'pups.txt')
$arrPat = @(Load-Patterns 'arranque.txt')
$D = [ordered]@{}
$D.meta = [ordered]@{ fecha = $inicio.ToString('s'); usuario = $env:USERNAME; equipo = $env:COMPUTERNAME; admin = $esAdmin; version_script = '1.0' }
if (-not $esAdmin) { Warn 'No estoy corriendo como Administrador: SMART, TPM y algunos logs pueden faltar.' }

# ───────────────────────────── 1. Sistema ─────────────────────────────
Paso 'Sistema'
try {
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build = [int]$os.BuildNumber
  $displayVer = $cv.DisplayVersion; if (-not $displayVer) { $displayVer = $cv.ReleaseId }
  $esWin11 = $build -ge 22000
  # Fin de soporte para ediciones Home/Pro (Microsoft Lifecycle)
  $eol = $null
  if (-not $esWin11) { $eol = [datetime]'2025-10-14' }
  else {
    switch ($displayVer) {
      '21H2' { $eol = [datetime]'2023-10-10' }
      '22H2' { $eol = [datetime]'2024-10-08' }
      '23H2' { $eol = [datetime]'2025-11-11' }
      '24H2' { $eol = [datetime]'2026-10-13' }
      '25H2' { $eol = [datetime]'2027-10-12' }
      default { $eol = $null }
    }
  }
  $chasis = @()
  try { $chasis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes) } catch {}
  $bateria = $null
  try { $bateria = Get-CimInstance Win32_Battery } catch {}
  $esLaptop = ($null -ne $bateria) -or (($chasis | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }).Count -gt 0)
  $uptime = (Get-Date) - $os.LastBootUpTime
  $D.sistema = [ordered]@{
    windows            = $os.Caption
    version            = $displayVer
    build              = "$($os.Version).$($cv.UBR)"
    edicion            = $cv.EditionID
    arquitectura       = $os.OSArchitecture
    instalado          = $os.InstallDate.ToString('yyyy-MM-dd')
    ultimo_arranque    = $os.LastBootUpTime.ToString('s')
    uptime_dias        = [math]::Round($uptime.TotalDays, 1)
    fin_de_soporte     = $(if ($eol) { $eol.ToString('yyyy-MM-dd') } else { 'desconocido' })
    fuera_de_soporte   = $(if ($eol) { (Get-Date) -gt $eol } else { $false })
    fabricante         = $cs.Manufacturer
    modelo             = $cs.Model
    es_laptop          = $esLaptop
    firmware           = $env:firmware_type
    fast_startup       = $(try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled -eq 1 } catch { $null })
  }
} catch { Warn "Sistema: $_" }

# ───────────────────────────── 2. CPU ─────────────────────────────
Paso 'CPU'
try {
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  # Carga de CPU sin depender de contadores de rendimiento (Get-Counter usa nombres localizados y
  # en muchas PCs los contadores están dañados): suma de tiempo de CPU de todos los procesos en 3 s.
  $carga = $null; $contadoresOk = $true
  try { $null = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop } catch { $contadoresOk = $false }
  try {
    # (Measure-Object no acepta scriptblock en PS 5.1; se proyecta con ForEach-Object)
    $t0 = (Get-Process | ForEach-Object { try { $_.TotalProcessorTime.TotalMilliseconds } catch { 0 } } | Measure-Object -Sum).Sum
    Start-Sleep -Seconds 3
    $t1 = (Get-Process | ForEach-Object { try { $_.TotalProcessorTime.TotalMilliseconds } catch { 0 } } | Measure-Object -Sum).Sum
    $carga = [math]::Round([math]::Min(100, 100 * ($t1 - $t0) / 3000 / [Environment]::ProcessorCount), 1)
  } catch {}
  $D.cpu = [ordered]@{
    nombre        = $cpu.Name.Trim()
    nucleos       = $cpu.NumberOfCores
    hilos         = $cpu.NumberOfLogicalProcessors
    mhz_max       = $cpu.MaxClockSpeed
    mhz_actual    = $cpu.CurrentClockSpeed
    pct_del_max   = $(if ($cpu.MaxClockSpeed) { [math]::Round(100 * $cpu.CurrentClockSpeed / $cpu.MaxClockSpeed) } else { $null })
    carga_pct     = $carga
    contadores_rendimiento_ok = $contadoresOk   # false = contadores dañados; se arregla con "lodctr /R" (no lo hace la skill)
  }
} catch { Warn "CPU: $_" }

# ───────────────────────────── 3. RAM ─────────────────────────────
Paso 'RAM'
try {
  $os = Get-CimInstance Win32_OperatingSystem
  $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  $libreGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  $modulos = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [ordered]@{ gb = GB $_.Capacity; mhz = $_.Speed; slot = $_.DeviceLocator } })
  $slots = $null; try { $slots = (Get-CimInstance Win32_PhysicalMemoryArray).MemoryDevices } catch {}
  $pf = $null; try { $pf = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1 } catch {}
  $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
    [ordered]@{ proceso = $_.ProcessName; mb = MB $_.WorkingSet64; ruta = $_.Path }
  }
  # Agrupado por nombre (Chrome son 30 procesos)
  $porNombre = Get-Process | Group-Object ProcessName | ForEach-Object {
    [ordered]@{ proceso = $_.Name; instancias = $_.Count; mb = MB (($_.Group | Measure-Object WorkingSet64 -Sum).Sum) }
  } | Sort-Object { $_.mb } -Descending | Select-Object -First 12
  $D.ram = [ordered]@{
    total_gb        = $totalGB
    usada_gb        = [math]::Round($totalGB - $libreGB, 1)
    usada_pct       = [math]::Round(100 * ($totalGB - $libreGB) / $totalGB)
    modulos         = $modulos
    slots_totales   = $slots
    pagefile_mb     = $(if ($pf) { $pf.AllocatedBaseSize } else { $null })
    pagefile_uso_mb = $(if ($pf) { $pf.CurrentUsage } else { $null })
    top_procesos    = @($top)
    por_programa    = @($porNombre)
  }
} catch { Warn "RAM: $_" }

# ───────────────────────────── 4. Discos ─────────────────────────────
Paso 'Discos y SMART'
try {
  $fisicos = @()
  $smartAlerta = $false
  foreach ($pd in (Get-PhysicalDisk)) {
    $rel = $null
    try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
    $item = [ordered]@{
      nombre        = $pd.FriendlyName
      tipo          = "$($pd.MediaType)"
      bus           = "$($pd.BusType)"
      tamano_gb     = GB $pd.Size
      salud         = "$($pd.HealthStatus)"
      estado        = ($pd.OperationalStatus -join ',')
      temperatura_c = $(if ($rel) { $rel.Temperature } else { $null })
      desgaste_pct  = $(if ($rel) { $rel.Wear } else { $null })
      errores_lectura   = $(if ($rel) { $rel.ReadErrorsTotal } else { $null })
      errores_escritura = $(if ($rel) { $rel.WriteErrorsTotal } else { $null })
      horas_encendido   = $(if ($rel) { $rel.PowerOnHours } else { $null })
    }
    if ($pd.HealthStatus -ne 'Healthy') { $smartAlerta = $true }
    if ($rel -and (($rel.ReadErrorsTotal -gt 0) -or ($rel.WriteErrorsTotal -gt 0) -or ($rel.Wear -ge 90))) { $smartAlerta = $true }
    $fisicos += $item
  }
  # ¿En qué disco físico vive C:?
  $tipoC = 'desconocido'
  try {
    $part = Get-Partition -DriveLetter C -ErrorAction Stop
    $pdC = Get-Disk -Number $part.DiskNumber | Get-PhysicalDisk
    $tipoC = "$($pdC.MediaType)"
  } catch {
    try { $tipoC = "$((Get-PhysicalDisk | Where-Object { $_.DeviceId -eq 0 }).MediaType)" } catch {}
  }
  $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
    [ordered]@{ letra = "$($_.DriveLetter)"; etiqueta = $_.FileSystemLabel; fs = $_.FileSystem; tamano_gb = GB $_.Size; libre_gb = GB $_.SizeRemaining; libre_pct = $(if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size) } else { $null }) }
  })
  $volC = $vols | Where-Object { $_.letra -eq 'C' } | Select-Object -First 1
  $D.discos = [ordered]@{ fisicos = $fisicos; volumenes = $vols; volumen_c = $volC; tipo_disco_c = $tipoC; smart_alerta = $smartAlerta }
} catch { Warn "Discos: $_" }

# ───────────────────────────── 5. Errores del sistema ─────────────────────────────
Paso 'Errores críticos (30 días)'
try {
  $desde = (Get-Date).AddDays(-30)
  $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $desde } -ErrorAction SilentlyContinue)
  $cnt = { param($prov, $ids) @($evs | Where-Object { $_.ProviderName -like $prov -and ($null -eq $ids -or $_.Id -in $ids) }).Count }
  $D.errores = [ordered]@{
    total_criticos_y_errores = $evs.Count
    apagones_o_cuelgues      = & $cnt 'Microsoft-Windows-Kernel-Power' @(41)
    disco                    = (& $cnt 'disk' @(7, 11, 51, 153, 157)) + (& $cnt 'Ntfs*' @(55, 98, 137)) + (& $cnt 'volmgr' $null)
    hardware_whea            = & $cnt 'Microsoft-Windows-WHEA-Logger' $null
    controladores            = & $cnt '*' @(219)
    pantallazos_bugcheck     = & $cnt 'Microsoft-Windows-WER-SystemErrorReporting' @(1001)
    top_fuentes              = @($evs | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [ordered]@{ fuente = $_.Name; veces = $_.Count } })
  }
} catch { Warn "Errores: $_" }

# ───────────────────────────── 6. Arranque ─────────────────────────────
Paso 'Programas de arranque'
try {
  function Get-Approved([string]$hive, [string]$sub, [string]$name) {
    # 02/06 = habilitado, 03/07 = deshabilitado (igual que Administrador de tareas)
    foreach ($h in @($hive, 'HKCU', 'HKLM')) {
      try {
        $k = Get-ItemProperty "${h}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub" -ErrorAction Stop
        $v = $k.$name
        if ($v -is [byte[]] -and $v.Length -gt 0) { return $(if (($v[0] % 2) -eq 1) { 'deshabilitado' } else { 'habilitado' }) }
      } catch {}
    }
    return 'habilitado'
  }
  $arranque = @()
  $fuentesReg = @(
    @{ hive = 'HKCU'; ruta = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; sub = 'Run' },
    @{ hive = 'HKLM'; ruta = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run'; sub = 'Run' },
    @{ hive = 'HKLM'; ruta = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; sub = 'Run32' }
  )
  foreach ($f in $fuentesReg) {
    $ps = $f.ruta -replace '^HKCU\\', 'HKCU:\' -replace '^HKLM\\', 'HKLM:\'
    if (-not (Test-Path $ps)) { continue }
    $k = Get-Item $ps
    foreach ($n in $k.GetValueNames()) {
      if (-not $n) { continue }
      $cmd = "$($k.GetValue($n))"
      $t = Tag "$n $cmd" $arrPat
      $arranque += [ordered]@{
        origen = 'reg'; ruta = $f.ruta; nombre = $n; comando = $cmd
        estado = Get-Approved $f.hive $f.sub $n
        etiqueta = $(if ($t) { $t.etiqueta } else { $null })
      }
    }
  }
  $carpetas = @(
    @{ hive = 'HKCU'; p = [Environment]::GetFolderPath('Startup') },
    @{ hive = 'HKLM'; p = [Environment]::GetFolderPath('CommonStartup') }
  )
  foreach ($c in $carpetas) {
    if (-not (Test-Path $c.p)) { continue }
    Get-ChildItem -LiteralPath $c.p -Force -File | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
      $destino = ''
      if ($_.Extension -eq '.lnk') { try { $destino = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName).TargetPath } catch {} }
      $t = Tag "$($_.Name) $destino" $arrPat
      $arranque += [ordered]@{
        origen = 'carpeta'; ruta = $c.p; nombre = $_.Name; comando = $destino
        estado = Get-Approved $c.hive 'StartupFolder' $_.Name
        etiqueta = $(if ($t) { $t.etiqueta } else { $null })
      }
    }
  }
  # Tareas programadas al iniciar sesión / al arrancar, no Microsoft
  try {
    Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.Triggers } | ForEach-Object {
      $trig = @($_.Triggers | ForEach-Object { $_.CimClass.CimClassName })
      if ($trig -match 'Logon|Boot') {
        $acc = @($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
        $t = Tag "$($_.TaskName) $acc" $arrPat
        $arranque += [ordered]@{
          origen = 'tarea'; ruta = $_.TaskPath; nombre = "$($_.TaskPath)$($_.TaskName)"; comando = $acc
          estado = $(if ($_.State -eq 'Disabled') { 'deshabilitado' } else { 'habilitado' })
          etiqueta = $(if ($t) { $t.etiqueta } else { $null })
        }
      }
    }
  } catch { Warn "Tareas programadas: $_" }
  $D.arranque = $arranque
  $D.arranque_resumen = [ordered]@{
    total       = $arranque.Count
    habilitados = @($arranque | Where-Object { $_.estado -eq 'habilitado' }).Count
    se_va       = @($arranque | Where-Object { $_.estado -eq 'habilitado' -and $_.etiqueta -eq 'SE_VA' }).Count
    preguntar   = @($arranque | Where-Object { $_.estado -eq 'habilitado' -and $_.etiqueta -eq 'PREGUNTAR' }).Count
    seguridad   = @($arranque | Where-Object { $_.etiqueta -eq 'SEGURIDAD' }).Count
    sin_etiqueta = @($arranque | Where-Object { $_.estado -eq 'habilitado' -and -not $_.etiqueta }).Count
  }
} catch { Warn "Arranque: $_" }

# ───────────────────────────── 7. Servicios ─────────────────────────────
Paso 'Servicios de terceros'
try {
  $svcs = Get-CimInstance Win32_Service | Where-Object {
    $_.StartMode -eq 'Auto' -and $_.PathName -and ($_.PathName -notmatch '\\Windows\\')
  } | ForEach-Object {
    $t = Tag "$($_.DisplayName) $($_.PathName)" $pups
    [ordered]@{ nombre = $_.Name; display = $_.DisplayName; estado = $_.State; ruta = $_.PathName; etiqueta = $(if ($t) { $t.etiqueta } else { $null }) }
  }
  $D.servicios_terceros_auto = @($svcs)
} catch { Warn "Servicios: $_" }

# ───────────────────────────── 8. Procesos ─────────────────────────────
Paso 'Procesos (muestra de CPU 4 s)'
try {
  $s1 = Get-Process | Select-Object Id, ProcessName, Path, @{n = 'cpu'; e = { $_.TotalProcessorTime.TotalMilliseconds } }
  Start-Sleep -Seconds 4
  $s2 = Get-Process | Select-Object Id, @{n = 'cpu'; e = { $_.TotalProcessorTime.TotalMilliseconds } }
  $h2 = @{}; foreach ($p in $s2) { $h2[$p.Id] = $p.cpu }
  $nproc = [Environment]::ProcessorCount
  $cpuTop = $s1 | ForEach-Object {
    if ($h2.ContainsKey($_.Id) -and $null -ne $_.cpu) {
      $pct = [math]::Round(100 * ($h2[$_.Id] - $_.cpu) / 4000 / $nproc, 1)
      [ordered]@{ proceso = $_.ProcessName; cpu_pct = $pct; ruta = $_.Path }
    }
  } | Where-Object { $_.cpu_pct -gt 0.5 } | Sort-Object { $_.cpu_pct } -Descending | Select-Object -First 12
  $sospechosos = @()
  Get-Process | Where-Object { $_.Path } | Group-Object Path | ForEach-Object {
    $ruta = $_.Name
    $fueraDeSistema = ($ruta -notmatch '^C:\\Windows\\') -and ($ruta -notmatch '^C:\\Program Files')
    $enTemp = $ruta -match '\\Temp\\|\\Downloads\\|\\Descargas\\|\\AppData\\Local\\Temp'
    if ($fueraDeSistema) {
      $firma = 'no_verificada'
      try { $firma = "$((Get-AuthenticodeSignature -LiteralPath $ruta -ErrorAction Stop).Status)" } catch {}
      if ($enTemp -or $firma -ne 'Valid') {
        $sospechosos += [ordered]@{ proceso = $_.Group[0].ProcessName; ruta = $ruta; firma = $firma; en_temp = $enTemp; instancias = $_.Count }
      }
    }
  }
  $D.procesos = [ordered]@{
    total       = (Get-Process).Count
    top_cpu     = @($cpuTop)
    sospechosos = @($sospechosos)
  }
} catch { Warn "Procesos: $_" }

# ───────────────────────────── 9. Programas instalados ─────────────────────────────
Paso 'Programas instalados'
try {
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $progs = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -and $_.SystemComponent -ne 1 -and $_.ParentKeyName -eq $null -and $_.DisplayName -notmatch '^(Update for|Security Update|Hotfix|KB\d)'
  } | ForEach-Object {
    $t = Tag $_.DisplayName $pups
    $fecha = $null
    if ($_.InstallDate -match '^\d{8}$') { $fecha = "$($_.InstallDate.Substring(0,4))-$($_.InstallDate.Substring(4,2))-$($_.InstallDate.Substring(6,2))" }
    [ordered]@{
      nombre    = $_.DisplayName
      editor    = $_.Publisher
      version   = $_.DisplayVersion
      fecha     = $fecha
      tamano_mb = $(if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1024, 1) } else { $null })
      uninstall = $_.UninstallString
      quiet     = $_.QuietUninstallString
      etiqueta  = $(if ($t) { $t.etiqueta } else { $null })
      nota      = $(if ($t) { $t.nota } else { $null })
    }
  } | Sort-Object { $_.nombre } -Unique
  $D.programas = @($progs)
  $D.programas_resumen = [ordered]@{
    total      = $progs.Count
    pup        = @($progs | Where-Object { $_.etiqueta -eq 'PUP' } | ForEach-Object { $_.nombre })
    av_tercero = @($progs | Where-Object { $_.etiqueta -eq 'AV_TERCERO' } | ForEach-Object { $_.nombre })
    seguridad  = @($progs | Where-Object { $_.etiqueta -eq 'SEGURIDAD' } | ForEach-Object { $_.nombre })
    preguntar  = @($progs | Where-Object { $_.etiqueta -eq 'PREGUNTAR' } | ForEach-Object { $_.nombre })
    se_queda   = @($progs | Where-Object { $_.etiqueta -eq 'SE_QUEDA' } | ForEach-Object { $_.nombre })
  }
} catch { Warn "Programas: $_" }

# ───────────────────────────── 10. Antivirus ─────────────────────────────
Paso 'Antivirus'
try {
  $avs = @()
  try {
    Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object {
      $hex = ('{0:X6}' -f [int]$_.productState)
      $avs += [ordered]@{
        nombre      = $_.displayName
        activo      = ($hex.Substring(2, 2) -in '10', '11')
        actualizado = ($hex.Substring(4, 2) -eq '00')
        ruta        = $_.pathToSignedProductExe
      }
    }
  } catch { Warn "SecurityCenter2: $_" }
  $def = $null
  try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $def = [ordered]@{
      antivirus_activo   = $mp.AntivirusEnabled
      tiempo_real        = $mp.RealTimeProtectionEnabled
      firmas_fecha       = $(if ($mp.AntivirusSignatureLastUpdated) { $mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd') } else { $null })
      firmas_dias        = $mp.AntivirusSignatureAge
      ultimo_escaneo_rapido_dias = $(if ($mp.QuickScanAge -ge 4294967295) { 'nunca' } else { $mp.QuickScanAge })
      ultimo_escaneo_completo_dias = $(if ($mp.FullScanAge -ge 4294967295) { 'nunca' } else { $mp.FullScanAge })
      modo_pasivo        = $(if ($mp.PSObject.Properties['AMRunningMode']) { $mp.AMRunningMode } else { $null })
    }
  } catch { Warn "Defender: $_" }
  $terceros = @($avs | Where-Object { $_.nombre -notmatch 'Windows Defender|Microsoft Defender' })
  $D.antivirus = [ordered]@{
    productos            = $avs
    defender             = $def
    terceros_instalados  = @($terceros | ForEach-Object { $_.nombre })
    multiples            = ($avs.Count -gt 1)
    tercero_desactualizado = @($terceros | Where-Object { -not $_.actualizado } | ForEach-Object { $_.nombre })
  }
} catch { Warn "Antivirus: $_" }

# ───────────────────────────── 11. Navegadores ─────────────────────────────
Paso 'Navegadores'
try {
  function Read-ChromiumProfile([string]$userData, [string]$nav) {
    $res = @()
    if (-not (Test-Path $userData)) { return $res }
    Get-ChildItem -LiteralPath $userData -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
      $prof = $_
      $prefPath = Join-Path $prof.FullName 'Preferences'
      if (-not (Test-Path $prefPath)) { return }
      $pref = $null
      try { $pref = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
      # Chrome/Edge guardan lo "protegido" (buscador, extensiones) en "Secure Preferences"
      $secure = $null
      $securePath = Join-Path $prof.FullName 'Secure Preferences'
      if (Test-Path $securePath) { try { $secure = Get-Content -LiteralPath $securePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
      $buscador = $null
      foreach ($src in @($secure, $pref)) {
        if ($buscador -or -not $src) { continue }
        try { $buscador = $src.default_search_provider_data.template_url_data.short_name } catch {}
        if (-not $buscador) { try { $buscador = $src.default_search_provider_data.template_url_data.keyword } catch {} }
      }
      if (-not $buscador) { $buscador = 'predeterminado' }   # sin entrada = el buscador de fábrica (Google en Chrome, Bing en Edge)
      $restaura = $null; try { $restaura = $pref.session.restore_on_startup } catch {}
      $urlsInicio = @(); try { $urlsInicio = @($pref.session.startup_urls) } catch {}
      $paginaInicio = $null; try { $paginaInicio = $pref.homepage } catch {}
      $exts = @()
      try {
        $settings = $null
        if ($secure) { try { $settings = $secure.extensions.settings } catch {} }
        if (-not $settings) { $settings = $pref.extensions.settings }
        if ($settings) {
          foreach ($prop in $settings.PSObject.Properties) {
            $id = $prop.Name; $s = $prop.Value
            $loc = $s.location
            if ($loc -in 5, 10) { continue } # componentes internos
            $nombre = $null
            if ($s.manifest) { $nombre = $s.manifest.name }
            if (-not $nombre -or "$nombre" -like '__MSG_*') {
              $extDir = Join-Path $prof.FullName "Extensions\$id"
              if (Test-Path $extDir) {
                $verDir = Get-ChildItem -LiteralPath $extDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
                if ($verDir) {
                  try {
                    $man = Get-Content -LiteralPath (Join-Path $verDir.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    $nombre = $man.name
                    if ("$nombre" -like '__MSG_*') {
                      $key = "$nombre" -replace '^__MSG_', '' -replace '__$', ''
                      $loc0 = $man.default_locale; if (-not $loc0) { $loc0 = 'en' }
                      $msgs = Get-Content -LiteralPath (Join-Path $verDir.FullName "_locales\$loc0\messages.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                      $nombre = $msgs.$key.message
                    }
                  } catch {}
                }
              }
            }
            if (-not $nombre) { $nombre = $id }
            $exts += [ordered]@{
              nombre        = "$nombre"
              id            = $id
              habilitada    = ($s.state -eq 1)
              de_la_tienda  = [bool]$s.from_webstore
              origen        = $loc
              # location: 2/3 = la instaló otro programa (vector clásico de adware), 4 = descomprimida, 8 = línea de comandos.
              # 6/10 son las que vienen con el navegador (Docs sin conexión, etc.): no son sospechosas.
              sospechosa    = (($null -ne $loc) -and (($loc -in 2, 3, 4, 8) -or ((-not [bool]$s.from_webstore) -and $loc -notin 6, 10)))
            }
          }
        }
      } catch {}
      $cacheMB = (Get-DirSizeMB (Join-Path $prof.FullName 'Cache')) + (Get-DirSizeMB (Join-Path $prof.FullName 'Code Cache')) + (Get-DirSizeMB (Join-Path $prof.FullName 'Service Worker\CacheStorage'))
      $res += [ordered]@{
        navegador        = $nav
        perfil           = $prof.Name
        buscador         = "$buscador"
        buscador_normal  = ("$buscador" -match 'predeterminado|Google|Bing|DuckDuckGo|Ecosia|Brave|Yahoo')
        restaurar_al_abrir = $(switch ($restaura) { 1 { 'continuar donde lo dejo' } 4 { 'paginas especificas' } 5 { 'nueva pestaña' } default { 'predeterminado' } })
        paginas_inicio   = @($urlsInicio)
        pagina_principal = "$paginaInicio"
        extensiones      = @($exts | Where-Object { $_.habilitada })
        extensiones_sospechosas = @($exts | Where-Object { $_.habilitada -and $_.sospechosa } | ForEach-Object { $_.nombre })
        cache_mb         = $cacheMB
      }
    }
    return $res
  }
  $navs = @()
  $navs += Read-ChromiumProfile "$env:LOCALAPPDATA\Google\Chrome\User Data" 'Chrome'
  $navs += Read-ChromiumProfile "$env:LOCALAPPDATA\Microsoft\Edge\User Data" 'Edge'
  $navs += Read-ChromiumProfile "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" 'Brave'
  $navs += Read-ChromiumProfile "$env:APPDATA\Opera Software\Opera Stable" 'Opera'
  $ffProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
  if (Test-Path $ffProfiles) {
    Get-ChildItem -LiteralPath $ffProfiles -Directory | ForEach-Object {
      $ext = @()
      $ej = Join-Path $_.FullName 'extensions.json'
      if (Test-Path $ej) { try { $ext = @((Get-Content -LiteralPath $ej -Raw -Encoding UTF8 | ConvertFrom-Json).addons | Where-Object { $_.type -eq 'extension' -and $_.active -and -not $_.location.StartsWith('app-') } | ForEach-Object { $_.defaultLocale.name }) } catch {} }
      $navs += [ordered]@{ navegador = 'Firefox'; perfil = $_.Name; extensiones = @($ext | ForEach-Object { [ordered]@{ nombre = $_ } }); cache_mb = (Get-DirSizeMB "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\$($_.Name)\cache2") }
    }
  }
  $defaultBrowser = $null
  try { $defaultBrowser = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice').ProgId } catch {}
  $D.navegadores = [ordered]@{ predeterminado = $defaultBrowser; perfiles = @($navs) }
} catch { Warn "Navegadores: $_" }

# ───────────────────────────── 12. Red ─────────────────────────────
Paso 'Red y secuestro'
try {
  $is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $hosts = @()
  # "$_" quita las propiedades PSPath/PSDrive que Get-Content pega a cada línea (inflaban el JSON a 300 MB)
  try { $hosts = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction Stop | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and $_ -notmatch 'localhost|^\s*::1' } | ForEach-Object { "$_".Trim() }) } catch {}
  $dns = @()
  try { $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique) } catch {}
  $D.red = [ordered]@{
    proxy_activo     = ($is.ProxyEnable -eq 1)
    proxy            = $is.ProxyServer
    proxy_script     = $is.AutoConfigURL
    hosts_modificado = ($hosts.Count -gt 0)
    hosts_lineas     = @($hosts | Select-Object -First 20)
    dns              = $dns
  }
} catch { Warn "Red: $_" }

# ───────────────────────────── 13. Uso de disco ─────────────────────────────
Paso 'Uso de disco (puede tardar en HDD)'
try {
  $papeleraMB = 0
  try { $papeleraMB = MB (((New-Object -ComObject Shell.Application).NameSpace(0xA).Items() | Measure-Object -Property Size -Sum).Sum) } catch { $papeleraMB = Get-DirSizeMB 'C:\$Recycle.Bin' }
  $hib = 0; try { $hib = MB (Get-Item 'C:\hiberfil.sys' -Force -ErrorAction Stop).Length } catch {}
  $pfz = 0; try { $pfz = MB (Get-Item 'C:\pagefile.sys' -Force -ErrorAction Stop).Length } catch {}
  $winold = 0; if (Test-Path 'C:\Windows.old') { $winold = Get-DirSizeMB 'C:\Windows.old' }
  $limpieza = [ordered]@{
    temp_usuario_mb       = Get-DirSizeMB $env:TEMP
    temp_windows_mb       = Get-DirSizeMB "$env:SystemRoot\Temp"
    windows_update_cache_mb = Get-DirSizeMB "$env:SystemRoot\SoftwareDistribution\Download"
    papelera_mb           = $papeleraMB
    error_reporting_mb    = (Get-DirSizeMB "$env:ProgramData\Microsoft\Windows\WER")
    drivers_sobrantes_mb  = (Get-DirSizeMB 'C:\AMD') + (Get-DirSizeMB 'C:\NVIDIA') + (Get-DirSizeMB 'C:\Intel')
    prefetch_mb           = Get-DirSizeMB "$env:SystemRoot\Prefetch"
    thumbnails_mb         = (MB ((Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum))
    cache_navegadores_mb  = [math]::Round((@($D.navegadores.perfiles | ForEach-Object { $_.cache_mb }) | Measure-Object -Sum).Sum, 1)
    windows_old_mb        = $winold
    hiberfil_mb           = $hib
    pagefile_mb           = $pfz
  }
  $limpieza.total_seguro_mb = [math]::Round($limpieza.temp_usuario_mb + $limpieza.temp_windows_mb + $limpieza.windows_update_cache_mb + $limpieza.papelera_mb + $limpieza.error_reporting_mb + $limpieza.drivers_sobrantes_mb + $limpieza.cache_navegadores_mb, 1)
  $carpetasUsuario = @()
  $grandes = @()
  if (-not $Rapido) {
    Paso '  Carpetas de usuario y archivos grandes'
    foreach ($u in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' })) {
      $item = [ordered]@{ usuario = $u.Name }
      foreach ($sub in 'Downloads', 'Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'OneDrive') {
        $p = Join-Path $u.FullName $sub
        if (Test-Path $p) { $item[$sub] = [math]::Round((Get-DirSizeMB $p) / 1024, 2) }
      }
      $item.AppData_gb = [math]::Round((Get-DirSizeMB (Join-Path $u.FullName 'AppData')) / 1024, 2)
      $carpetasUsuario += $item
      foreach ($sub in 'Downloads', 'Desktop', 'Documents', 'Videos') {
        $p = Join-Path $u.FullName $sub
        if (Test-Path $p) {
          Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 500MB } | ForEach-Object {
            $grandes += [ordered]@{ archivo = $_.FullName; gb = GB $_.Length; modificado = $_.LastWriteTime.ToString('yyyy-MM-dd') }
          }
        }
      }
    }
    $grandes = @($grandes | Sort-Object { $_.gb } -Descending | Select-Object -First 20)
  }
  $D.disco_uso = [ordered]@{ limpieza_segura = $limpieza; carpetas_usuario_gb = @($carpetasUsuario); archivos_grandes = @($grandes); nota = 'Las carpetas de usuario solo se reportan. La skill nunca borra archivos del usuario.' }
} catch { Warn "Uso de disco: $_" }

# ───────────────────────────── 14. Windows Update ─────────────────────────────
Paso 'Windows Update (hasta 2 min)'
try {
  $ultimo = $null
  try { $ultimo = (Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn.ToString('yyyy-MM-dd') } catch {}
  $rebootPend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
  $pend = $null; $pendNombres = @()
  $job = Start-Job -ScriptBlock {
    try {
      $s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
      $r = $s.Search('IsInstalled=0 and IsHidden=0')
      @{ n = $r.Updates.Count; t = @($r.Updates | ForEach-Object { $_.Title } | Select-Object -First 10) }
    } catch { @{ n = -1; t = @("$_") } }
  }
  if (Wait-Job $job -Timeout 120) { $r = Receive-Job $job; $pend = $r.n; $pendNombres = @($r.t) } else { Warn 'Windows Update no respondió en 2 min (posiblemente atorado).'; $pend = -2 }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
  $D.windows_update = [ordered]@{
    ultimo_parche         = $ultimo
    pendientes            = $pend
    pendientes_nombres    = $pendNombres
    reinicio_pendiente    = $rebootPend
    servicio_wuauserv     = "$($wu.Status) / $($wu.StartType)"
    nota                  = 'pendientes: -1 = error al consultar, -2 = sin respuesta (atorado o sin internet)'
  }
} catch { Warn "Windows Update: $_" }

# ───────────────────────────── 15. Energía y batería ─────────────────────────────
Paso 'Energía'
try {
  $act = powercfg /getactivescheme 2>$null
  $guid = $null; $nombrePlan = $null
  if ($act -match '([0-9a-fA-F-]{36})\s+\((.+)\)') { $guid = $Matches[1]; $nombrePlan = $Matches[2] }
  $bat = $null
  try {
    $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
    $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
    if ($full -and $design) { $bat = [ordered]@{ salud_pct = [math]::Round(100 * $full / $design); capacidad_diseno_mwh = $design; capacidad_actual_mwh = $full } }
  } catch {}
  $D.energia = [ordered]@{ plan = $nombrePlan; plan_guid = $guid; bateria = $bat; en_bateria = $(try { (Get-CimInstance Win32_Battery).BatteryStatus -eq 1 } catch { $null }) }
} catch { Warn "Energía: $_" }

# ───────────────────────────── 16. Efectos visuales ─────────────────────────────
try {
  $vfx = $null; try { $vfx = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -ErrorAction Stop).VisualFXSetting } catch {}
  $trans = $null; try { $trans = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).EnableTransparency } catch {}
  $anim = $null; try { $anim = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction Stop).MinAnimate } catch {}
  $D.visual = [ordered]@{
    modo         = $(switch ($vfx) { 0 { 'windows decide' } 1 { 'mejor apariencia' } 2 { 'mejor rendimiento' } 3 { 'personalizado' } default { 'desconocido' } })
    transparencia = ($trans -ne 0)
    animaciones   = ("$anim" -ne '0')
  }
} catch { Warn "Visual: $_" }

# ───────────────────────────── 17. Térmico ─────────────────────────────
try {
  $temps = @()
  try { $temps = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15, 1) } | Where-Object { $_ -gt 0 -and $_ -lt 130 }) } catch {}
  $D.termico = [ordered]@{
    temp_c      = $(if ($temps.Count) { ($temps | Measure-Object -Maximum).Maximum } else { $null })
    zonas       = $temps
    nota        = 'Muchas PCs no exponen temperatura por ACPI; null no significa que esté bien. El pct_del_max del CPU en reposo también indica throttling.'
  }
} catch {}

# ───────────────────────────── 18. Elegibilidad Windows 11 ─────────────────────────────
Paso 'Elegibilidad Windows 11'
try {
  $tpmVer = $null; $tpmPresente = $null
  try { $tpm = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop; if ($tpm) { $tpmPresente = $true; $tpmVer = "$($tpm.SpecVersion)".Split(',')[0].Trim() } else { $tpmPresente = $false } } catch { }
  $secureBoot = $null; try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $secureBoot = $false }
  $uefi = ($env:firmware_type -eq 'UEFI')
  $ramOk = ($D.ram.total_gb -ge 4)
  $discoOk = ($D.discos.volumen_c.tamano_gb -ge 64)
  $eleg = ($tpmPresente -and $tpmVer -like '2*' -and $uefi -and $ramOk -and $discoOk)
  $D.win11 = [ordered]@{
    ya_es_win11   = ($D.sistema.windows -like '*11*')
    tpm_presente  = $tpmPresente
    tpm_version   = $tpmVer
    uefi          = $uefi
    secure_boot   = $secureBoot
    ram_ok        = $ramOk
    disco_ok      = $discoOk
    elegible_probable = $eleg
    nota          = 'No se verifica la lista de CPUs compatibles; si todo lo demás es true, confirmar con la app "Comprobación de estado del PC" de Microsoft.'
  }
} catch { Warn "Win11: $_" }

# ───────────────────────────── 19. Veredicto ─────────────────────────────
$hdd = ($D.discos.tipo_disco_c -match 'HDD|Unspecified' -and $D.discos.tipo_disco_c -notmatch 'SSD')
$V = [ordered]@{
  smart_alerta       = [bool]$D.discos.smart_alerta
  errores_disco_log  = [int]$D.errores.disco
  disco_sistema_hdd  = [bool]$hdd
  ram_baja           = ($D.ram.total_gb -le 4)
  ram_justa          = ($D.ram.total_gb -gt 4 -and $D.ram.total_gb -le 8)
  disco_lleno        = ($D.discos.volumen_c.libre_pct -lt 15)
  disco_critico      = ($D.discos.volumen_c.libre_pct -lt 7)
  uptime_largo       = ($D.sistema.uptime_dias -ge 7)
  fuera_de_soporte   = [bool]$D.sistema.fuera_de_soporte
  antivirus_multiples = [bool]$D.antivirus.multiples
  antivirus_tercero_vencido = (@($D.antivirus.tercero_desactualizado).Count -gt 0)
  pups               = @($D.programas_resumen.pup).Count
  seguridad_programas = @($D.programas_resumen.seguridad).Count
  seguridad_arranque = [int]$D.arranque_resumen.seguridad
  procesos_sospechosos = @($D.procesos.sospechosos).Count
  proxy_o_hosts      = ([bool]$D.red.proxy_activo -or [bool]$D.red.hosts_modificado)
  arranque_inflado   = ($D.arranque_resumen.habilitados -ge 10)
  buscador_raro      = (@($D.navegadores.perfiles | Where-Object { $_.PSObject.Properties['buscador_normal'] -and -not $_.buscador_normal }).Count -gt 0)
  extensiones_sospechosas = (@($D.navegadores.perfiles | ForEach-Object { $_.extensiones_sospechosas }).Count -gt 0)
  plan_energia_ahorro = ("$($D.energia.plan)" -match 'Economizador|Ahorro|Power saver')
  termico_alto       = ($null -ne $D.termico.temp_c -and $D.termico.temp_c -gt 85)
  cpu_throttling     = ($null -ne $D.cpu.pct_del_max -and $D.cpu.pct_del_max -lt 60 -and $D.cpu.carga_pct -gt 30)
  wu_pendientes      = ($D.windows_update.pendientes -gt 0)
  wu_atorado         = ($D.windows_update.pendientes -eq -2)
}
$sem = '🟢'
if ($V.disco_sistema_hdd -or $V.ram_baja -or $V.disco_critico) { $sem = '🟠' }
if ($V.smart_alerta -or $V.errores_disco_log -gt 0) { $sem = '🔴' }
if ($V.seguridad_programas -gt 0 -or $V.seguridad_arranque -gt 0 -or $V.procesos_sospechosos -gt 0 -or $V.proxy_o_hosts) { $V.bandera_seguridad = $true } else { $V.bandera_seguridad = $false }
$V.semaforo = $sem
$D.veredicto = $V
$D.advertencias = @($advertencias)
$D.meta.duracion_seg = [math]::Round(((Get-Date) - $inicio).TotalSeconds)

# ───────────────────────────── Salida ─────────────────────────────
$jsonPath = Join-Path $OutDir 'diagnostico.json'
$D | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $jsonPath -Encoding UTF8

$L = New-Object System.Collections.ArrayList
function A($s) { [void]$L.Add($s) }
A "RESUMEN DEL DIAGNÓSTICO — $($inicio.ToString('yyyy-MM-dd HH:mm'))   equipo: $env:COMPUTERNAME   usuario: $env:USERNAME   admin: $esAdmin"
A ('=' * 100)
A "$sem  VEREDICTO DE HARDWARE"
if ($V.smart_alerta -or $V.errores_disco_log -gt 0) { A "   🔴 DISCO CON PROBLEMAS (SMART: $($V.smart_alerta), errores en log: $($V.errores_disco_log)). RESPALDAR ANTES DE TOCAR NADA." }
if ($V.disco_sistema_hdd) { A "   🟠 El disco del sistema es HDD (mecánico). Techo real del rendimiento. Recomendar SSD." }
if ($V.ram_baja) { A "   🟠 RAM: $($D.ram.total_gb) GB. Insuficiente para Chrome + cualquier cosa. Recomendar 8 GB." }
elseif ($V.ram_justa) { A "   ·  RAM: $($D.ram.total_gb) GB. Justa; cuidar arranque y extensiones." }
if ($V.disco_critico) { A "   🟠 Disco C: al $($D.discos.volumen_c.libre_pct)% libre. Crítico." } elseif ($V.disco_lleno) { A "   ·  Disco C: al $($D.discos.volumen_c.libre_pct)% libre. Hay que limpiar." }
if ($V.uptime_largo) { A "   ·  $($D.sistema.uptime_dias) días sin reiniciar de verdad." }
if ($V.fuera_de_soporte) { A "   ⚠️  $($D.sistema.windows) $($D.sistema.version): FUERA DE SOPORTE desde $($D.sistema.fin_de_soporte). Win11 elegible (probable): $($D.win11.elegible_probable)" }
if ($V.termico_alto) { A "   🟠 Temperatura $($D.termico.temp_c)°C en reposo. Limpieza física." }
if ($V.cpu_throttling) { A "   🟠 CPU al $($D.cpu.pct_del_max)% de su velocidad máxima bajo carga: posible throttling térmico." }
if ($sem -eq '🟢') { A "   Hardware bien. Es software." }
A ''
if ($V.bandera_seguridad) {
  A '🚨 BANDERA DE SEGURIDAD — revisar antes de optimizar'
  if ($V.seguridad_programas) { A "   Acceso remoto instalado: $($D.programas_resumen.seguridad -join ', ')" }
  if ($V.seguridad_arranque) { A "   Entradas de arranque sospechosas: $((@($D.arranque | Where-Object { $_.etiqueta -eq 'SEGURIDAD' } | ForEach-Object { $_.nombre })) -join ', ')" }
  if ($V.procesos_sospechosos) { A "   Procesos sin firma o desde Temp/Descargas: $((@($D.procesos.sospechosos | ForEach-Object { $_.proceso })) -join ', ')" }
  if ($V.proxy_o_hosts) { A "   Proxy activo: $($D.red.proxy_activo) ($($D.red.proxy))   hosts modificado: $($D.red.hosts_modificado)" }
  A ''
}
A "SISTEMA      $($D.sistema.windows) $($D.sistema.version) build $($D.sistema.build) · $($D.sistema.fabricante) $($D.sistema.modelo) · $(if ($D.sistema.es_laptop) {'laptop'} else {'desktop'})"
A "CPU          $($D.cpu.nombre) · $($D.cpu.nucleos)C/$($D.cpu.hilos)T · carga $($D.cpu.carga_pct)%"
A "RAM          $($D.ram.total_gb) GB · usada $($D.ram.usada_gb) GB ($($D.ram.usada_pct)%) · módulos: $(($D.ram.modulos | ForEach-Object { "$($_.gb)GB@$($_.mhz)" }) -join ' + ') de $($D.ram.slots_totales) slots"
A "   top RAM:  $((@($D.ram.por_programa | Select-Object -First 6 | ForEach-Object { "$($_.proceso)($($_.instancias))=$($_.mb)MB" })) -join ' · ')"
foreach ($f in $D.discos.fisicos) { A "DISCO        $($f.nombre) · $($f.tipo) · $($f.tamano_gb) GB · salud $($f.salud) · desgaste $($f.desgaste_pct)% · err R/W $($f.errores_lectura)/$($f.errores_escritura) · $($f.horas_encendido) h" }
foreach ($v in $D.discos.volumenes) { A "  VOL $($v.letra):  $($v.libre_gb) GB libres de $($v.tamano_gb) ($($v.libre_pct)%)" }
A "ERRORES 30d  apagones/cuelgues $($D.errores.apagones_o_cuelgues) · disco $($D.errores.disco) · hardware $($D.errores.hardware_whea) · pantallazos $($D.errores.pantallazos_bugcheck)"
A ''
A "ARRANQUE     $($D.arranque_resumen.habilitados) habilitados de $($D.arranque_resumen.total) · se_va: $($D.arranque_resumen.se_va) · preguntar: $($D.arranque_resumen.preguntar) · sin etiqueta: $($D.arranque_resumen.sin_etiqueta)"
foreach ($a in ($D.arranque | Where-Object { $_.estado -eq 'habilitado' })) { A ("   [{0,-9}] {1,-40} {2}" -f $(if ($a.etiqueta) { $a.etiqueta } else { '?' }), $a.nombre, $(if ($a.comando.Length -gt 70) { $a.comando.Substring(0, 70) + '…' } else { $a.comando })) }
A ''
A "PROGRAMAS    $($D.programas_resumen.total) instalados"
if ($D.programas_resumen.pup.Count) { A "   PUP:        $($D.programas_resumen.pup -join ' · ')" }
if ($D.programas_resumen.av_tercero.Count) { A "   AV tercero: $($D.programas_resumen.av_tercero -join ' · ')" }
if ($D.programas_resumen.seguridad.Count) { A "   Acc.remoto: $($D.programas_resumen.seguridad -join ' · ')" }
if ($D.programas_resumen.preguntar.Count) { A "   Preguntar:  $($D.programas_resumen.preguntar -join ' · ')" }
A ''
A "ANTIVIRUS    $((@($D.antivirus.productos | ForEach-Object { "$($_.nombre) [activo=$($_.activo) actualizado=$($_.actualizado)]" })) -join ' · ')"
if ($D.antivirus.defender) { A "   Defender:  activo=$($D.antivirus.defender.antivirus_activo) tiempo_real=$($D.antivirus.defender.tiempo_real) firmas hace $($D.antivirus.defender.firmas_dias) d · escaneo completo hace $($D.antivirus.defender.ultimo_escaneo_completo_dias) d" }
A ''
A "NAVEGADOR    predeterminado: $($D.navegadores.predeterminado)"
foreach ($p in $D.navegadores.perfiles) {
  if ($p.PSObject.Properties['buscador']) { A "   $($p.navegador)/$($p.perfil): buscador=$($p.buscador) · al abrir=$($p.restaurar_al_abrir) · $(@($p.extensiones).Count) extensiones ($(@($p.extensiones_sospechosas).Count) sospechosas: $($p.extensiones_sospechosas -join ', ')) · caché $($p.cache_mb) MB" }
  else { A "   $($p.navegador)/$($p.perfil): $(@($p.extensiones).Count) extensiones · caché $($p.cache_mb) MB" }
}
A ''
$lz = $D.disco_uso.limpieza_segura
A "LIMPIEZA SEGURA  ~$([math]::Round($lz.total_seguro_mb/1024,2)) GB: temp $($lz.temp_usuario_mb + $lz.temp_windows_mb) MB · WU caché $($lz.windows_update_cache_mb) MB · papelera $($lz.papelera_mb) MB · caché navegadores $($lz.cache_navegadores_mb) MB · WER $($lz.error_reporting_mb) MB · drivers sobrantes $($lz.drivers_sobrantes_mb) MB"
A "   Nivel 3 (solo con confirmación aparte): Windows.old $([math]::Round($lz.windows_old_mb/1024,1)) GB · hiberfil $([math]::Round($lz.hiberfil_mb/1024,1)) GB"
foreach ($c in $D.disco_uso.carpetas_usuario_gb) { A "   Usuario $($c.usuario): $(($c.PSObject.Properties | Where-Object { $_.Name -ne 'usuario' } | ForEach-Object { "$($_.Name)=$($_.Value)GB" }) -join ' · ')  (SOLO INFORMATIVO, no se borra)" }
if ($D.disco_uso.archivos_grandes.Count) { A "   Archivos >500 MB: $((@($D.disco_uso.archivos_grandes | Select-Object -First 8 | ForEach-Object { "$($_.gb)GB $($_.archivo)" })) -join ' · ')" }
A ''
A "WIN UPDATE   último parche $($D.windows_update.ultimo_parche) · pendientes $($D.windows_update.pendientes) · reinicio pendiente $($D.windows_update.reinicio_pendiente)"
A "ENERGÍA      plan: $($D.energia.plan) $(if ($D.energia.bateria) { "· batería $($D.energia.bateria.salud_pct)% de salud" })"
A "VISUAL       $($D.visual.modo) · transparencia $($D.visual.transparencia) · animaciones $($D.visual.animaciones)"
A "SERVICIOS    $(@($D.servicios_terceros_auto).Count) de terceros en automático: $((@($D.servicios_terceros_auto | Select-Object -First 15 | ForEach-Object { $_.display })) -join ' · ')"
if ($advertencias.Count) { A ''; A 'ADVERTENCIAS DEL SCRIPT'; foreach ($w in $advertencias) { A "   ! $w" } }
A ''
A "Duración: $($D.meta.duracion_seg) s. Detalle completo en diagnostico.json"
$L -join "`r`n" | Out-File -LiteralPath (Join-Path $OutDir 'resumen.txt') -Encoding UTF8

# Medición base para comparar después
$ver = Join-Path $PSScriptRoot '02_verificar.ps1'
if (Test-Path $ver) { & $ver -Etiqueta pre -OutDir $OutDir -SinEspera } else { Warn 'No encontré 02_verificar.ps1; no se guardó medición base.' }

Write-Host "`nListo. Archivos en $OutDir" -ForegroundColor Green
Write-Host ($L -join "`n")
