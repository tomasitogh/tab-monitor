# TabMonitor

Usa una Lenovo Tab P11 Pro como monitor extendido de una MacBook Air M1, solo por cable USB,
con latencia mínima y sin pagar nada.

- `mac/`: app de barra de menú en Swift. Crea un monitor virtual, lo captura, lo codifica en
  H.264 por hardware y lo manda por el cable.
- `android/`: visor en Kotlin que decodifica por hardware y dibuja directo en pantalla
  (a partir del hito 3).
- El cable usa `adb reverse tcp:8081 tcp:8081`.

Documentación:

- [CLAUDE.md](CLAUDE.md): arquitectura, comandos y reglas del proyecto.
- [PROTOCOL.md](PROTOCOL.md): mensajes entre la Mac y la tablet, con bytes de ejemplo.
- [docs/hitos.md](docs/hitos.md): estado de cada hito y cómo probarlo.
- [docs/latency.md](docs/latency.md): mediciones de latencia.

## Licencia

Apache 2.0. Incluye código derivado de [Sill](https://github.com/Saffsanity/sill); ver [NOTICE](NOTICE).
