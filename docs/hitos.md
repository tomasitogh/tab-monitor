# Hitos

Cada hito se prueba en la tablet real antes de pasar al siguiente. El MVP es el hito 3.

| Hito | Estado |
|---|---|
| 0. Validaciones (sin código) | pendiente: lo hacés en la Mac y la tablet |
| 1. Monitor virtual | código escrito, falta compilar y probar en la Mac |
| 2. Captura y codificación | — |
| 3. Visor Android por cable (MVP) | — |
| 4. Latencia excelente | — |
| 5. Enchufar y usar | — |
| 6. Toque y lápiz (opcional) | — |

## Hito 0: validaciones

Anotá cada resultado acá.

- [ ] **El M1 Air acepta un monitor virtual.** `brew install --cask deskpad`, abrirlo, verificar
      que aparece en Ajustes del Sistema › Pantallas y desinstalarlo
      (`brew uninstall --cask deskpad`).
      Resultado:
- [ ] **adb ve la tablet.** `adb devices` la muestra como `device` (no `unauthorized`).
      Resultado:
- [ ] **Versión de Android.** `adb shell getprop ro.build.version.release`
      Resultado:
- [ ] **El decoder soporta 2560×1600 a 60 fps.**
      ```
      adb shell 'cat /vendor/etc/media_codecs*.xml' | grep -A12 'video/avc' | grep -iE 'name=|size|frame-rate|performance'
      ```
      Resultado (pegá la salida):
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
