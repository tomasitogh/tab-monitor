# Latencia

Objetivo: promedio menor a 45 ms desde que algo cambia en la Mac hasta que se ve en la tablet,
p95 menor a 60 ms y nunca más de 80 ms durante 10 minutos de uso real.

## Línea de base

| Qué | Promedio | p95 | Máximo | Cómo se midió | Fecha |
|---|---|---|---|---|---|
| Duet Display (prueba gratis), por cable | — | — | — | filmación en cámara lenta | — |

## Presupuesto estimado

| Tramo | Estimación | Medido |
|---|---|---|
| Captura + codificación en la Mac | 8–20 ms | 6–7 ms prom, p95 13–15 ms (2026-10-20) |
| Cable USB con adb | 1–3 ms | — |
| Decodificación en la tablet | 5–15 ms | 17–20 ms (OMX.qcom, 2026-10-21) |
| Mostrar en pantalla | 0–17 ms | — |

## Registro de cambios

Cada cambio que afecte la latencia, con su medición antes y después.

| Fecha | Cambio | Antes (prom / p95) | Después (prom / p95) | Notas |
|---|---|---|---|---|
| 2026-10-20 | Encoder: modo de baja latencia (`EnableLowLatencyRateControl`) con High 5.1 | sin él: 51–69 / 101–103 ms | 11–18 / 19 ms | Banco aparte: frames sintéticos de 2560×1600 con ruido, 60 fps, 35 Mbps. A 30 fps: 12,8 ms en la mediana, o sea que no retiene frames. ConstrainedHigh y Baseline no mejoran. |
| 2026-10-20 | Último frame gana antes del encoder (un frame en vuelo y una ranura con el más nuevo) | 30–44 / ~50 ms | 5–6 / 11–13 ms | Captura + codificación, patrón en parte de la pantalla. `EncodeFrame` bloqueaba la cola de captura. |
| 2026-10-20 | ScreenCaptureKit `queueDepth` 3 → 8 | 18–44 / 46–53 ms | 6–7 / 13–15 ms | Captura + codificación, patrón a pantalla completa. Llegada de la captura: 6–26 ms → 0,3 ms. Con 6 todavía se agotaba el pool. |
| 2026-10-21 | Tablet: decoder `OMX.qcom.video.decoder.avc` en vez de `c2.qti.avc.decoder` | decode 125 ms (a 10 fps) | decode 19 ms | `c2.qti` retiene cada frame hasta que llega el siguiente, aun con SPS de 1 referencia. Con OMX y `vendor.qti-ext-dec-low-latency`, no. |
| 2026-10-21 | Mac: `ReferenceBufferCount` = 1 y `EnableLTR` = false | SPS con 11 referencias y LTR | SPS con 1 referencia, `max_dec_frame_buffering` = 1 | Sin el modo de baja latencia el decoder retenía 11 frames (1,13 s a 10 fps): decide cuánto retener por el SPS. |
| 2026-10-21 | Las dos anteriores juntas, punta a punta | 140–155 / 155–175 ms | 32–38 / 41–48 ms | Patrón a 10 fps; latencia medida en la tablet con el reloj de la Mac. |
| 2026-10-21 | Mac: el encoder recibe frames desde su propia cola, nunca desde la de captura | 105–167 / 174–179 ms | 45–47 / 58–62 ms | Patrón a 60 fps, 2560×1600. `EncodeFrame` bloqueaba ~19 ms y ScreenCaptureKit llegaba a 120 ms de atraso. |
| 2026-10-21 | Calidad "Rápida": se transmite a 1920×1200 y la tablet lo estira | 45–47 / 58–62 ms | 25–29 / 35–49 ms | Patrón a 60 fps. Encoder 19 → 12–13 ms, decode 19 → 14 ms. Opción del menú; "Nítida" (2560×1600) sigue siendo la predeterminada. |
| 2026-10-21 | Probado sin efecto | — | — | Mac: `MaximizePowerEfficiency` = false (ruido); `ExpectedFrameRate` 120 rompe el encoder. Tablet: `KEY_OPERATING_RATE` máximo (decode igual); AUD al final de cada frame y `vendor.qti-ext-dec-picture-order` (no cambian la retención de `c2.qti`). |

## Desglose (hito 4)

2026-10-21, patrón a 60 fps. "Llegada" es la hora en que la tablet terminó de leer el frame, en
el reloj de la Mac, menos el vsync de captura: incluye la Mac y el transporte.

| Tramo | Nítida (2560×1600) | Rápida (1920×1200) |
|---|---|---|
| Captura (vsync → callback) | 0,1–0,2 ms | ~0,1 ms |
| Encoder del M1 | 19 ms (a veces 11–13) | 12–13 ms |
| USB + adb (llegada − captura+codificación en la Mac) | 2–4 ms | 2–4 ms |
| Decode en la tablet | 18–19 ms | 13–14 ms |
| Punta a punta hasta soltar el buffer | 45–47 ms (p95 58–62) | 25–29 ms (p95 35–49) |
| Soltar → pantalla (present fence de SurfaceFlinger) | ~25 ms (p95 30–33) | igual |

El cable no influye: la tablet negocia USB 3 a 5 Gb/s (por un hub USB 3) y el video usa menos de
35 Mbps.

### Tramo de pantalla

`dumpsys SurfaceFlinger --latency 'SurfaceView - dev.tabmonitor/dev.tabmonitor.MainActivity#0'`
da, por frame, la hora deseada de presentación (la que pasa el visor al soltar el buffer) y la del
present fence. La diferencia es lo que tarda Android en mostrarlo: esperar el vsync, componer y
presentar en el siguiente. Medido: 25 ms de promedio, p95 33, p99 34, máx 48 (1452 frames). No se
puede acortar sin root. `OnFrameRenderedListener` no sirve para esto: en `OMX.qcom` reporta ~45 ms
(unos 20 ms después del present fence) y en `c2.qti` devuelve el PTS × 1000.

Con `releaseOutputBuffer(i, true)` la Surface usa el PTS (la hora de captura, en el reloj de la
Mac) como hora deseada de presentación; el visor pasa la hora actual de la tablet.

### Prueba larga (2026-10-21, calidad Rápida)

6,3 minutos de uso real (189 ventanas de 2 s, 164 con video, 32 fps de promedio).

| Medida | Al soltar el buffer | Estimado en pantalla (+25 ms) |
|---|---|---|
| Promedio ponderado por frames | 24,3 ms | ~49 ms |
| Máximo por ventana: mediana / p90 | 51 / 62 ms | ~76 / ~87 ms |
| Peor ventana | 113 ms | ~140 ms |
| Ventanas con máximo > 80 ms al soltar | 2 de 164 | — |

Decode 12,9 ms y llegada 10,5 ms de promedio; ningún frame descartado. Los peores picos son con
muy poco movimiento (0,1 Mbps): la Mac captura y codifica en 5–12 ms, pero la llegada a la tablet
tiene un p95 de 66–97 ms. El primer frame después de un reposo tarda en el camino (USB, adb o la
tablet saliendo de reposo).

Contra el objetivo (promedio < 45, p95 < 60, nunca > 80 en pantalla): el promedio queda en ~49 y
los picos lo superan. El objetivo suponía 0–17 ms para mostrar; son 25.

## Mediciones de punta a punta (hito 3)

2026-10-21, tablet por cable USB con `adb reverse`, decoder OMX de Qualcomm. La latencia es la
hora en que la tablet suelta el frame a la pantalla (`releaseOutputBuffer`), pasada al reloj de
la Mac con ping/pong, menos el vsync de captura en la Mac. El frame aparece en el vsync
siguiente de la tablet, así que la latencia vista es 0–17 ms mayor. Ping de ida y vuelta: 2–5 ms.

| Prueba | Promedio | p95 | Decode |
|---|---|---|---|
| Patrón `testsrc2` a 10 fps | 32–38 ms | 41–48 ms | 18–19 ms |
| Uso real (escribir, mover el mouse), ventanas de 2 s típicas | 35–50 ms | 45–65 ms | 17–20 ms |
| Uso real, peores ventanas de 2 s | 55–115 ms | 100–210 ms | 20–40 ms |

Los picos coinciden con la "llegada de la captura" alta en la Mac (ScreenCaptureKit entregando
frames 30–80 ms tarde); queda para el hito 4.

`OnFrameRenderedListener` no sirve con `c2.qti.avc.decoder`: devuelve el PTS × 1000 como hora.

## Mediciones en la Mac (hito 2)

2026-10-20, MacBook Air M1, macOS 15.3.2. 2560×1600 a 60 fps, H.264 High 5.1, 35 Mbps, con
`testsrc2` de ffmpeg animado a 60 fps dentro del monitor virtual y `Scripts/view-stream.py`
como cliente. Son los valores de la línea `stats` del log de la app, cada 2 s.

| Tramo | Promedio | p95 |
|---|---|---|
| Llegada de la captura (vsync del frame → callback de ScreenCaptureKit) | 0,3 ms | 1,5–4 ms |
| Encoder (entrada → salida de VideoToolbox) | 11 ms | 12–13 ms |
| Captura + codificación (vsync → sale del encoder) | 6–7 ms | 13–15 ms |
| Envío (escritura en el socket local, 128 KB de SO_SNDBUF) | 0,1 ms | 0,1 ms |

Notas:
- Fps entregados: 50–57. ScreenCaptureKit solo entrega cuando cambia algo; el encoder del M1
  tarda 11–18 ms por frame a esta resolución, así que a 60 fps algunos frames se saltean antes de
  codificarlos (último frame gana).
- La hora de captura es el `displayTime` de ScreenCaptureKit (el vsync), que puede quedar unos
  ms en el futuro. Por eso "captura + codificación" a veces da menos que "encoder".
- Bitrate real: 0,4–1,6 Mbps con este contenido; el tope es 35 Mbps.
- El stream usa referencias de largo plazo y `max_num_ref_frames` = 11, el máximo del nivel 5.1
  a 2560×1600, con `max_num_reorder_frames` = 0. En el hito 3 hay que confirmar que el decoder
  Qualcomm lo acepta.

