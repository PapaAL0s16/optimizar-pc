# optimizar-pc

Skill para Claude Code (Claude Desktop → pestaña **Code**) que optimiza una PC con Windows de forma
**conservadora**, pensada para la computadora de alguien no técnico: diagnostica, propone un plan,
espera tu aprobación, ejecuta con punto de restauración y deja un archivo de "deshacer".

## Instalar (un comando, cualquier Windows 10/11)

Abre PowerShell y pega:

```powershell
irm https://raw.githubusercontent.com/PapaAL0s16/optimizar-pc/main/instalar.ps1 | iex
```

Descarga este repo y lo deja en `C:\Users\<usuario>\.claude\skills\optimizar-pc\`.
Volver a correrlo = actualizar. Luego abre Claude Desktop → **Code** y escribe:

```
/optimizar-pc
```

(Si Claude ya estaba abierto, ciérralo y vuelve a abrirlo: lee las skills al arrancar.)

### Alternativas

```powershell
# Con Node instalado
npx skillfish add PapaAL0s16/optimizar-pc

# Con git instalado
git clone https://github.com/PapaAL0s16/optimizar-pc "$env:USERPROFILE\.claude\skills\optimizar-pc"
```

## Qué hace, paso por paso

1. **Diagnóstico** (solo lectura, 1–5 min). Un aviso de Windows pidiendo Administrador → "Sí".
   Claude dice primero si el cuello de botella es hardware (HDD, poca RAM, disco con errores) o software.
2. **5 preguntas**: qué siente lento, para qué se usa, qué programas abre a diario, si hay respaldo,
   si instaló algo raro a propósito.
3. **Plan** en dos bloques: **A** riesgo cero (temp, papelera, arranque, energía) se aprueba junto;
   **B** (desinstalar, servicios) se aprueba uno por uno con su motivo. Nada corre antes.
4. **Ejecución** (segundo y último aviso de Administrador). Primero punto de restauración y respaldo
   de claves de arranque; luego de menor a mayor riesgo; todo a `aplicar.log` + `deshacer.json`.
5. **Reinicio** y **verificación**: tabla antes/después (arranque, RAM, disco, procesos) y un
   `LEEME.txt` en el Escritorio para el dueño de la PC.

Todo queda en `Escritorio\OptimizarPC\`.

## Lo que NUNCA hace

Tweaks de registro "de rendimiento" · deshabilitar Windows Update / Defender · debloat masivo de apps ·
instalar "limpiadores" u "optimizadores" · cambiar navegador o buscador por script · borrar archivos
del usuario · tocar pagefile, hibernación en laptop o UAC · actualizar a Windows 11.

## Seguridad

Corre como Administrador, así que conviene saber qué toca: **[SECURITY.md](SECURITY.md)** lo detalla.
En corto:

- Los scripts de la skill **no hacen ninguna conexión de red**. Solo el instalador habla con GitHub.
- El borrado está limitado por **lista blanca** (temp, cachés, WER). **Nunca** toca archivos del usuario.
- El registro está limitado por lista blanca a `StartupApproved` y transparencia/animaciones.
- Los desinstaladores del registro se ejecutan **sin shell** y se validan antes; si no pasan, no corren.
- Antes de cualquier cambio: punto de restauración + respaldo de claves de arranque + `deshacer.json`.

`irm | iex` ejecuta código sin verificarlo. Son ~60 líneas — [léelas antes](instalar.ps1) — o fija
una versión concreta en vez de `main`:

```powershell
irm https://raw.githubusercontent.com/PapaAL0s16/optimizar-pc/v1.0.0/instalar.ps1 | iex
```

> ⚠️ **`diagnostico.json` (en tu Escritorio) contiene un inventario completo del equipo**: nombre de PC
> y usuario, software instalado, archivo `hosts`, IPs. Nunca sale de la máquina — no lo subas ni lo
> pegues en sitios públicos.

## Si algo salió mal

En Claude: *"deshaz los cambios de optimizar-pc"* → corre `01_aplicar.ps1 -Deshacer`.
Último recurso: Restaurar sistema → punto **"OptimizarPC <fecha>"**.

## Estructura

```
SKILL.md                    instrucciones que sigue Claude (el criterio vive aquí)
instalar.ps1                instalador de una línea
scripts/
  00_diagnostico.ps1        solo lectura → diagnostico.json + resumen.txt
  01_aplicar.ps1            ejecuta plan.json aprobado · -DryRun · -Deshacer
  02_verificar.ps1          medición antes/después → reporte.md
referencias/
  pups.txt                  bloatware / antivirus / acceso remoto / drivers intocables
  arranque.txt / .md        qué se queda, se va, se pregunta en el arranque
```

Compatible con Windows PowerShell 5.1 (el que trae Windows). No requiere Node ni git.

## Probar sin tocar nada

```powershell
$s = "$env:USERPROFILE\.claude\skills\optimizar-pc\scripts"
powershell -ExecutionPolicy Bypass -File "$s\00_diagnostico.ps1" -Rapido                 # sin admin
powershell -ExecutionPolicy Bypass -File "$s\01_aplicar.ps1" -Plan "$env:USERPROFILE\Desktop\OptimizarPC\plan.json" -DryRun
```
