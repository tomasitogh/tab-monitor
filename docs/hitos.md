# Hitos

Cada hito se prueba en la tablet real antes de pasar al siguiente. El MVP es el hito 3.

| Hito | Estado |
|---|---|
| 0. Validaciones (sin código) | 5 de 6 hechas (2026-10-20); falta medir Duet |
| 1. Monitor virtual | hecho, probado en la Mac (2026-10-20) |
| 2. Captura y codificación | hecho, probado en la Mac (2026-10-20) |
| 3. Visor Android por cable (MVP) | hecho, probado en la tablet (2026-10-21) |
| 4. Latencia excelente | hecho (2026-10-21): ~49 ms en pantalla en Rápida; picos ocasionales por adb |
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
- [x] **Límite de carga.** ¿Existe en Ajustes › Batería? ¿Cómo se llama?
      Resultado: sí, "Modo de protección de la batería": mantiene la carga entre 40 % y 60 %.

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

## Hito 2: captura y codificación

Criterio: con una conexión de prueba, la Mac transmite el monitor virtual en H.264 según
PROTOCOL.md, con el tiempo de captura más codificación medido y anotado en docs/latency.md.

Para probarlo:

```
cd mac
swift test
Scripts/make-app.sh --install --open
Scripts/view-stream.py --no-view --save /tmp/prueba.h264   # hace de tablet; Ctrl-C para cortar
```

Resultado (2026-10-20): cumple. 2560×1600, H.264 High 5.1 sin B-frames (lo confirma ffprobe),
50–57 fps, captura más codificación de 6–7 ms de promedio (p95 13–15 ms), sin frames descartados
al enviar. Los cuadros decodificados del stream grabado muestran el monitor virtual nítido.
Detalle en docs/latency.md.

Encontrado al probar:
- El `displayTime` de ScreenCaptureKit puede quedar en el futuro; restarlo sin signo hacía
  crashear la app por overflow.
- Hace falta el permiso de Grabación de pantalla. Con la firma Apple Development no se vuelve a
  pedir tras cada compilación.
- Al recrear el monitor (mismo vendor, producto y número de serie), macOS devuelve ahí las
  ventanas que estuvieron en él antes. Sin la tablet mostrándolo, quedan invisibles hasta que se
  desactiva. Con la tablet es lo deseable.
- ffplay lanzado en segundo plano desde una shell no activa su ventana: para verlo en vivo hay
  que correr `Scripts/view-stream.py` desde una terminal propia.
- Un proceso lanzado con `&` en una shell no interactiva ignora SIGINT: cortar el cliente de
  prueba con SIGTERM.

## Hito 3: visor Android por cable (MVP)

Criterio: la tablet muestra el monitor virtual nítido, se arrastran ventanas y se ven fluidas,
y al cerrar el visor el monitor desaparece de la Mac. Latencia de punta a punta medida.

Para probarlo:

```
cd android
./gradlew testDebugUnitTest assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb reverse tcp:8081 tcp:8081
adb shell am start -n dev.tabmonitor/.MainActivity
adb logcat -s TabMonitor
```

Con la TabMonitor de la Mac abierta. Un toque en la tablet muestra fps, latencia, decode y ping.

Resultado (2026-10-21): cumple. Se ve nítido a 2560×1600 y es usable para escribir. Latencia de
punta a punta de 35–50 ms de promedio en uso real, con picos (detalle en docs/latency.md).

Encontrado al probar:
- El decoder que elige Android (`c2.qti.avc.decoder`) retiene un frame; `OMX.qcom.video.decoder.avc`
  con `vendor.qti-ext-dec-low-latency.enable` no. Para comparar:
  `adb shell am start -S -n dev.tabmonitor/.MainActivity --es decoder c2.qti.avc.decoder`.
- El decoder decide cuántos frames retener por el SPS: la Mac pide 1 referencia y sin LTR.
- `OnFrameRenderedListener` devuelve horas falsas en `c2.qti`; se mide al soltar el buffer.
- Una reconexión rápida podía cortar la transmisión nueva por el error de un arranque viejo.
- El SDK de Android se instaló con `brew install --cask android-commandlinetools` y `sdkmanager`
  (plataforma 35, build-tools 35); Gradle corre con el JDK de Android Studio.
- Al conectar, el decoder todavía no arrancó y llegan más de 3 frames: se tiran y se pide un
  keyframe (un aviso en el log, sin efecto visible).

## Hito 4: latencia excelente

Resultado (2026-10-21): cerrado con estos números (detalle en docs/latency.md).

| | Nítida (2560×1600) | Rápida (1920×1200) |
|---|---|---|
| Al soltar el frame en la tablet, a 60 fps | 45–47 ms (p95 58–62) | 25–29 ms (p95 35–49) |
| En pantalla (+25 ms de SurfaceFlinger) | ~70 ms | ~50 ms |
| Uso real, 6 minutos | — | ~49 ms de promedio en pantalla |

Hecho en este hito: captura que nunca espera al encoder, calidad Nítida/Rápida en el menú,
`releaseOutputBuffer` con la hora de la tablet, y medición de cada tramo (llegada, decode y
pantalla con SurfaceFlinger).

No cumple "nunca más de 80 ms": quedan picos ocasionales de 100–140 ms en el transporte de adb.
El `adbd` de Android 11 no tiene `delayed_ack` y espera un OKAY por cada frame; si `adbd` tarda
en despertarse, los frames se acumulan en el servidor de adb de la Mac. Un latido de 100 ms y
`ADB_LIBUSB` no los sacan.

### Posible paso siguiente: Android Open Accessory (no planificado)

Reemplazar `adb reverse` por AOA: USB directo con endpoints bulk, sin `adbd` en el camino.

- Gana: sin la espera de un OKAY por frame, deberían desaparecer los picos y quizá bajar algunos
  ms el promedio. Además Android puede abrir el visor solo al enchufar (filtro de accesorio),
  lo que también sirve para "enchufar y usar".
- Cuesta: en la Mac, el handshake de AOA y las transferencias bulk con IOKit (IOUSBHost), sin
  dependencias; en Android, `UsbManager`/`UsbAccessory` y un aviso de permiso la primera vez
  (se puede marcar "siempre"). La tablet se reenumera como accesorio (VID 0x18D1, PID
  0x2D00/0x2D01), lo que puede convivir con adb o no según el modo.
- Cómo empezar: una prueba mínima que mande frames por AOA y mida la llegada contra adb, antes
  de tocar la app.

