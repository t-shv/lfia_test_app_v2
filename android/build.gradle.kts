
plugins {
    id("com.google.gms.google-services") version "4.3.15" apply false
}

import org.gradle.api.tasks.Delete
import com.android.build.gradle.LibraryExtension
import org.gradle.kotlin.dsl.*

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ─── Relocate root build dir one level up ───
buildDir = file("../build")

subprojects {
    // ─── Nest each subproject's build dir under ../build/<moduleName> ───
    buildDir = rootProject.file("../build/${project.name}")

    // ─── Configure Android library modules ───
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {

            val isTfliteFlutter = name == "tflite_flutter"

            extensions.configure<LibraryExtension> {

                // Inject a default namespace (AGP 8+ requirement)
                if (namespace.isNullOrBlank()) {
                    namespace = name.replace("-", ".")
                }

                // Fix Java/Kotlin JVM target mismatch for TensorFlow Lite
                if (isTfliteFlutter) {
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
        }
    }
}

// ─── Clean task ───
tasks.register<Delete>("clean") {
    delete(buildDir)
}
