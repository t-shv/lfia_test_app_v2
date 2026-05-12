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
    // ─── Nest each subproject’s build dir under ../build/<moduleName> ───
    buildDir = rootProject.file("../build/${project.name}")

    // ─── Inject a default namespace into any library module (AGP 8+ requirement) ───
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.configure<LibraryExtension> {
                if (namespace.isNullOrBlank()) {
                    namespace = name.replace("-", ".")
                }
            }
        }
    }
}

// ─── Clean task ───
tasks.register<Delete>("clean") {
    delete(buildDir)
}
