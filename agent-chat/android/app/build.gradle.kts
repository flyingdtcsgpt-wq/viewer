plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 서명: 환경변수 AC_KEYSTORE(파일 경로) · AC_KEYSTORE_PASSWORD · AC_KEY_ALIAS 가 있으면 그 키, 없으면 debug 키
val ks = System.getenv("AC_KEYSTORE")?.takeIf { it.isNotBlank() && file(it).exists() }

android {
    namespace = "com.agentchat.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.agentchat.app"
        minSdk = 26
        targetSdk = 35
        versionCode = (System.getenv("AC_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("AC_VERSION_NAME") ?: "0.2.0"
    }

    signingConfigs {
        if (ks != null) {
            create("release") {
                storeFile = file(ks)
                storePassword = System.getenv("AC_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("AC_KEY_ALIAS")
                keyPassword = System.getenv("AC_KEYSTORE_PASSWORD")
                storeType = if (ks.endsWith(".p12") || ks.endsWith(".pfx")) "pkcs12" else null
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (ks != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    // QR 스캔: 구글 Play 서비스의 스캐너 화면을 빌려 쓴다 (카메라 권한 필요 없음)
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
