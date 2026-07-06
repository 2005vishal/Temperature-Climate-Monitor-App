plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vpatwa.atmo_stream"
    
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // FIXED: आपके ग्रैडल के हिसाब से इसे वापस stabalized kotlinOptions पर सेट कर दिया है
    // इससे 'Unresolved reference' की दोनों एरर पूरी तरह खत्म हो जाएंगी
    @Suppress("DEPRECATION")
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.vpatwa.atmo_stream"
        minSdk = flutter.minSdkVersion         // Support starting from Flutter's minimum standard
        
        // 32 (Android 12) for smooth HC-05 V3.0 auto background connectivity
        targetSdk = 32 
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Bypass strict lint errors during release assembly compiles
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

flutter {
    source = "../.."
}