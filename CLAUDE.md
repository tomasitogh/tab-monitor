# TabMonitor

Convierte una Lenovo Tab P11 Pro (2560x1600, Snapdragon 730G) en monitor extendido de una
MacBook Air M1, solo por cable USB, con latencia mínima. Uso personal, gratis.

## Arquitectura
- mac/: app de barra de menú en Swift (macOS 14+, sin sandbox, sin dependencias).
  Monitor virtual (CGVirtualDisplay) -> ScreenCaptureKit -> VideoToolbox H.264 -> TCP 127.0.0.1:8081.
- android/: APK Kotlin sin AndroidX, minSdk 29. Socket a 127.0.0.1:8081 -> MediaCodec -> SurfaceView.
- Cable: adb reverse tcp:8081 tcp:8081. AdbBridge lo aplica y abre el visor al detectar la tablet.
- Protocolo en PROTOCOL.md: encabezado de 5 bytes (tipo, largo BE), video 0x01 en Annex B,
  control en JSON (hello, config, key, ping/pong, stats).

## Comandos
- mac: swift build / swift test / Scripts/make-app.sh
- android: ./gradlew assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
- logs de la tablet: adb logcat -s TabMonitor

## Reglas de latencia (no negociables)
- Nunca encolar video: último frame gana en captura y envío. Si el envío anterior no se confirmó,
  descartar y forzar keyframe. SO_SNDBUF chico, TCP_NODELAY en las dos puntas.
- H.264 High 5.1, sin B-frames, RealTime, 35 Mbps, keyframe solo al conectar o bajo pedido.
- Android: MediaCodec asíncrono, KEY_LOW_LATENCY si existe, releaseOutputBuffer(i, true) apenas sale.
- Todo cambio que afecte la latencia se mide y se anota en docs/latency.md.

## Licencias
- VirtualDisplay.swift viene de Sill (Apache 2.0): conservar cabecera, marcar cambios, listar en NOTICE.
  Es el único archivo con API privada.
- Moonlight es GPL v3: se pueden usar ideas, nunca copiar código.

## Forma de trabajo
- Un hito a la vez, en orden. Probar en la tablet real antes de seguir.
- El estado de cada hito está en docs/hitos.md.
