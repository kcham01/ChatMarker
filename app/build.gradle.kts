plugins {
    id("com.android.application")
}

// CI passes the GitHub run number so every build gets a higher version.
val buildNumber = System.getenv("GITHUB_RUN_NUMBER")?.toIntOrNull() ?: 1

android {
    namespace = "com.kcham01.pdftopng"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.kcham01.pdftopng"
        minSdk = 26
        targetSdk = 34
        versionCode = buildNumber
        versionName = "1.0.$buildNumber"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

}
