plugins {
    id("com.android.application")
}

android {
    namespace = "dev.tabmonitor"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.tabmonitor"
        minSdk = 29
        targetSdk = 35
        // make-app.sh pasa la versión del tag y la cantidad de commits, igual que en la app de Mac.
        versionCode = providers.gradleProperty("tabmonitorBuild").getOrElse("1").toInt()
        versionName = providers.gradleProperty("tabmonitorVersion").getOrElse("0.1.0")
    }

    // La clave de release vive fuera del repo (mac/Scripts/make-apk-key.sh); make-app.sh la pasa
    // por el entorno. Sin ella el release se firma con la clave de debug.
    val keystore = providers.environmentVariable("TABMONITOR_KEYSTORE").orNull
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = providers.environmentVariable("TABMONITOR_KEYSTORE_PASSWORD").get()
                keyAlias = "tabmonitor"
                keyPassword = storePassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // org.json del android.jar es un stub en los tests de JVM; esta es la implementación real.
    testImplementation("org.json:json:20240303")
}
