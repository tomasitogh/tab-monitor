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

