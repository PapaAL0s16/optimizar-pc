# Seguridad

Esta skill corre PowerShell como **Administrador** y modifica el sistema. Este documento
dice exactamente qué hace, qué no hace, y dónde está el riesgo real.

## Qué toca y qué no

| | |
|---|---|
| **Ejecuta como Administrador** | Solo `00_diagnostico.ps1` (lectura) y `01_aplicar.ps1` (cambios). Nada más. |
| **Sale a internet** | Solo `i.ps1`, y solo a `github.com`. Los tres scripts de la skill **no hacen ninguna conexión de red**: no descargan, no suben, no telemetría. |
| **Archivos del usuario** | **Nunca los borra.** Documentos, Escritorio, Descargas, Imágenes y OneDrive solo se miden para reportar tamaño. |
| **Borrado** | Restringido por lista blanca a: `%TEMP%`, `C:\Windows\Temp`, caché de Windows Update, WER, `C:\AMD\|NVIDIA\|Intel`, cachés de navegador. Cualquier ruta fuera de esa lista se registra como `BLOQUEADO` y no se toca. |
| **Registro** | Solo las claves de `StartupApproved` (las mismas que usa el Administrador de tareas), transparencia/animaciones y el punto de restauración. Validado contra lista blanca; una clave fuera de ella se rechaza. |
| **Arranque** | Se **desactiva**, no se borra. Se revierte con un clic en Administrador de tareas → Inicio. |
| **Servicios** | Solo pasan a **Manual**, nunca a Deshabilitado. Nunca servicios de Microsoft, antivirus, audio, red o impresión. |
| **Antes de cambiar nada** | Punto de restauración + exportación de las claves `Run` + inventario de servicios. |
| **Deshacer** | `01_aplicar.ps1 -Deshacer` revierte arranque, servicios, energía y efectos visuales. |

## Riesgos conocidos, y qué se hizo con ellos

### 1. `irm ... | iex` ejecuta código sin verificarlo — riesgo aceptado
El instalador de una línea confía en que el repo no ha sido alterado. Si la cuenta de GitHub
fuera comprometida, quien instale ejecuta lo que el atacante haya puesto. No hay forma de
evitarlo con código dentro del propio repo. Mitigaciones:

- **Lee el script antes de ejecutarlo.** Son ~60 líneas: <https://github.com/PapaAL0s16/optimizar-pc/blob/main/i.ps1>
- **Fija una versión** en lugar de `main`, para que un cambio futuro no te llegue solo:
  ```powershell
  irm github.com/PapaAL0s16/optimizar-pc/raw/v1.0.0/i.ps1 | iex
  ```
- El dueño del repo debe tener **2FA activo** y **protección de rama** en `main`.
- `i.ps1` **no pide Administrador** y solo escribe dentro de `%USERPROFILE%\.claude\skills\`.
  Verifica la ruta de destino antes de borrar nada y aborta si no es la esperada.

### 2. Inyección de comandos por el desinstalador del registro — corregido
El `UninstallString` del registro lo escribe cada programa que se instala, así que un
instalador malicioso podría dejar ahí algo como `unins.exe & malware.exe`. Antes ese texto
se pasaba a `cmd.exe /c`, que lo habría ejecutado como Administrador.

Ahora se parsea en ejecutable + argumentos, se rechaza cualquier cosa con metacaracteres
de shell (`& | ; ` < > ^ $(`), se comprueba que el ejecutable exista, y se lanza con
`Start-Process` **sin shell**. Lo que no pasa la validación no se ejecuta: se registra y
se le pide al usuario desinstalarlo a mano.

### 3. `plan.json` y `deshacer.json` viven en el Escritorio — mitigado
Los lee un proceso elevado, así que quien pueda escribirlos influye en lo que se ejecuta.
Por eso las rutas de borrado y las claves de registro están en lista blanca dentro del
script: aunque el JSON pida otra cosa, no se hace. Aun así, **revisa el plan antes de
aprobarlo** — Claude te lo muestra completo y espera tu respuesta.

### 4. `diagnostico.json` contiene un inventario completo del equipo
Nombre de PC y usuario, software instalado, entradas de arranque, archivo `hosts`, IPs,
rutas personales. Se queda en el Escritorio y **nunca sale del equipo**, pero:

- No lo subas a un repo, foro, pastebin ni chat público.
- El `.gitignore` de este repo ya lo excluye por si clonas dentro de una carpeta de trabajo.

### 5. `Unblock-File` quita la marca de "descargado de internet"
El instalador lo hace a propósito con los archivos de la skill: sin eso, Windows bloquearía
los `.ps1`. Es la contrapartida de instalar desde internet, y solo aplica a los archivos
de esta skill.

## Cómo revisarlo tú mismo

```powershell
# Ver el diagnóstico completo sin Administrador y sin cambiar nada
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\optimizar-pc\scripts\00_diagnostico.ps1" -Rapido

# Ver exactamente qué haría un plan, sin ejecutarlo (tampoco requiere Administrador)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\optimizar-pc\scripts\01_aplicar.ps1" -Plan "$env:USERPROFILE\Desktop\OptimizarPC\plan.json" -DryRun
```

## Reportar un problema

Abre un issue en <https://github.com/PapaAL0s16/optimizar-pc/issues>. Si crees que es un
fallo de seguridad explotable, márcalo en el título y no publiques detalles que permitan
reproducirlo hasta que esté corregido.
