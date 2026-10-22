# Traspaso

Para retomar el desarrollo en otra sesión o cuenta. Estado al 2026-10-21.

## Dónde está todo

- Todo en `main` (el PR #1 con los hitos 0 a 5 ya está mergeado). El repo no tiene CI.
- Distribución: cask en el tap `tomasitogh/homebrew-tap`, zip en los GitHub Releases de este
  repo, publicado con `mac/Scripts/release.sh` (hito 7).
- [CLAUDE.md](../CLAUDE.md): arquitectura, comandos y reglas no negociables.
- [docs/hitos.md](hitos.md): qué se hizo en cada hito, cómo probarlo y lo encontrado al probar.
- [docs/latency.md](latency.md): cada cambio de latencia con su medición antes y después, y
  lo que se probó sin efecto (no repetirlo).
- [docs/setup.md](setup.md): preparar una Mac desde cero.
- [PROTOCOL.md](../PROTOCOL.md): los mensajes, con bytes de ejemplo que usan los tests de las
  dos puntas.

## Estado

| Hito | Estado |
|---|---|
| 0. Validaciones | 5 de 6: falta la medición de Duet (la hace el usuario) |
| 1. Monitor virtual | hecho |
| 2. Captura y codificación | hecho |
| 3. Visor Android (MVP) | hecho |
| 4. Latencia | hecho: ~49 ms en pantalla en Rápida, ~70 ms en Nítida; picos por adb |
| 5. Enchufar y usar | hecho: con TabMonitor abierta, enchufar la tablet y anda sola |
| 6. Toque y lápiz | opcional, sin empezar |
| 7. Distribución con Homebrew | hecho: v0.1.0 publicada en el tap |

Funciona en el uso diario del usuario. Tests: 6 en la Mac (`swift test`), 7 en Android
(`./gradlew testDebugUnitTest`).

## Pendientes

- **Del usuario**: medir Duet Display por cable (filmación en cámara lenta) y anotarlo en
  docs/latency.md; confirmar que "Abrir al iniciar sesión" abre TabMonitor tras reiniciar la Mac.
- **Decisión del usuario**: mergear el PR #1.

No hay trabajo técnico pendiente dentro de los hitos 0–5. Lo que sigue lo elige el usuario.

## Estacionado (no empezar sin que el usuario lo pida)

El usuario fue explícito: después del hito 5 no avanzar con estos temas hasta que él diga.

- **Otras tablets y otros tamaños.** Hoy todo asume la P11 Pro:
  - El monitor virtual es siempre 1280×800 pt a 2× (`mac/Sources/TabMonitor/App.swift`,
    `widthPt`/`heightPt`); debería salir del `hello` de cada tablet.
  - `Decoder.decoderName` prefiere `OMX.qcom.video.decoder.avc`; con MediaTek o Exynos el decoder
    por defecto podría retener frames como `c2.qti` (medirlo con el patrón a 10 fps, ver abajo).
  - La calidad (Nítida/Rápida) no se elige según `maxDecode` del `hello`.
  - Identidad del monitor (vendor/product/serial) fija: debería ser una por tablet para que
    macOS recuerde dónde va cada una.
  - Una tablet a la vez (la primera autorizada en adb).
- **Distribución, lo que falta después del hito 7.** Developer ID + notarización (Apple
  Developer Program, pago) para sacar el aviso de Gatekeeper; build universal para Intel;
  releases desde CI.
- **Android Open Accessory** para sacar los picos de adb: detalle en docs/hitos.md, hito 4.
- **Visor más liviano**: leer el socket directo al buffer del codec (SocketChannel) ahorraría
  ~10 % de CPU de la tablet.

## Recetas de diagnóstico

- Ver qué pasa: logs de las dos puntas (comandos en CLAUDE.md). La línea `stats` de la Mac da
  llegada de la captura, captura+codificación, encoder, envío, salteados y descartados; la de la
  tablet da latencia al soltar, llegada (Mac + transporte), decode y ping.
- Latencia controlada: un patrón animado dentro del monitor virtual, por ejemplo
  `ffplay -f lavfi -i testsrc2=size=640x400:rate=10 -left 2000 -top 300 -noborder`
  (x ≥ 1440 cae en el monitor virtual, que está a la derecha de la MacBook). `rate=10` separa
  retención de frames (el decode sube a ~100 ms) de falta de capacidad; `rate=60` es el peor caso.
- Elegir decoder a mano:
  `adb shell am start -S -n dev.tabmonitor/.MainActivity --es decoder c2.qti.avc.decoder`.
- Abrir el monitor sin el menú: `open /Applications/TabMonitor.app --args --activate`.
- Banco de VideoToolbox: se usó un programa aparte con frames sintéticos de 2560×1600 para
  comparar configuraciones del encoder; los resultados están en docs/latency.md.

## Cuidados al probar

- Al crear el monitor, macOS devuelve ahí las ventanas que estuvieron antes en él (incluida la
  de la sesión de Claude). Sin la tablet mostrándolo quedan invisibles hasta desactivarlo.
- No lanzar apps con ventana (ffplay como visor) en segundo plano desde la shell: no se activan y
  quedan fuera de pantalla. ffplay con `-left/-top` para patrones sí funciona.
- Un proceso lanzado con `&` desde una shell no interactiva ignora SIGINT: cortarlo con SIGTERM.
- Si "Duplicar pantallas" quedó activo (por un monitor externo), macOS mete al monitor virtual en
  el espejo; `DisplayLayout.extend` lo saca.
- `OnFrameRenderedListener` miente en esta tablet; el tramo de pantalla se mide con
  `dumpsys SurfaceFlinger --latency`.

## Forma de trabajo con el usuario

- Habla en español rioplatense; todo (código, comentarios, docs, commits) va en español.
- Un hito o tema a la vez. Antes de empezar algo nuevo, proponer el plan y esperar el OK.
- Lo físico (enchufar, tocar la tablet, aceptar permisos, reiniciar, mirar la pantalla) se le
  pide explícitamente y se espera su respuesta. Se le dan pasos concretos y numerados.
- Se prueba primero, después se anota en docs/hitos.md y docs/latency.md, y recién con su OK se
  hace commit y push.
- Prefiere decisiones apoyadas en mediciones: medir antes y después, decir con honestidad lo que
  no mejoró y descartarlo (queda anotado en docs/latency.md).
- Le importa que la app sea liviana en la Mac y en la tablet.
