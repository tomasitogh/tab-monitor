# Hitos

Cada hito se prueba en la tablet real antes de pasar al siguiente. El MVP es el hito 3.

| Hito | Estado |
|---|---|
| 0. Validaciones (sin código) | 4 de 6 hechas (2026-10-20); faltan Duet y límite de carga |
| 1. Monitor virtual | hecho, probado en la Mac (2026-10-20) |
| 2. Captura y codificación | — |
| 3. Visor Android por cable (MVP) | — |
| 4. Latencia excelente | — |
| 5. Enchufar y usar | — |
| 6. Toque y lápiz (opcional) | — |

## Hito 0: validaciones

Anotá cada resultado acá.

- [x] **El M1 Air acepta un monitor virtual.** `brew install --cask deskpad`, abrirlo, verificar
      que aparece en Ajustes del Sistema › Pantallas y desinstalarlo
      (`brew uninstall --cask deskpad`).
      Resultado: sí (macOS 15.3.2). DeskPad aparece en Ajustes › Pantallas, incluso con un
      monitor externo de 3440×1440 conectado. Desinstalado.
- [x] **adb ve la tablet.** `adb devices` la muestra como `device` (no `unauthorized`).
      Resultado: `HA1QVH2T device` (Lenovo TB-J706F, USB).
- [x] **Versión de Android.** `adb shell getprop ro.build.version.release`
      Resultado: Android 11.
- [x] **El decoder soporta 2560×1600 a 60 fps.**
      ```
      adb shell 'cat /vendor/etc/media_codecs*.xml' | grep -A12 'video/avc' | grep -iE 'name=|size|frame-rate|performance'
      ```
      Resultado: sí, justo. Decoder de hardware `c2.qti.avc.decoder` (alias
      `OMX.qcom.video.decoder.avc`):
      ```
      <Limit name="size" min="96x96" max="4096x2160" />
      <Limit name="blocks-per-second" range="24-979200" />
      <Limit name="frame-rate" range="1-240" />
      <Limit name="performance-point-3840x2160" value="30" />
      <Limit name="performance-point-1920x1080" value="120" />
      measured-frame-rate-1920x1088: 189-301   (media_codecs_performance.xml)
      ```
      2560×1600 a 60 = 160×100 macrobloques × 60 = 960 000 bloques/s, el 98 % del tope declarado
      (979 200). Lo medido a 1920×1088 (189 fps o más) equivale a unos 96 fps o más a 2560×1600.
      Se arranca con 2560×1600 a 2×; 1920×1200 a 1× queda de reserva si en la práctica no llega.
- [ ] **Línea de base de Duet.** Prueba gratis de Duet Display por cable; filmar las dos pantallas
      en cámara lenta (por ejemplo un cronómetro en milisegundos en la Mac) y anotar la latencia
      en docs/latency.md.
      Resultado:
- [ ] **Límite de carga.** ¿Existe en Ajustes › Batería? ¿Cómo se llama?
      Resultado:

Criterio: las cuatro primeras respondidas. Si el decoder no llega a 2560×1600 a 60, se arranca
con el preset 1920×1200 a 1×.

## Hito 1: el monitor virtual

Criterio: "Activar monitor" en el menú crea un monitor de 1280×800 pt a 2× a la derecha de la
MacBook; se arrastran ventanas; al desactivar o salir desaparece y las ventanas vuelven.

Para probarlo:

```
cd mac
swift build
Scripts/make-app.sh --install --open
```

El ícono aparece en la barra de menú. "Activar monitor" debería mostrar el monitor nuevo en
Ajustes del Sistema › Pantallas, a la derecha de la MacBook.

Resultado (2026-10-20, macOS 15.3.2, solo la pantalla de la MacBook): cumple. El monitor
aparece en (1440, 0) a 1280×800 pt y 2560×1600 px, pasan el cursor y las ventanas, y
desaparece al desactivar y con ⌘Q.

Encontrado al probar: con "Duplicar pantallas" activo (heredado de un monitor externo), macOS
metía al monitor nuevo en el espejo y lo hacía principal; la MacBook quedaba a 1280×800 y el
cursor no salía. `DisplayLayout.extend` rompe ese espejo antes de ubicarlo y deja la pantalla
real como principal. Para diagnosticar: `open /Applications/TabMonitor.app --args --activate`
y `/usr/bin/log stream --predicate 'subsystem == "dev.tabmonitor.mac"'` (en zsh, `log` a secas
es un comando interno).

Firma: el certificado Apple Development necesitó el intermedio Apple WWDR CA G3
(apple.com/certificateauthority) en el llavero; sin él `codesign` falla con
errSecInternalComponent y `make-app.sh` cae a firma ad hoc.
