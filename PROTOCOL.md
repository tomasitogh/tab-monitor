# Protocolo TabMonitor

Una conexión TCP a `127.0.0.1:8081`, iniciada por la tablet a través de
`adb reverse tcp:8081 tcp:8081`. La Mac escucha solo en `127.0.0.1`. Una tablet a la vez:
si llega una segunda conexión, la Mac la cierra. `TCP_NODELAY` en las dos puntas.

## Encabezado

Cada mensaje empieza con 5 bytes:

| Bytes | Campo | Formato |
|---|---|---|
| 0 | tipo | 1 byte |
| 1–4 | largo del contenido | entero sin signo de 32 bits, big-endian |

Después vienen exactamente `largo` bytes de contenido. Un largo mayor a 16 MiB es un error
de protocolo y se cierra la conexión. Un tipo desconocido se ignora salteando su contenido.

## Mensajes

| Tipo | Dirección | Nombre | Contenido |
|---|---|---|---|
| `0x01` | Mac → tablet | Frame de video | binario, ver abajo |
| `0x10` | Tablet → Mac | `hello` | JSON, ver abajo |
| `0x11` | Mac → tablet | `config` | JSON: `codec`, `w`, `h`, `fps`, `bitrate` |
| `0x12` | Tablet → Mac | `key` | vacío: pedir keyframe |
| `0x13` | Tablet → Mac | `ping` | JSON: `ts` (hora de la tablet en ms) |
| `0x14` | Mac → tablet | `pong` | JSON: `ts` (eco), `mac` (hora de la Mac en ms) |
| `0x15` | Tablet → Mac | `stats` | JSON: `fps`, `latencyMs` (`avg`, `p95`), `decodeMs`, `dropped` |

El JSON va en UTF-8, compacto. El receptor ignora claves que no conoce.

### `hello` (`0x10`)

| Clave | Contenido |
|---|---|
| `w`, `h` | pantalla en píxeles, siempre horizontal (`w` ≥ `h`) |
| `dpi` | píxeles por pulgada de la pantalla; con `w` y `h` da el tamaño físico |
| `model`, `android` | modelo y versión de Android, para los logs |
| `id` | identificador estable de la tablet: los primeros 8 dígitos hexadecimales del SHA-256 del `ANDROID_ID`. La Mac lo usa para que cada tablet sea un monitor distinto para macOS |
| `decoder` | el decoder que eligió el visor |
| `maxDecode` | lo que dice soportar ese decoder: `w`, `h` (máximos), `fps` (a la resolución de la pantalla), `w60`, `h60` (lo más grande con la proporción de la pantalla que decodifica a 60 fps) y `bitrate` (máximo, en bits por segundo) |

Todas menos `w` y `h` son opcionales para la Mac: sin ellas usa los valores de la Lenovo
Tab P11 Pro.

### Frame de video (`0x01`)

| Bytes | Campo |
|---|---|
| 0 | flags: bit 0 = keyframe; el resto en 0 |
| 1–8 | hora de captura en µs, entero sin signo de 64 bits, big-endian |
| 9… | unidades NAL en Annex B (`00 00 00 01` antes de cada una) |

Los keyframes llevan SPS y PPS adelante del IDR. La tablet no decodifica nada hasta recibir
el primer keyframe.

### Relojes

- La hora de la Mac (`mac` en `pong` y la hora de captura del video) sale del mismo reloj
  monotónico de la Mac; el video en µs y el `pong` en ms.
- La hora de la tablet (`ts` del `ping`) sale de un reloj monotónico de la tablet
  (`System.nanoTime`).
- Desfase estimado: `mac − (envío + recepción) / 2`, usando las horas de la tablet en que salió el
  `ping` y llegó el `pong`. Se toma el de menor ida y vuelta de las últimas muestras.
- Latencia de un frame: hora en que se muestra (en la tablet, pasada al reloj de la Mac)
  menos hora de captura.

## Secuencia

1. La tablet conecta y manda `hello`.
2. La Mac crea el monitor virtual con la proporción de la pantalla de la tablet y responde `config`
   con el tamaño que va a transmitir.
3. La Mac empieza con un keyframe y sigue con frames de video.
4. La tablet manda `ping` cada 1 s y `stats` cada 2 s; manda `key` cuando necesita un keyframe
   (por ejemplo, tras un error del decoder).
5. Al cortarse la conexión, la Mac destruye el monitor y las ventanas vuelven a la MacBook.

## Bytes de ejemplo

Los tests de las dos puntas usan estos mismos bytes. El encabezado va separado del contenido
con `|` solo para leerlo; en el cable van seguidos.

**Frame de video** (keyframe, captura en 1 000 000 µs, NAL de ejemplo: SPS, PPS e IDR
recortados, válidos solo para probar el framing):

```
01 00 00 00 20 | 01 00 00 00 00 00 0F 42 40 00 00 00 01 67 42 00 1F 00 00 00 01 68 CE 3C 80 00 00 00 01 65 88 84
```

**hello** (203 bytes de contenido):

```
10 00 00 00 CB | {"w":2560,"h":1600,"dpi":262.5,"model":"TB-J706F","android":"12","id":"3f9a0c1e","decoder":"OMX.qcom.video.decoder.avc","maxDecode":{"w":3840,"h":2160,"fps":60,"w60":2560,"h60":1600,"bitrate":100000000}}
```

**config** (62 bytes):

```
11 00 00 00 3E | {"codec":"h264","w":2560,"h":1600,"fps":60,"bitrate":35000000}
```

**key** (sin contenido):

```
12 00 00 00 00
```

**ping** (13 bytes):

```
13 00 00 00 0D | {"ts":123456}
```

**pong** (26 bytes):

```
14 00 00 00 1A | {"ts":123456,"mac":987654}
```

**stats** (75 bytes):

```
15 00 00 00 4B | {"fps":59.8,"latencyMs":{"avg":38.2,"p95":51.0},"decodeMs":6.1,"dropped":0}
```
