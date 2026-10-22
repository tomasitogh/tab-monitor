# TabMonitor

Usa una tablet Android como monitor extendido de tu Mac, solo por cable USB y con latencia
mínima. Se enchufa la tablet y aparece un monitor nuevo a la derecha de la Mac: la app instala
el visor en la tablet y lo abre sola, aunque la tablet esté bloqueada.

Latencia hasta la pantalla de la tablet: ~50 ms en calidad Rápida (1920×1200), ~70 ms en
Nítida (2560×1600).

## Requisitos

- Mac con Apple Silicon (M1 o posterior) y macOS 14 Sonoma o posterior.
- Tablet con Android 10 o posterior y cable USB de datos.
- Probada en la **Lenovo Tab P11 Pro**. En otras tablets puede andar, pero el monitor se crea
  pensado para 2560×1600 y la latencia no está medida.

## Instalación

Con [Homebrew](https://brew.sh):

```
brew install --cask tomasitogh/tap/tabmonitor
```

Instala también `adb` (Android Platform Tools), que la app usa para hablar con la tablet.

## Primera vez en la Mac

TabMonitor es gratis y no está notarizada por Apple, así que macOS la frena la primera vez.
Hay que darle permiso a mano, una sola vez:

1. Abrí TabMonitor desde Aplicaciones. macOS dice que no puede verificar que no tenga software
   malicioso: tocá **Listo** (no "Mover a la papelera").
2. Andá a **Ajustes del Sistema › Privacidad y seguridad**, bajá hasta **Seguridad** y tocá
   **Abrir igual** al lado de "Se bloqueó TabMonitor". Confirmá con tu contraseña o Touch ID.
   El botón aparece durante una hora después del intento del paso 1.
3. El ícono de TabMonitor aparece en la barra de menú (arriba a la derecha).
4. La primera vez que transmite, macOS pide **Grabación de pantalla**: activala en
   **Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema**
   y volvé a abrir TabMonitor si te lo pide. Lo necesita para mostrar el monitor nuevo en la tablet.
5. Opcional: en el menú, **Abrir al iniciar sesión**. macOS puede pedir aprobarlo en
   **Ajustes del Sistema › General › Ítems de inicio**.

Si preferís la terminal, el paso 2 equivale a quitarle la marca de cuarentena (hacelo solo si
confiás en esta app):

```
xattr -dr com.apple.quarantine /Applications/TabMonitor.app
```

## Preparar la tablet

Una sola vez, para que la Mac pueda instalar y abrir el visor:

1. **Activá las opciones de desarrollador**: en Ajustes, buscá **Número de compilación** y
   tocalo 7 veces hasta que diga que ya sos desarrollador.
   - Lenovo: Ajustes › Información de la tablet › Número de compilación.
   - Samsung: Ajustes › Acerca de la tablet › Información de software › Número de compilación.
2. **Activá la depuración USB**: Ajustes › Sistema › Opciones de desarrollador (en Samsung,
   Ajustes › Opciones de desarrollador) › **Depuración USB**.
3. **Enchufá la tablet a la Mac** con TabMonitor abierta y aceptá **Permitir depuración USB**
   en la tablet. Marcá **Permitir siempre desde esta computadora** para que no lo vuelva a pedir.

En Samsung con One UI 6 o posterior, si está activado el **Bloqueador automático** (Ajustes ›
Seguridad y privacidad), apagalo: bloquea la depuración USB.

No hace falta instalar nada en la tablet: TabMonitor instala el visor (`dev.tabmonitor`) y lo
actualiza cuando hace falta.

## Uso

Con TabMonitor abierta, enchufá la tablet: en un par de segundos aparece el monitor. El menú de
la barra muestra el estado de la tablet y deja elegir la calidad (Nítida o Rápida). Al
desenchufarla, el monitor desaparece y las ventanas vuelven a la Mac.

## Actualizar y desinstalar

```
brew upgrade --cask tabmonitor
```

```
brew uninstall --cask tabmonitor
```

El visor de la tablet se desinstala desde la tablet, como cualquier app.

## Desarrollo

- `mac/`: app de barra de menú en Swift. Crea un monitor virtual, lo captura, lo codifica en
  H.264 por hardware, lo manda por el cable y maneja la tablet por adb.
- `android/`: visor en Kotlin que decodifica por hardware y dibuja directo en pantalla. Viaja
  dentro de la app de Mac.
- El cable usa `adb reverse tcp:8081 tcp:8081`.

Compilar e instalar desde el código (lo que hace falta en la máquina está en
[docs/setup.md](docs/setup.md)):

```
cd mac
Scripts/make-app.sh --install --open
```

Publicar una versión: `mac/Scripts/release.sh X.Y.Z` (detalle en [docs/setup.md](docs/setup.md)).

## Documentación

- [CLAUDE.md](CLAUDE.md): arquitectura, comandos y reglas del proyecto.
- [docs/handoff.md](docs/handoff.md): estado actual, pendientes y cómo seguir.
- [docs/setup.md](docs/setup.md): preparar una Mac desde cero y publicar versiones.
- [PROTOCOL.md](PROTOCOL.md): mensajes entre la Mac y la tablet, con bytes de ejemplo.
- [docs/hitos.md](docs/hitos.md): estado de cada hito y cómo probarlo.
- [docs/latency.md](docs/latency.md): mediciones de latencia.

## Licencia

Apache 2.0. Incluye código derivado de [Sill](https://github.com/Saffsanity/sill); ver [NOTICE](NOTICE).
