# TabMonitor

Usa una Lenovo Tab P11 Pro como monitor extendido de una MacBook Air M1, solo por cable USB,
con latencia mínima y sin pagar nada.

Con TabMonitor abierta en la Mac, se enchufa la tablet (con depuración USB activa) y aparece un
monitor de 1280×800 pt a 2× a la derecha de la MacBook. La Mac instala o actualiza el visor en la
tablet y lo abre sola, aunque la tablet esté bloqueada. Latencia hasta la pantalla de la tablet:
~50 ms en calidad Rápida (1920×1200), ~70 ms en Nítida (2560×1600).

- `mac/`: app de barra de menú en Swift. Crea un monitor virtual, lo captura, lo codifica en
  H.264 por hardware, lo manda por el cable y maneja la tablet por adb.
- `android/`: visor en Kotlin que decodifica por hardware y dibuja directo en pantalla. Viaja
  dentro de la app de Mac.
- El cable usa `adb reverse tcp:8081 tcp:8081`.

## Uso

```
cd mac
Scripts/make-app.sh --install --open
```

Después enchufar la tablet. Lo que hace falta en la máquina está en [docs/setup.md](docs/setup.md).

## Documentación

- [CLAUDE.md](CLAUDE.md): arquitectura, comandos y reglas del proyecto.
- [docs/handoff.md](docs/handoff.md): estado actual, pendientes y cómo seguir.
- [docs/setup.md](docs/setup.md): preparar una Mac desde cero.
- [PROTOCOL.md](PROTOCOL.md): mensajes entre la Mac y la tablet, con bytes de ejemplo.
- [docs/hitos.md](docs/hitos.md): estado de cada hito y cómo probarlo.
- [docs/latency.md](docs/latency.md): mediciones de latencia.

## Licencia

Apache 2.0. Incluye código derivado de [Sill](https://github.com/Saffsanity/sill); ver [NOTICE](NOTICE).
