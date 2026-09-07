<#
.SYNOPSIS
  Ejecuta SOLO las acciones aprobadas en plan.json, con punto de restauración,
  registro completo (aplicar.log) y archivo de deshacer (deshacer.json).
.EXAMPLE
  01_aplicar.ps1 -Plan "$env:USERPROFILE\Desktop\OptimizarPC\plan.json"
  01_aplicar.ps1 -Plan ... -DryRun                 # muestra qué haría, no toca nada
  01_aplicar.ps1 -Deshacer "...\deshacer.json"     # revierte arranque, servicios, energía, visual
#>
param(
  [string]$Plan,
  [string]$Deshacer,
  [string]$OutDir = "$env:USERPROFILE\Desktop\OptimizarPC",
  [switch]$DryRun,
  [switch]$SinPuntoRestauracion,
  [int]$TimeoutDesinstalarMin = 10,
  [int]$TimeoutUpdateMin = 45
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$logPath = Join-Path $OutDir 'aplicar.log'
$undoPath = Join-Path $OutDir 'deshacer.json'
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')

function Log([string]$msg, [string]$nivel = 'INFO') {
  $line = "$((Get-Date).ToString('HH:mm:ss')) [$nivel] $msg"
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
  $color = switch ($nivel) { 'OK' { 'Green' } 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'DRY' { 'DarkGray' } default { 'White' } }
  Write-Host $line -ForegroundColor $color
}
if (-not $esAdmin -and -not $DryRun) { Log 'Este script necesita Administrador. Ábrelo con -Verb RunAs.' 'ERROR'; exit 2 }
if ($DryRun) { Log '=== MODO DRY-RUN: no se cambia nada (no requiere Administrador) ===' 'DRY' }

# ── Usuario interactivo (por si el admin que eleva no es el dueño de la sesión) ──
$interactivo = $null; try { $interactivo = (Get-CimInstance Win32_ComputerSystem).UserName } catch {}
$HKCU = 'HKCU:'
$perfilUsuario = $env:USERPROFILE
$localAppData = $env:LOCALAPPDATA
$tempUsuario = $env:TEMP
if ($interactivo -and ($interactivo -notlike "*\$env:USERNAME")) {
  try {
    $sid = (New-Object System.Security.Principal.NTAccount($interactivo)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
    if ($prof -and (Test-Path "Registry::HKEY_USERS\$sid")) {
      $HKCU = "Registry::HKEY_USERS\$sid"; $perfilUsuario = $prof; $localAppData = "$prof\AppData\Local"; $tempUsuario = "$prof\AppData\Local\Temp"
      Log "Sesión de '$interactivo' distinta al admin '$env:USERNAME'. Las acciones de usuario van a su perfil ($prof)." 'WARN'
    }
  } catch { Log "No pude resolver el perfil de $interactivo; uso el del admin. $_" 'WARN' }
}

# ── Deshacer ──
$undo = New-Object System.Collections.ArrayList
if (Test-Path $undoPath) { try { (Get-Content -LiteralPath $undoPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { [void]$undo.Add($_) } } catch {} }
function SaveUndo($obj) { [void]$undo.Add([pscustomobject]$obj); if (-not $DryRun) { $undo | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $undoPath -Encoding UTF8 } }

<#
  Blindaje del registro. plan.json y deshacer.json viven en el Escritorio: quien pueda
  escribirlos no debe poder hacer que este script (elevado) escriba en cualquier clave.
  Solo se permiten las claves que la skill realmente usa.
#>
function Clave-Permitida([string]$clave) {
  if (-not $clave) { return $false }
  $patrones = @(
    '(?i)^(HKCU:|HKLM:|Registry::HKEY_USERS\\S-[\d\-]+)\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\(Run|Run32|StartupFolder)$',
    '(?i)^(HKCU:|Registry::HKEY_USERS\\S-[\d\-]+)\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize$',
    '(?i)^(HKCU:|Registry::HKEY_USERS\\S-[\d\-]+)\\Control Panel\\Desktop\\WindowMetrics$',
    '(?i)^(HKCU:|Registry::HKEY_USERS\\S-[\d\-]+)\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced$'
  )
  foreach ($p in $patrones) { if ($clave -match $p) { return $true } }
  return $false
}

function Approved-Key([string]$rutaRun, [string]$origen) {
  # Devuelve la clave StartupApproved que controla esa entrada (igual que Administrador de tareas)
  if ($origen -eq 'carpeta') {
    if ($rutaRun -like "$([Environment]::GetFolderPath('CommonStartup'))*") { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    return "$HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
  }
  if ($rutaRun -like 'HKCU*') { return "$HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" }
  if ($rutaRun -like '*WOW6432Node*') { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
  return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
}

if ($Deshacer) {
  if (-not (Test-Path $Deshacer)) { Log "No existe $Deshacer" 'ERROR'; exit 1 }
  $items = @(Get-Content -LiteralPath $Deshacer -Raw -Encoding UTF8 | ConvertFrom-Json)
  Log "=== DESHACER $($items.Count) cambios ==="
  [array]::Reverse($items)
  foreach ($u in $items) {
    try {
      switch ($u.tipo) {
        'arranque_reg' {
          if (-not (Clave-Permitida $u.clave)) { Log "BLOQUEADO: clave no permitida en deshacer.json: $($u.clave)" 'ERROR'; break }
          if ($u.previo) { Set-ItemProperty -Path $u.clave -Name $u.nombre -Value ([byte[]]$u.previo) -Type Binary } else { Remove-ItemProperty -Path $u.clave -Name $u.nombre -ErrorAction SilentlyContinue }
          Log "Arranque rehabilitado: $($u.nombre)" 'OK'
        }
        'arranque_tarea' { Enable-ScheduledTask -TaskPath $u.ruta -TaskName $u.nombre | Out-Null; Log "Tarea rehabilitada: $($u.nombre)" 'OK' }
        'servicio'      { Set-Service -Name $u.nombre -StartupType $u.previo; Log "Servicio $($u.nombre) → $($u.previo)" 'OK' }
        'energia'       { powercfg /setactive $u.previo | Out-Null; Log "Plan de energía restaurado ($($u.previo))" 'OK' }
        'visual'        {
          foreach ($p in $u.previo.PSObject.Properties) {
            $k, $n = $p.Name.Split('|')
            if (-not (Clave-Permitida $k)) { Log "BLOQUEADO: clave no permitida en deshacer.json: $k" 'ERROR'; continue }
            if ($null -ne $p.Value) { Set-ItemProperty -Path $k -Name $n -Value $p.Value }
          }
          Log 'Efectos visuales restaurados' 'OK'
        }
        'hibernacion'   { powercfg /h on | Out-Null; Log 'Hibernación reactivada' 'OK' }
        'desinstalar'   { Log "No se puede reinstalar automáticamente: $($u.nombre). Reinstálalo a mano si hace falta." 'WARN' }
        default         { Log "Tipo de deshacer desconocido: $($u.tipo)" 'WARN' }
      }
    } catch { Log "Deshacer $($u.tipo) $($u.nombre): $_" 'ERROR' }
  }
  Log 'Deshacer terminado. Reinicia para que aplique todo.'
  exit 0
}

# ── Cargar plan ──
if (-not $Plan -or -not (Test-Path $Plan)) { Log 'Falta -Plan <ruta a plan.json>' 'ERROR'; exit 1 }
$P = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
$acciones = @($P.acciones | Sort-Object { [int]$_.nivel }, { $_.id })
Log "=== APLICAR $($acciones.Count) acciones del plan $($P.fecha) ==="
$esLaptop = $false; try { $esLaptop = ($null -ne (Get-CimInstance Win32_Battery)) } catch {}
$ok = 0; $fail = 0; $skip = 0

# ── Paso 0: punto de restauración + respaldos ──
if (-not $DryRun) {
  if (-not $SinPuntoRestauracion) {
    Log 'Creando punto de restauración…'
    $creado = $false
    try {
      Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
      $freqKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
      $prevFreq = (Get-ItemProperty $freqKey -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
      Set-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord   # permite crear uno aunque haya otro reciente
      $antes = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
      Checkpoint-Computer -Description "OptimizarPC $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
      $despues = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
      $creado = ($despues.Count -gt $antes) -or (@($despues | Where-Object { $_.Description -like 'OptimizarPC*' }).Count -gt 0)
      if ($null -ne $prevFreq) { Set-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -Value $prevFreq } else { Remove-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
    } catch { Log "Checkpoint-Computer: $_" 'WARN' }
    if ($creado) { Log "Punto de restauración 'OptimizarPC $stamp' creado." 'OK' }
    else { Log 'NO se pudo crear el punto de restauración. Me detengo. Si el usuario acepta continuar sin él, relanza con -SinPuntoRestauracion.' 'ERROR'; exit 3 }
  } else { Log 'Continuando SIN punto de restauración por petición explícita.' 'WARN' }
  foreach ($k in @(@('HKCU\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU_Run'), @('HKLM\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM_Run'), @('HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM_Run32'))) {
    reg export $k[0] (Join-Path $OutDir "respaldo_$($k[1]).reg") /y 2>$null | Out-Null
  }
  Get-Service | Select-Object Name, StartType, Status | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'respaldo_servicios.json') -Encoding UTF8
  Log 'Respaldo de claves Run y estado de servicios guardado.' 'OK'
}

# ── Blindaje: nunca borrar fuera de estas raíces, ni una raíz completa ──
$RaicesBorrables = @(
  $tempUsuario, "$env:SystemRoot\Temp", "$env:SystemRoot\SoftwareDistribution\Download",
  "$env:ProgramData\Microsoft\Windows\WER", 'C:\AMD', 'C:\NVIDIA', 'C:\Intel', $localAppData
) | Where-Object { $_ } | ForEach-Object { try { [IO.Path]::GetFullPath($_).TrimEnd('\') } catch {} }
$NuncaBorrar = @(
  'C:\', $env:SystemRoot, "$env:SystemRoot\System32", $env:ProgramData, 'C:\Program Files',
  'C:\Program Files (x86)', 'C:\Users', $perfilUsuario, $localAppData, "$env:APPDATA",
  "$perfilUsuario\Documents", "$perfilUsuario\Desktop", "$perfilUsuario\Downloads",
  "$perfilUsuario\Pictures", "$perfilUsuario\Videos", "$perfilUsuario\Music", "$perfilUsuario\OneDrive"
) | Where-Object { $_ } | ForEach-Object { try { [IO.Path]::GetFullPath($_).TrimEnd('\') } catch {} }

function Ruta-Borrable([string]$path) {
  if (-not $path) { return $false }
  $full = $null
  try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $false }
  if ($full.Length -lt 8) { return $false }                                    # "C:\Temp" es lo más corto aceptable
  if ($NuncaBorrar -contains $full) { return $false }                          # nunca una carpeta protegida completa
  foreach ($r in $RaicesBorrables) {
    if ($full -eq $r -or $full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false                                                                # fuera de la lista blanca: no se toca
}

function Borrar-Contenido([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  if (-not (Ruta-Borrable $path)) { Log "BLOQUEADO: '$path' está fuera de las rutas permitidas; no se borra." 'WARN'; return 0 }
  $antes = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if (-not $DryRun) { Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
  $despues = $(if ($DryRun) { 0 } else { (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum })
  return [math]::Round(($antes - $despues) / 1MB)
}
function Run-Timeout([string]$file, [string]$argumentos, [int]$min) {
  # Sin cmd.exe: Start-Process no interpreta &, |, ; ni redirecciones.
  $p = if ($argumentos) { Start-Process -FilePath $file -ArgumentList $argumentos -PassThru -WindowStyle Hidden }
       else { Start-Process -FilePath $file -PassThru -WindowStyle Hidden }
  if (-not $p.WaitForExit($min * 60 * 1000)) { try { $p.Kill() } catch {}; return 'TIMEOUT' }
  return $p.ExitCode
}

<#
  Blindaje de desinstaladores. El UninstallString viene del registro, que cualquier
  instalador (o malware) puede escribir. Antes se pasaba a `cmd.exe /c`, lo que permitía
  colar `& algo.exe` y ejecutarlo como Administrador. Ahora se parsea en ejecutable +
  argumentos y se lanza sin shell; si no se puede validar, no se ejecuta.
#>
function Parse-Desinstalador([string]$s) {
  if (-not $s) { return $null }
  $s = $s.Trim()
  try { $s = [Environment]::ExpandEnvironmentVariables($s) } catch { return $null }
  # Metacaracteres de shell fuera de las comillas ⇒ sospechoso, se rechaza
  $fuera = [regex]::Replace($s, '"[^"]*"', '')
  if ($fuera -match '[&|;`\r\n<>^]|\$\(') { return $null }
  $exe = $null; $argumentos = ''
  if ($s.StartsWith('"')) {
    $i = $s.IndexOf('"', 1)
    if ($i -lt 1) { return $null }
    $exe = $s.Substring(1, $i - 1); $argumentos = $s.Substring($i + 1).Trim()
  }
  elseif ($s -match '(?i)^(?<exe>.+?\.exe)\s*(?<rest>.*)$') { $exe = $Matches.exe.Trim(); $argumentos = $Matches.rest.Trim() }
  else { return $null }
  if ($exe -match '[&|;`\r\n<>^"]') { return $null }
  if (-not [IO.Path]::IsPathRooted($exe)) {
    $c = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $exe = $c.Source
  }
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
  return @{ exe = $exe; args = $argumentos }
}
function Programa-Instalado([string]$nombre) {
  $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', "$HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
  return (@(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $nombre }).Count -gt 0)
}

# ── Acciones ──
foreach ($a in $acciones) {
  $tag = "[$($a.id)] $($a.tipo)"
  try {
    switch ($a.tipo) {

      'limpiar_temp' {
        $mb = 0
        foreach ($p in @($tempUsuario, "$env:SystemRoot\Temp", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:ProgramData\Microsoft\Windows\WER\Temp", 'C:\AMD', 'C:\NVIDIA', 'C:\Intel')) { $mb += Borrar-Contenido $p }
        Log "$tag liberó ~$mb MB (lo que estaba en uso se queda; es normal)." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'vaciar_papelera' {
        if (-not $DryRun) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        Log "$tag papelera vaciada." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'limpiar_wu_cache' {
        if (-not $DryRun) { Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue }
        $mb = Borrar-Contenido "$env:SystemRoot\SoftwareDistribution\Download"
        if (-not $DryRun) { Start-Service bits, wuauserv -ErrorAction SilentlyContinue }
        Log "$tag liberó ~$mb MB de caché de Windows Update." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'limpiar_cache_navegador' {
        $mapa = @{ Chrome = @("$localAppData\Google\Chrome\User Data", 'chrome'); Edge = @("$localAppData\Microsoft\Edge\User Data", 'msedge'); Brave = @("$localAppData\BraveSoftware\Brave-Browser\User Data", 'brave') }
        $navs = @($a.navegadores); if (-not $navs.Count) { $navs = @('Chrome', 'Edge') }
        foreach ($n in $navs) {
          if (-not $mapa.ContainsKey($n)) { continue }
          if (Get-Process -Name $mapa[$n][1] -ErrorAction SilentlyContinue) { Log "$tag $n está abierto; ciérralo y repite esta acción. Omitida." 'WARN'; $skip++; continue }
          $mb = 0
          Get-ChildItem -LiteralPath $mapa[$n][0] -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') { $mb += Borrar-Contenido (Join-Path $_.FullName $c) }
          }
          Log "$tag ${n}: ~$mb MB de caché." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
        }
      }

      'desactivar_arranque' {
        switch ($a.origen) {
          'tarea' {
            $tp = Split-Path $a.nombre -Parent; if (-not $tp.EndsWith('\')) { $tp += '\' }
            $tn = Split-Path $a.nombre -Leaf
            if (-not $DryRun) { Disable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop | Out-Null; SaveUndo @{ tipo = 'arranque_tarea'; ruta = $tp; nombre = $tn } }
            Log "$tag tarea deshabilitada: $($a.nombre)" $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
          }
          default {
            $key = Approved-Key $a.ruta $a.origen
            if (-not (Clave-Permitida $key)) { Log "$tag BLOQUEADO: clave no permitida: $key" 'ERROR'; $fail++; break }
            $previo = $null
            try { $v = (Get-ItemProperty -Path $key -ErrorAction Stop).($a.nombre); if ($v -is [byte[]]) { $previo = @($v) } } catch {}
            # 03 = deshabilitado + marca de tiempo (FILETIME) igual que el Administrador de tareas
            $ft = [BitConverter]::GetBytes([datetime]::UtcNow.ToFileTimeUtc())
            $val = [byte[]](@(3, 0, 0, 0) + $ft)
            if (-not $DryRun) {
              if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
              Set-ItemProperty -Path $key -Name $a.nombre -Value $val -Type Binary -ErrorAction Stop
              SaveUndo @{ tipo = 'arranque_reg'; clave = $key; nombre = $a.nombre; previo = $previo }
            }
            Log "$tag desactivado (no borrado): $($a.nombre)  [$($a.origen)]  — se reactiva en Administrador de tareas > Inicio" $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
          }
        }
      }

      'desinstalar' {
        $n = $a.nombre
        if (-not (Programa-Instalado $n)) { Log "$tag '$n' ya no está instalado." 'WARN'; $skip++; break }
        if ($DryRun) { Log "$tag desinstalaría '$n' (winget → quiet → uninstall)" 'DRY'; $ok++; break }
        $hecho = $false
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget -and $n -notmatch '["`\r\n]') {
          Log "$tag winget uninstall '$n'…"
          $rc = Run-Timeout $winget.Source "uninstall --name `"$n`" --exact --silent --accept-source-agreements --disable-interactivity" $TimeoutDesinstalarMin
          Start-Sleep 3; $hecho = -not (Programa-Instalado $n); Log "$tag winget rc=$rc instalado_aun=$(-not $hecho)"
        }
        foreach ($campo in 'quiet', 'uninstall') {
          if ($hecho -or -not $a.$campo) { continue }
          $cmd = "$($a.$campo)"
          if ($campo -eq 'uninstall') {   # UninstallString suele ser interactivo: pedir modo silencioso
            if ($cmd -match '(?i)msiexec') { $cmd = ($cmd -replace '(?i)/I\s*\{', '/X{'); if ($cmd -notmatch '(?i)/q') { $cmd += ' /qn /norestart' } }
            elseif ($cmd -notmatch '(?i)/S\b|/silent|/quiet|/VERYSILENT') { $cmd += ' /S' }
          }
          $d = Parse-Desinstalador $cmd
          if (-not $d) {
            Log "$tag BLOQUEADO: el desinstalador del registro no pasó la validación de seguridad y NO se ejecutó: $cmd" 'ERROR'
            Log "$tag   Desinstálalo a mano desde Configuración > Aplicaciones." 'ERROR'
            continue
          }
          Log "$tag $campo -> exe='$($d.exe)' args='$($d.args)'"
          $rc = Run-Timeout $d.exe $d.args $TimeoutDesinstalarMin
          Start-Sleep 3; $hecho = -not (Programa-Instalado $n); Log "$tag $campo rc=$rc instalado_aun=$(-not $hecho)"
        }
        if ($hecho) { SaveUndo @{ tipo = 'desinstalar'; nombre = $n }; Log "$tag '$n' desinstalado." 'OK'; $ok++ }
        else { Log "$tag '$n' sigue instalado. Probablemente su desinstalador pide clics: ábrelo desde Configuración > Aplicaciones." 'ERROR'; $fail++ }
      }

      'servicio_manual' {
        $s = Get-Service -Name $a.nombre -ErrorAction Stop
        if ($s.StartType -eq 'Manual') { Log "$tag $($a.nombre) ya estaba en Manual." 'WARN'; $skip++; break }
        if (-not $DryRun) { Set-Service -Name $a.nombre -StartupType Manual -ErrorAction Stop; SaveUndo @{ tipo = 'servicio'; nombre = $a.nombre; previo = "$($s.StartType)" } }
        Log "$tag $($a.nombre) ($($s.DisplayName)): $($s.StartType) → Manual" $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'plan_energia' {
        $guids = @{ equilibrado = '381b4222-f694-41f0-9685-ff5bb260df2e'; alto = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        $esq = "$($a.esquema)"; if (-not $guids.ContainsKey($esq)) { $esq = 'equilibrado' }
        if ($esq -eq 'alto' -and $esLaptop) { Log "$tag 'alto rendimiento' en laptop no es buena idea; uso 'equilibrado'." 'WARN'; $esq = 'equilibrado' }
        $act = (powercfg /getactivescheme) -replace '.*([0-9a-f-]{36}).*', '$1'
        if (-not $DryRun) { powercfg /setactive $guids[$esq] | Out-Null; SaveUndo @{ tipo = 'energia'; previo = $act } }
        Log "$tag plan → $esq" $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'efectos_visuales' {
        # Conservador: solo transparencia y animaciones. Conserva miniaturas, sombras y suavizado de fuentes.
        $cambios = @(
          @("$HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", 'EnableTransparency', 0, 'DWord'),
          @("$HKCU\Control Panel\Desktop\WindowMetrics", 'MinAnimate', '0', 'String'),
          @("$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", 'TaskbarAnimations', 0, 'DWord'),
          @("$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", 'ListviewAlphaSelect', 0, 'DWord')
        )
        $previo = [ordered]@{}
        foreach ($c in $cambios) {
          $cur = $null; try { $cur = (Get-ItemProperty -Path $c[0] -ErrorAction Stop).($c[1]) } catch {}
          $previo["$($c[0])|$($c[1])"] = $cur
          if (-not $DryRun) { if (-not (Test-Path $c[0])) { New-Item -Path $c[0] -Force | Out-Null }; Set-ItemProperty -Path $c[0] -Name $c[1] -Value $c[2] -Type $c[3] }
        }
        if (-not $DryRun) { SaveUndo @{ tipo = 'visual'; previo = $previo } }
        Log "$tag transparencia y animaciones desactivadas (miniaturas intactas). Aplica al reiniciar sesión." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      'windows_update' {
        if ($DryRun) { Log "$tag buscaría e instalaría actualizaciones (hasta $TimeoutUpdateMin min)" 'DRY'; $ok++; break }
        Log "$tag buscando actualizaciones… (puede tardar; límite $TimeoutUpdateMin min)"
        Start-Service wuauserv -ErrorAction SilentlyContinue
        $job = Start-Job -ScriptBlock {
          try {
            $s = New-Object -ComObject Microsoft.Update.Session
            $r = $s.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0 and Type=''Software''')
            if ($r.Updates.Count -eq 0) { return 'Sin actualizaciones pendientes.' }
            $col = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $r.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u) }
            $d = $s.CreateUpdateDownloader(); $d.Updates = $col; [void]$d.Download()
            $i = $s.CreateUpdateInstaller(); $i.Updates = $col; $res = $i.Install()
            "Instaladas $($col.Count). Resultado=$($res.ResultCode) (2=ok, 3=parcial). Reinicio requerido=$($res.RebootRequired)"
          } catch { "Error: $_" }
        }
        if (Wait-Job $job -Timeout ($TimeoutUpdateMin * 60)) { $msg = Receive-Job $job; Log "$tag $msg" 'OK'; $ok++ }
        else { Log "$tag no terminó en $TimeoutUpdateMin min; Windows Update sigue trabajando en segundo plano. Revisa Configuración > Windows Update." 'WARN'; $skip++ }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
      }

      'sfc' {
        if ($DryRun) { Log "$tag correría sfc /scannow (10–20 min)" 'DRY'; $ok++; break }
        Log "$tag sfc /scannow… (10–20 min)"
        $out = & "$env:SystemRoot\System32\sfc.exe" /scannow 2>&1 | Out-String
        $resumen = ($out -split "`n" | Where-Object { $_ -match 'integrity|integridad|no encontr|did not find|found corrupt|encontró' } | Select-Object -First 2) -join ' '
        Log "$tag $resumen" 'OK'; $ok++
        if ($out -match 'unable to fix|no pudo reparar|could not perform') {
          Log "$tag SFC no pudo reparar todo; corriendo DISM /RestoreHealth (10–30 min)…"
          & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /RestoreHealth | Out-Null
          Log "$tag DISM terminó (rc=$LASTEXITCODE). Reinicia y vuelve a correr sfc si hubo errores." 'OK'
        }
      }

      'defender_escaneo' {
        $tipo = $(if ("$($a.tipo_escaneo)" -eq 'completo') { 'FullScan' } else { 'QuickScan' })
        if ($DryRun) { Log "$tag Start-MpScan -ScanType $tipo" 'DRY'; $ok++; break }
        Update-MpSignature -ErrorAction SilentlyContinue
        if ($tipo -eq 'FullScan') { Start-MpScan -ScanType FullScan -AsJob | Out-Null; Log "$tag escaneo completo iniciado en segundo plano (1–3 h). Revisa Seguridad de Windows." 'OK' }
        else { Start-MpScan -ScanType QuickScan; $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue).Count; Log "$tag escaneo rápido terminado. Detecciones históricas: $det" 'OK' }
        $ok++
      }

      'windows_old' {
        if (-not (Test-Path 'C:\Windows.old')) { Log "$tag no existe C:\Windows.old" 'WARN'; $skip++; break }
        if ($DryRun) { Log "$tag eliminaría C:\Windows.old vía Liberador de espacio" 'DRY'; $ok++; break }
        $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations'
        Set-ItemProperty -Path $vc -Name StateFlags0099 -Value 2 -Type DWord
        $rc = Run-Timeout 'cleanmgr.exe' '/sagerun:99' 30
        Remove-ItemProperty -Path $vc -Name StateFlags0099 -ErrorAction SilentlyContinue
        Log "$tag cleanmgr rc=$rc. Windows.old existe aún: $(Test-Path 'C:\Windows.old')" 'OK'; $ok++
      }

      'hibernacion_off' {
        if ($esLaptop) { Log "$tag es laptop: la hibernación se queda." 'WARN'; $skip++; break }
        if (-not $DryRun) { powercfg /h off | Out-Null; SaveUndo @{ tipo = 'hibernacion' } }
        Log "$tag hibernación desactivada (libera hiberfil.sys). Nota: también desactiva Inicio rápido." $(if ($DryRun) { 'DRY' } else { 'OK' }); $ok++
      }

      default { Log "$tag tipo desconocido; omitido." 'WARN'; $skip++ }
    }
  } catch { Log "$tag ERROR: $_" 'ERROR'; $fail++ }
}

Log "=== FIN: $ok ok · $fail error · $skip omitidas. Log: $logPath · Deshacer: $undoPath ==="
if (-not $DryRun -and (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) { Log 'Windows pide reinicio.' 'WARN' }
exit $(if ($fail) { 1 } else { 0 })
