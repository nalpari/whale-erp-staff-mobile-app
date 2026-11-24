import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 출시용 서명 키. android/key.properties(저장소에 넣지 않음, 형식은 key.properties.example)가 있으면 그 키로
// release 를 서명하고, 없으면 지금처럼 debug 키로 서명한다(로컬 `flutter run --release` · 내부 확인용).
// 키 파일(.jks)과 key.properties 는 .gitignore 에 있다. 보관자는 계획 결정 16.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "kr.co.whaleerp.staff"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kr.co.whaleerp.staff"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                fun required(name: String): String =
                    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
                        ?: throw GradleException("android/key.properties 에 $name 이 없습니다 (key.properties.example 참고)")
                storeFile = rootProject.file(required("storeFile"))
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // 경고는 아래 packageRelease 작업이 실제로 실행될 때 띄운다(설정 단계 · 구성 캐시와 상관없이).
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 서명 키 없이 release 를 만들면 경고한다. 출력이 없는 작업이라 매번 실행되고(최신 상태로 건너뛰지 않음), 실행 단계에서 띄우므로
// `:app:assemble` 처럼 묶음 작업으로 빌드해도, Gradle 구성 캐시를 다시 써도 빠지지 않는다. release 패키징 작업이 이 작업에 기댄다.
if (!hasReleaseKey) {
    val warnDebugSignedRelease = tasks.register("warnDebugSignedRelease") {
        doLast {
            logger.warn("android/key.properties 가 없어 release 를 debug 키로 서명합니다. 스토어에 올릴 수 없는 빌드입니다.")
        }
    }
    tasks.matching { it.name == "packageRelease" }.configureEach {
        dependsOn(warnDebugSignedRelease)
    }
}
