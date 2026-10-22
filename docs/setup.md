# Preparar la máquina

Lo que hizo falta en la MacBook Air M1 (macOS 15.3.2) para compilar y probar todo. Si la Mac ya
tiene esto, saltealo.

## Mac

1. **Xcode** (se usó 16.0, Swift 6.0) y Homebrew.
2. Herramientas:
   ```
   brew install android-platform-tools ffmpeg
   brew install --cask android-studio android-commandlinetools
   ```
   - `adb`: AdbBridge lo busca en `/opt/homebrew/bin/adb`, `/usr/local/bin/adb` y
     `~/Library/Android/sdk/platform-tools/adb`.
   - `ffmpeg` trae `ffplay`, que usan `mac/Scripts/view-stream.py` y las pruebas con patrones
     (`testsrc2`).
3. **SDK de Android** (el asistente de Android Studio no lo descargó; se hizo a mano):
   ```
   SM=$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager
   export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   $SM --sdk_root=$HOME/Library/Android/sdk --licenses
   $SM --sdk_root=$HOME/Library/Android/sdk "platforms;android-35" "build-tools;35.0.0" "platform-tools"
   echo "sdk.dir=$HOME/Library/Android/sdk" > android/local.properties
   ```
   Las licencias del SDK las acepta el usuario. El Android Gradle Plugin baja solo las
   build-tools 36 al compilar.
4. **JDK**: Gradle 9.8.2 (wrapper en `android/`) y AGP 9.4.1 corren con el JDK de Android Studio
   (Java 25). `make-app.sh` lo toma solo si `JAVA_HOME` no está definido.
5. **Firma**: un certificado Apple Development (Xcode › Settings › Accounts, con un Apple ID
   gratis alcanza; Manage Certificates › + › Apple Development).
   - Si `security find-identity -v -p codesigning` dice `0 valid identities` aunque el
     certificado esté, falta el intermedio **Apple WWDR CA G3**: bajar `AppleWWDRCAG3.cer` de
     https://www.apple.com/certificateauthority/ e importarlo en el llavero de sesión
     (`security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`). Sin él,
     `codesign` falla con `errSecInternalComponent` y `make-app.sh` firma ad hoc.
   - Con la firma ad hoc, macOS vuelve a pedir Grabación de pantalla tras cada compilación.
6. **Permisos de TabMonitor**: Grabación de pantalla (Ajustes del Sistema › Privacidad y seguridad ›
   Grabación de pantalla y audio del sistema). macOS lo pide la primera vez que transmite.
   "Abrir al iniciar sesión" puede pedir aprobación en General › Ítems de inicio.

## Tablet

- Opciones de desarrollador › Depuración USB activada. La primera vez, aceptar "Permitir
  depuración USB" (conviene marcar "Permitir siempre desde esta computadora").
- Batería: "Modo de protección de la batería" la mantiene entre 40 % y 60 %; útil si queda
  enchufada todo el día.
- No hace falta instalar nada a mano: TabMonitor instala el visor (`dev.tabmonitor`) al enchufar.

## Compilar y probar

```
cd mac
swift test
Scripts/make-app.sh --install --open
```

Después enchufar la tablet. Tests del visor:

```
cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew testDebugUnitTest
```

## Publicar una versión

Una sola vez:

1. Clave del visor: `mac/Scripts/make-apk-key.sh`. Deja `~/.tabmonitor/release.jks` y su
   contraseña en el llavero (`dev.tabmonitor.apk`). **Hacele backup a las dos**: sin la misma
   clave, Android no deja actualizar el visor y cada tablet tendría que desinstalarlo.
2. `gh auth login` y el tap: `gh repo create tomasitogh/homebrew-tap --public`.

Cada versión, desde `main` limpio y pusheado:

```
cd mac
Scripts/release.sh 0.2.0
```

Corre los tests, arma la app firmada, crea el tag `v0.2.0` y el GitHub Release con el zip, y
actualiza `Casks/tabmonitor.rb` en el tap. Los usuarios actualizan con
`brew upgrade --cask tabmonitor`. Con `--dry-run` solo arma el zip y el cask en `mac/.build/dist/`.
