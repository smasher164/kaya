#!/usr/bin/env python3
"""Write the probe project's gradle files at the given pins.

usage: gen.py <agp> <kotlin> <compileSdk> <foundation>
"""
import sys, pathlib

agp, kotlin, compile_sdk, foundation = sys.argv[1:5]
agp_major = int(agp.split(".")[0])
kotlin_android_decl = "" if agp_major >= 9 else f'        id("org.jetbrains.kotlin.android") version "{kotlin}"\n'
kotlin_android_apply = "" if agp_major >= 9 else '    id("org.jetbrains.kotlin.android")\n'
kotlin_block = "" if agp_major >= 9 else """
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
"""
root = pathlib.Path(__file__).resolve().parent / "proj"
(root / "app/src/main/kotlin/dev/kayaprobe/richtext").mkdir(parents=True, exist_ok=True)

(root / "settings.gradle.kts").write_text(f"""
pluginManagement {{
    repositories {{
        google()
        mavenCentral()
        gradlePluginPortal()
    }}
    plugins {{
        id("com.android.application") version "{agp}"
{kotlin_android_decl}        id("org.jetbrains.kotlin.plugin.compose") version "{kotlin}"
    }}
}}

dependencyResolutionManagement {{
    repositories {{
        google()
        mavenCentral()
    }}
}}

rootProject.name = "rtprobe"
include(":app")
""", encoding="utf-8")

(root / "build.gradle.kts").write_text("", encoding="utf-8")

(root / "gradle.properties").write_text("""android.useAndroidX=true
org.gradle.jvmargs=-Xmx3g
android.builder.sdkDownload=false
""", encoding="utf-8")

(root / "app/build.gradle.kts").write_text(f"""
plugins {{
    id("com.android.application")
{kotlin_android_apply}    id("org.jetbrains.kotlin.plugin.compose")
}}

android {{
    namespace = "dev.kayaprobe.richtext"
    compileSdk = {compile_sdk}
    buildToolsVersion = "37.0.0"

    defaultConfig {{
        applicationId = "dev.kayaprobe.richtext"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }}

    buildFeatures {{
        compose = true
    }}

    compileOptions {{
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }}

}}
{kotlin_block}
dependencies {{
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.foundation:foundation:{foundation}")
    implementation("androidx.compose.ui:ui:{foundation}")
    implementation("androidx.compose.ui:ui-text:{foundation}")
    implementation("androidx.compose.runtime:runtime:{foundation}")
}}
""", encoding="utf-8")

(root / "app/src/main/AndroidManifest.xml").write_text("""<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="rtprobe" android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
""", encoding="utf-8")
print(f"wrote {root} agp={agp} kotlin={kotlin} compileSdk={compile_sdk} foundation={foundation}")
