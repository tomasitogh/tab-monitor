# TabMonitor

Convierte una Lenovo Tab P11 Pro (2560x1600, Snapdragon 730G, Android 11) en monitor extendido
de una MacBook Air M1, solo por cable USB, con latencia mínima. Hoy es de uso personal; el
usuario quiere llegar a un producto ("instalás la app, enchufás la tablet y anda"), pero otras
tablets y la distribución esperan a que él lo pida.

**Antes de seguir, leé [docs/handoff.md](docs/handoff.md)**: estado actual, pendientes, ideas
estacionadas y forma de trabajo. Preparar una máquina nueva: [docs/setup.md](docs/setup.md).

## Arquitectura
- mac/: app de barra de menú en Swift (macOS 14+, sin sandbox, sin dependencias).
  Monitor virtual (CGVirtualDisplay) -> ScreenCaptureKit -> VideoToolbox H.264 -> TCP 127.0.0.1:8081.
  AdbBridge escucha `adb track-devices`, instala o actualiza el visor (por SHA-256), aplica
  `adb reverse` y lo abre. Menú: estado de la tablet, calidad Nítida/Rápida, abrir visor,
  abrir al iniciar sesión.
- android/: APK Kotlin sin AndroidX, minSdk 29. Socket a 127.0.0.1:8081 -> MediaCodec -> SurfaceView.
  El APK viaja dentro de TabMonitor.app (make-app.sh lo compila y lo copia con su hash).
- Cable: adb reverse tcp:8081 tcp:8081.
- Protocolo en PROTOCOL.md: encabezado de 5 bytes (tipo, largo BE), video 0x01 en Annex B,
  control en JSON (hello, config, key, ping/pong, stats).

## Comandos
- mac: swift build / swift test / Scripts/make-app.sh --install --open (compila también el visor;
  TABMONITOR_SKIP_APK=1 para saltearlo).
- android: ./gradlew testDebugUnitTest assembleDebug, con JAVA_HOME en el JDK de Android Studio
  (`/Applications/Android Studio.app/Contents/jbr/Contents/Home`). Normalmente no hace falta
  instalar a mano: AdbBridge actualiza el visor al enchufar o al reabrir TabMonitor.
- logs de la Mac: `/usr/bin/log stream --predicate 'subsystem == "dev.tabmonitor.mac"'`
  (en zsh, `log` a secas es un comando interno). La línea `stats` sale cada 2 s.
- logs de la tablet: adb logcat -s TabMonitor (línea `stats` cada 2 s; un toque en la tablet las
  muestra en pantalla).
- probar la Mac sin tablet: mac/Scripts/view-stream.py (hace de tablet; ffplay para verlo).
- tramo de pantalla de la tablet:
  `adb shell dumpsys SurfaceFlinger --latency "'SurfaceView - dev.tabmonitor/dev.tabmonitor.MainActivity#0'"`.

## Reglas de latencia (no negociables)
- Nunca encolar video: último frame gana en captura, antes del encoder y en el envío. Si el envío
  anterior no se confirmó, descartar y forzar keyframe. SO_SNDBUF chico, TCP_NODELAY en las dos puntas.
- La cola de captura nunca llama al encoder: VTCompressionSessionEncodeFrame bloquea lo que dura
  la codificación. ScreenCaptureKit con queueDepth 8 (con menos se agota el pool).
- H.264 High 5.1, sin B-frames, RealTime, modo de baja latencia, 1 frame de referencia y sin LTR
  (el decoder de la tablet retiene tantos frames como declare el SPS), 35 Mbps, keyframe solo al
  conectar o bajo pedido.
- Android: MediaCodec asíncrono con OMX.qcom.video.decoder.avc (c2.qti retiene un frame),
  KEY_LOW_LATENCY y vendor.qti-ext-dec-low-latency, releaseOutputBuffer(i, horaActual) apenas sale
  (con `true` toma la hora de captura de la Mac como hora de presentación).
- Todo cambio que afecte la latencia se mide antes y después y se anota en docs/latency.md.

## Licencias
- VirtualDisplay.swift viene de Sill (Apache 2.0): conservar cabecera, marcar cambios, listar en NOTICE.
  Es el único archivo con API privada.
- Moonlight es GPL v3: se pueden usar ideas, nunca copiar código.

## Forma de trabajo
- Un hito a la vez, en orden. Probar en la tablet real antes de seguir; el usuario prueba y
  recién con su OK se anota en docs/hitos.md, se hace commit y push.
- Todo lo físico (enchufar, tocar la tablet, aceptar permisos, mirar la pantalla) se le pide
  explícitamente al usuario y se espera su respuesta.
- El estado de cada hito está en docs/hitos.md; las mediciones, en docs/latency.md.
