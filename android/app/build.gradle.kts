plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

android {
    namespace = "com.jgsoft.pingolive"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jgsoft.pingolive"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = "upload"
            keyPassword = "pingo2026!"
            storeFile = file("upload-keystore.jks")
            storePassword = "pingo2026!"
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

configurations.all {
    resolutionStrategy {
        force("com.android.billingclient:billing:8.0.0")
        force("com.android.billingclient:billing-ktx:8.0.0")
    }
}

dependencies {
    implementation("com.android.billingclient:billing:8.0.0")
}

flutter {
    source = "../.."
}
