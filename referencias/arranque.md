# Arranque: qué se queda, qué se va, qué se pregunta

La lista máquina está en `arranque.txt`; el diagnóstico ya etiqueta cada entrada con ella.
Aquí está el **criterio** para las que no tienen etiqueta o cuando la etiqueta no encaja.

## Cómo se desactiva (y por qué así)

**Nunca se borra la entrada.** Se desactiva igual que lo hace el Administrador de tareas > Inicio:
escribiendo en `HKCU\...\Explorer\StartupApproved\Run` (o `\Run32`, `\StartupFolder`). El
programa sigue instalado, la entrada sigue existiendo, y el dueño (o tú) lo reactiva con un clic.
Tareas programadas: `Disable-ScheduledTask`, reversible con `Enable-ScheduledTask`.

## Se queda (no se toca)

- **Antivirus** (Defender, o el de pago vigente).
- **Bandeja de audio** (Realtek, Waves, Dolby, Nahimic): si se quita, a veces deja de sonar la salida
  correcta o se pierden los controles de volumen del teclado.
- **Touchpad / teclado / gráficos** (Synaptics, ELAN, Intel Graphics tray, hotkeys del fabricante).
- **Idioma / IME** (`ctfmon`).
- **Edge "startup boost"** (`msedge --no-startup-window`): es ligero y acelera abrir Edge; inofensivo.
- Todo lo que el dueño dijo que usa **todos los días** en la entrevista, aunque esté en "se va".

## Se va (se desactiva por defecto)

Regla general: **si el programa funciona igual abriéndolo cuando se necesita, no debe arrancar solo.**

- Música / juegos / chat: Spotify, Steam, Epic, Discord, Skype, WhatsApp, Telegram, Slack.
- Videollamadas: Zoom, Teams, Webex. Se abren al hacer clic en el enlace de la reunión; no
  necesitan estar corriendo desde que prende la PC.
- **Updaters**: Adobe (AAM, Acrobat Update, CCXProcess), Java (`jusched`), Apple, Google Update.
  Los programas se actualizan solos al abrirlos.
- Cosas de Microsoft que casi nadie usa: Cortana, Phone Link (YourPhone), Xbox/Game Bar,
  "Send to OneNote".
- Fabricante: HP Message Service, Lenovo Vantage, Dell Digital Delivery, Acer Quick Access,
  MyASUS, CyberLink, WildTangent, Booking.com.
- Gaming/periféricos "RGB": Razer Synapse, iCUE, GeForce Experience, Afterburner, Wallpaper Engine.
- Antivirus que **se va a desinstalar** (Avast, AVG, McAfee, Norton, Avira): su entrada de
  arranque desaparece con la desinstalación; no hace falta tocarla aparte.

## Preguntar

- **Nube** (OneDrive, Dropbox, Google Drive, iCloud): si ahí están sus fotos o documentos, es
  **intocable** — sin arranque no sincroniza y el dueño creerá que perdió archivos. Si no la usa,
  se va.
- **Impresora / escáner** (Epson, Canon, Brother, HP): si imprime o escanea, se queda (algunas
  funciones de escaneo dependen del monitor de estado). Si no tiene impresora, se va.
- **Mouse/teclado** (Logitech Options, etc.): si usa botones programados, se queda.
- **HP Support Assistant / Dell SupportAssist**: traen drivers, pero molestan con avisos. Preguntar.
- **Google Update**: es minúsculo. Se puede quedar.
- **Chrome/Firefox** en arranque: raro; normalmente lo puso una extensión o un "restaurar
  sesión". Preguntar y revisar el navegador.
- **Malwarebytes**: la versión gratis es buen segundo escáner; la de prueba vencida solo estorba.

## Seguridad (revisar antes de cualquier otra cosa)

Bandera roja si aparece en arranque y el dueño no lo instaló a propósito:

- **Acceso remoto**: AnyDesk, TeamViewer, UltraViewer, Supremo, Ammyy, ScreenConnect, RustDesk.
  Patrón típico de fraude: "le llamaron de Microsoft/el banco" y le pidieron instalar esto.
  Si es el caso: desinstalar, cambiar contraseñas del banco/correo **desde otro dispositivo**,
  y avisarle.
- **Ejecutables en `Temp`, `AppData\Local\Temp`, `Descargas`**: los programas legítimos no viven ahí.
- **`powershell`, `wscript`, `mshta`, `rundll32`, `.vbs`, `.bat`, `cmd /c` en una entrada de arranque**:
  casi siempre malware o residuo de uno. Ver la línea completa antes de decidir.
- **Entradas sin nombre o con nombres genéricos** (`update`, `svchost` fuera de `System32`, `Windows Service`).

Si hay bandera de seguridad: **Defender escaneo completo** (`Start-MpScan -ScanType FullScan`)
antes de optimizar, y considerar un escaneo offline (`Start-MpWDOScan`, reinicia la PC).
