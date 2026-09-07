<#
  Instala la skill "optimizar-pc" en ~\.claude\skills\optimizar-pc\ desde GitHub.

  Uso (una línea, en cualquier PowerShell, SIN Administrador):
    irm https://raw.githubusercontent.com/PapaAL0s16/optimizar-pc/main/instalar.ps1 | iex

  Para fijar una versión concreta en lugar de la última:
    $env:OPTIMIZARPC_REF='v1.0.0'; irm https://raw.githubusercontent.com/PapaAL0s16/optimizar-pc/v1.0.0/instalar.ps1 | iex

  Este script NO requiere Administrador y NO modifica el sistema: solo copia archivos
  dentro de tu perfil de usuario. Quien optimiza es la skill, después, y pidiendo permiso.
#>
$ErrorActionPreference = 'Stop'
$repo = 'PapaAL0s16/optimizar-pc'
$ref = if ($env:OPTIMIZARPC_REF) { $env:OPTIMIZARPC_REF } else { 'main' }

# TLS 1.2: GitHub lo exige y Windows 10 no siempre lo activa por defecto en PowerShell 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Esta skill es solo para Windows.' }
if (-not $env:USERPROFILE -or -not (Test-Path -LiteralPath $env:USERPROFILE)) { throw 'No pude determinar tu carpeta de usuario (%USERPROFILE%).' }

$skills  = Join-Path $env:USERPROFILE '.claude\skills'
$destino = Join-Path $skills 'optimizar-pc'

# Blindaje: $destino tiene que ser absoluto y terminar exactamente donde esperamos.
# Sin esto, un %USERPROFILE% raro podría convertir el Remove-Item de abajo en algo destructivo.
$destinoFull = [IO.Path]::GetFullPath($destino)
if (-not [IO.Path]::IsPathRooted($destinoFull) -or $destinoFull.Length -lt 20 -or
    -not $destinoFull.EndsWith('\.claude\skills\optimizar-pc', [StringComparison]::OrdinalIgnoreCase)) {
  throw "Ruta de instalación inesperada, cancelo por seguridad: $destinoFull"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("optimizarpc-" + [Guid]::NewGuid().ToString('N'))
$zip = "$tmp.zip"

try {
  Write-Host "Descargando $repo ($ref)..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/heads/$ref.zip" -OutFile $zip -UseBasicParsing

  $sha = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
  Write-Host "  SHA256 del paquete: $sha" -ForegroundColor DarkGray

  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  $raiz = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
  if (-not $raiz) { throw 'El paquete descargado está vacío.' }

  # Verificar que trae lo que debe traer antes de tocar nada en tu perfil
  foreach ($req in 'SKILL.md', 'scripts\00_diagnostico.ps1', 'scripts\01_aplicar.ps1', 'scripts\02_verificar.ps1', 'referencias\pups.txt', 'referencias\arranque.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $raiz.FullName $req))) { throw "El paquete no trae '$req'. Cancelo sin instalar." }
  }

  New-Item -ItemType Directory -Force -Path $skills | Out-Null
  if (Test-Path -LiteralPath $destinoFull) {
    Write-Host "Reemplazando instalación anterior..." -ForegroundColor DarkGray
    Remove-Item -LiteralPath $destinoFull -Recurse -Force
  }
  Copy-Item -LiteralPath $raiz.FullName -Destination $destinoFull -Recurse

  # Windows marca como "bloqueado" todo .ps1 bajado de internet; sin esto no correrían
  Get-ChildItem -LiteralPath $destinoFull -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

  $n = (Get-ChildItem -LiteralPath $destinoFull -Recurse -File).Count
  Write-Host ""
  Write-Host "Skill instalada ($n archivos) en:" -ForegroundColor Green
  Write-Host "  $destinoFull"
  Write-Host ""
  Write-Host "Ahora abre Claude Desktop -> pestana Code y escribe:  /optimizar-pc" -ForegroundColor Yellow
  Write-Host "(si Claude ya estaba abierto, cierralo y vuelve a abrirlo: lee las skills al arrancar)"
  Write-Host ""
  Write-Host "Para revisar que hace antes de usarla:  https://github.com/$repo" -ForegroundColor DarkGray
}
finally {
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
