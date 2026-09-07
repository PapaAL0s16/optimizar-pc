---
name: optimizar-pc
description: >
  Optimiza una PC con Windows de forma segura y conservadora, pensada para la computadora
  de una persona no técnica (papá, mamá, abuelos). Diagnostica primero, propone un plan,
  espera aprobación y ejecuta con punto de restauración y registro de "deshacer".
  Úsala cuando digan "optimizar la PC", "la compu está lenta", "limpiar la computadora",
  "tarda en prender", "quitar basura", o cuando quieran dejar rápida una PC ajena sin romper nada.
---

# /optimizar-pc — Optimización segura de una PC ajena

Eres un técnico cuidadoso trabajando en la computadora de alguien que **no es técnico**.
Tu prioridad, en este orden: **(1) no romper nada que la persona use, (2) no perder datos,
(3) que quede más rápida.** La persona no debe notar ningún cambio excepto la velocidad.

Quien te habla es el familiar/técnico que está frente a la PC, no el dueño. Él aprueba.

## Dónde están los scripts

Los scripts viven junto a este archivo: `scripts/00_diagnostico.ps1`, `scripts/01_aplicar.ps1`,
`scripts/02_verificar.ps1`. Localiza la carpeta de la skill así (usa la primera que exista):

```powershell
$skill = @("$env:USERPROFILE\.claude\skills\optimizar-pc", ".\.claude\skills\optimizar-pc") |
  Where-Object { Test-Path "$_\SKILL.md" } | Select-Object -First 1
```

Toda la salida va a `$env:USERPROFILE\Desktop\OptimizarPC\` (crea la carpeta si no existe).
Ahí quedan: `diagnostico.json`, `resumen.txt`, `plan.json`, `aplicar.log`, `deshacer.json`,
`verificar_pre.json`, `verificar_post.json`, `reporte.md`, `LEEME.txt`.

## Cómo correr un script con Administrador

La shell de Claude Code no está elevada. Cada script se lanza así (dispara **un** aviso de UAC;
pídele al usuario que dé clic en "Sí"):

```powershell
$out = "$env:USERPROFILE\Desktop\OptimizarPC"
# Ruta completa a propósito: tiene que ser Windows PowerShell 5.1, NO pwsh 7
# (PowerShell 7 no trae Checkpoint-Computer y no podría crear el punto de restauración).
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
Start-Process $ps -Verb RunAs -Wait -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$skill\scripts\00_diagnostico.ps1`"","-OutDir","`"$out`""
)
```

Después lee los archivos que dejó en `$out`. Si el script termina en menos de 3 segundos,
el usuario canceló el UAC — pregúntale y reintenta. **Máximo 3 elevaciones en toda la sesión**
(diagnóstico, aplicar, verificar). No lances comandos elevados sueltos.

---

## Paso 1 — Diagnóstico (solo lectura, ~2–5 min)

Corre `00_diagnostico.ps1`. Ese script también toma la medición base "pre" y la escribe como
`verificar_pre.json` (no hace falta elevar aparte). Lee `resumen.txt` completo y `diagnostico.json`.
Las entradas de `programas[]` y `arranque[]` ya vienen pre-etiquetadas con `referencias/pups.txt`
y `referencias/arranque.txt`; la etiqueta es una sugerencia, el criterio final es tuyo.

Con eso emite **un veredicto de hardware antes de cualquier otra cosa**, textual, al usuario:

| Hallazgo en `diagnostico.json` | Qué dices |
|---|---|
| `veredicto.smart_alerta = true` o `errores.disco > 0` | 🔴 "El disco tiene errores. **Antes de tocar nada hay que respaldar fotos y documentos.** Si no hay respaldo, lo hacemos ahora y paramos aquí." No continúes sin confirmación explícita de respaldo. |
| `veredicto.disco_sistema_hdd = true` | 🟠 "El disco del sistema es mecánico (HDD). Voy a limpiar y va a mejorar, pero el arreglo real es un **SSD** (SATA 480 GB, ~$500–700 MXN; se clona con Macrium Reflect Free). Ningún ajuste de software se acerca a eso." |
| `ram.total_gb <= 4` | 🟠 "Tiene 4 GB de RAM. Con Chrome abierto ya está al límite. Voy a ser agresivo con arranque y extensiones; considera subir a 8 GB." |
| `sistema.uptime_dias >= 7` | "Lleva N días sin reiniciar de verdad. 'Apagar' en Windows no reinicia el sistema; hoy reiniciamos y le enseñas a usar 'Reiniciar' una vez por semana." |
| `sistema.fuera_de_soporte = true` | ⚠️ "Windows 10 dejó de recibir parches de seguridad en oct 2025. No lo cambio yo, pero te digo si es elegible para Windows 11 (`sistema.win11_elegible`)." |
| Nada de lo anterior | 🟢 "El hardware está bien. Es software; esto se arregla hoy." |

## Paso 2 — Entrevista (5 preguntas, lenguaje simple)

Haz las cinco de una vez, en una sola pregunta al usuario:

1. ¿Qué siente lento? (prender / abrir programas / navegar / todo / se congela)
2. ¿Para qué usa la PC? (navegador, Office, Zoom/WhatsApp, fotos, banco, impresora, algún programa de trabajo)
3. ¿Qué programas abre él/ella **todos los días**?
4. ¿Sus fotos y documentos tienen respaldo?
5. ¿Instaló algo a propósito que parezca raro? (antivirus pagado, programa de control remoto, etc.)

Guarda las respuestas. Todo lo mencionado en la 3 y la 5 es **intocable** salvo que el usuario diga lo contrario.

## Paso 3 — Análisis

Cruza `diagnostico.json` con la entrevista y `referencias/pups.txt` + `referencias/arranque.md`.
Cada hallazgo se convierte en una acción con **qué / por qué (evidencia) / nivel / cómo se revierte**.

Orden del razonamiento (cada nodo puede cortar lo que sigue):

1. **Seguridad primero.** Si `red.proxy_activo`, `red.hosts_modificado`, procesos desde `AppData`/`Temp`
   sin firma, tareas programadas apuntando a `AppData`, o herramientas de acceso remoto
   (AnyDesk, TeamViewer, UltraViewer, Supremo, Ammyy) que el dueño **no** instaló a propósito →
   dilo explícitamente: puede ser un fraude de "soporte técnico". Prioridad sobre todo lo demás.
2. **Antivirus.** Dos o más productos, o uno de tercero vencido (`antivirus.productos` con `actualizado=false`)
   → desinstalar el tercero; Defender se activa solo al quitarlo. Si el dueño paga uno vigente, se queda.
3. **PUPs / bloatware.** Todo `programas[]` con `etiqueta = PUP` → proponer desinstalar, con nombre,
   editor y fecha como evidencia. `etiqueta = PREGUNTAR` → pregúntale al usuario. `SE_QUEDA`
   (drivers, runtimes, Office) → ni lo menciones. Sin etiqueta y desconocido para ti → **no se toca**.
4. **Disco.** Si `discos.volumen_c.libre_pct < 15` → limpieza con tamaños. Objetivos seguros:
   Temp de usuario y Windows, `SoftwareDistribution\Download`, Papelera, cachés de navegador
   (solo con el navegador cerrado), `C:\AMD|NVIDIA|Intel`, Windows Error Reporting.
   **`Descargas`, `Documentos`, `Escritorio`, `Imágenes`: solo se reporta el tamaño. Jamás se borra.**
   `Windows.old` es nivel 3: solo si el disco está crítico y el usuario lo confirma por separado.
5. **Arranque.** Aplica `referencias/arranque.md`: lo que está en "se queda" no se toca; lo de "se va"
   se desactiva (no se borra: se desactiva vía StartupApproved, igual que el Administrador de tareas,
   reversible con un clic); lo de "preguntar" se pregunta. Entradas desconocidas → se preguntan.
6. **Servicios.** Solo a **Manual**, nunca deshabilitar. Solo servicios de terceros claramente
   identificables (updaters, Adobe, Apple, TeamViewer, etc.). Nunca servicios de Microsoft,
   antivirus, audio, red, impresión.
7. **Energía.** Laptop en "Economizador" o desktop en "Ahorro" → "Equilibrado". No uses "Alto
   rendimiento" en laptop (calienta y gasta batería).
8. **Efectos visuales.** Solo transparencia y animaciones. **Nunca "mejor rendimiento"** (quita
   las miniaturas de fotos y la persona lo nota de inmediato).
9. **Navegador.** Si el buscador no es Google/Bing o hay extensiones sospechosas → **no lo hagas por
   script**. Guía al usuario a hacerlo en 3 clics: `chrome://settings/searchEngines`,
   `chrome://extensions`, y `chrome://settings/onStartup` (quitar "continuar donde lo dejé" si
   restaura 40 pestañas). Chrome protege sus preferencias y las revierte si un script las toca.
10. **Windows Update.** Si hay pendientes o está atorado → se incluye `windows_update` en el plan
    (fuerza búsqueda e instalación; puede tardar). Nunca se deshabilita.
11. **Térmico.** `termico.temp_c > 85` en reposo o clock actual < 60 % del máximo → pendiente manual:
    limpiar polvo / cambiar pasta. No hay fix por software.

### Lo que esta skill NUNCA hace

- Tweaks de registro "de rendimiento" (timer resolution, `bcdedit`, Nagle, HAGS, MPO): placebo o daño.
- Deshabilitar Windows Update, Defender, Windows Search, Security Center, o SysMain en HDD.
- Debloat masivo de apps de Store (Fotos, Calculadora, Correo): la persona las usa.
- Instalar "limpiadores", "optimizadores" o "actualizadores de drivers". **Son la enfermedad.**
- Cambiar navegador, buscador por script, escritorio, apps por defecto, OneDrive si él lo usa.
- Borrar archivos de usuario. Nunca. Ni con permiso: lo hace el usuario a mano.
- Tocar pagefile, hibernación en laptop, UAC.
- Actualizar a Windows 11 o cambiar de edición.
- Ejecutar nada que no esté en `plan.json` aprobado.

## Paso 4 — Propuesta y aprobación

Escribe el plan en `$out\plan.json` (formato abajo) **y** muéstralo al usuario así:

```
PLAN — [fecha]   Perfil: [uso principal]   Veredicto hardware: [🟢/🟠/🔴 + una línea]

BLOQUE A — Riesgo cero, reversible al instante   (apruebas todo junto)
  A1 Limpiar temporales y papelera          ~X GB    [deshacer: no aplica, es basura]
  A2 Desactivar del arranque: Spotify       ~180 MB  [deshacer: Administrador de tareas > Inicio]
  A3 Plan de energía → Equilibrado                   [deshacer: automático en deshacer.json]
  ...

BLOQUE B — Reversible con esfuerzo   (apruebas UNO POR UNO)
  B1 Desinstalar "Driver Booster 11" (IObit, 2024)   motivo: optimizador falso, consume CPU   [reinstalable]
  B2 Desinstalar "McAfee LiveSafe" vencido            motivo: pelea con Defender                [reinstalable]
  B3 Servicio "Adobe Update Service" → Manual                                                  [deshacer: automático]
  ...

NO TOCO (y por qué)
  - OneDrive: ahí están sus fotos
  - HP Support Assistant: trae drivers de la impresora
  ...

PENDIENTES MANUALES (no los hace la skill)
  - SSD / RAM / limpiar polvo / Windows 11 / buscador del navegador (te guío)
```

**Espera respuesta explícita.** Bloque A: un "sí" lo aprueba completo. Bloque B: el usuario
puede decir "todo B" o listar ids ("B1, B3"). Quita del `plan.json` lo que no aprobó.
**Nada se ejecuta antes de esto.**

### Formato de `plan.json`

```json
{
  "fecha": "2026-09-06T17:00:00",
  "acciones": [
    { "id": "A1", "tipo": "limpiar_temp",        "nivel": 1, "motivo": "3.2 GB en temporales" },
    { "id": "A2", "tipo": "vaciar_papelera",     "nivel": 1, "motivo": "1.1 GB" },
    { "id": "A3", "tipo": "limpiar_wu_cache",    "nivel": 1, "motivo": "2.4 GB en SoftwareDistribution" },
    { "id": "A4", "tipo": "limpiar_cache_navegador", "nivel": 1, "navegadores": ["Chrome","Edge"], "motivo": "1.8 GB" },
    { "id": "A5", "tipo": "desactivar_arranque", "nivel": 1, "origen": "reg", "ruta": "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", "nombre": "Spotify", "motivo": "no se necesita al iniciar" },
    { "id": "A6", "tipo": "desactivar_arranque", "nivel": 1, "origen": "carpeta", "nombre": "Send to OneNote.lnk", "motivo": "…" },
    { "id": "A7", "tipo": "desactivar_arranque", "nivel": 1, "origen": "tarea", "nombre": "\\Adobe Acrobat Update Task", "motivo": "…" },
    { "id": "A8", "tipo": "plan_energia",        "nivel": 1, "esquema": "equilibrado", "motivo": "estaba en Economizador" },
    { "id": "A9", "tipo": "efectos_visuales",    "nivel": 1, "motivo": "quita transparencia y animaciones; conserva miniaturas" },
    { "id": "B1", "tipo": "desinstalar",         "nivel": 2, "nombre": "Driver Booster 11", "motivo": "PUP", "uninstall": "…de programas[].uninstall…", "quiet": "…programas[].quiet…" },
    { "id": "B2", "tipo": "servicio_manual",     "nivel": 2, "nombre": "AdobeUpdateService", "motivo": "…" },
    { "id": "B3", "tipo": "windows_update",      "nivel": 2, "motivo": "14 actualizaciones pendientes" },
    { "id": "B4", "tipo": "sfc",                 "nivel": 2, "motivo": "errores de sistema en el log" },
    { "id": "C1", "tipo": "windows_old",         "nivel": 3, "motivo": "18 GB, disco al 6 %" }
  ]
}
```

Copia `uninstall` y `quiet` **literal** desde `diagnostico.json → programas[]`. Para `desactivar_arranque`
copia `origen`, `ruta` y `nombre` literal desde `diagnostico.json → arranque[]`.

## Paso 5 — Ejecución

Corre `01_aplicar.ps1 -Plan "$out\plan.json" -OutDir "$out"`. El script:
crea punto de restauración → exporta Run keys y servicios a `deshacer.json` → ejecuta en orden de
menor a mayor riesgo → escribe `aplicar.log`. Si el punto de restauración falla, el script se detiene
y lo reporta; pregunta al usuario si continuar y relanza con `-SinPuntoRestauracion` solo si acepta.

Cuando termine, lee `aplicar.log` y di qué se hizo y qué falló (los desinstaladores a veces piden
interacción; si alguno quedó abierto, pídele al usuario que lo termine).

Luego pide **reiniciar**. Si acepta: `shutdown /r /t 30 /c "Reinicio de optimización"`. Dile que
vuelva a abrir Claude y escriba `/optimizar-pc verificar`.

## Paso 6 — Verificación y reporte

Al volver (o si el usuario dice "verificar"): espera 2 minutos desde el arranque
(`sistema.uptime` en el nuevo diagnóstico, o simplemente pregunta) y corre
`02_verificar.ps1 -Etiqueta post -OutDir "$out"`. El script compara con `verificar_pre.json` y
escribe `reporte.md` con la tabla antes/después.

Muestra la tabla y escribe `$out\LEEME.txt` **tú**, para el dueño de la PC, en español simple, con:

```
QUÉ SE HIZO EN TU COMPUTADORA — [fecha]
Lo hizo: [nombre del usuario] con ayuda de Claude.

- Se limpiaron X GB de archivos basura.
- Se quitaron del arranque: [lista corta]. Por eso prende más rápido.
- Se desinstaló: [lista]. Eran programas que la hacían lenta / ya no servían.
- [si aplica] Se quitó el antivirus vencido. Windows Defender la protege ahora, sin pagar nada.

RESULTADO
  Prende en:   X seg  →  Y seg
  Espacio libre: X GB →  Y GB

SI ALGO FALLA: llama a [usuario]. Existe un punto de restauración llamado "OptimizarPC [fecha]".

PENDIENTES (necesitan comprar / abrir la máquina): [SSD, RAM, limpieza de polvo…]

CONSEJO: una vez por semana usa "Reiniciar", no "Apagar".
```

## Deshacer

Si algo se rompió: `01_aplicar.ps1 -Deshacer "$out\deshacer.json" -OutDir "$out"` restaura arranque,
servicios, plan de energía y efectos visuales. Las desinstalaciones no se deshacen automáticamente:
reinstala el programa. Como último recurso: Punto de restauración "OptimizarPC [fecha]".
