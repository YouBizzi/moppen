allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// We gebruiken .set() in plaats van .value() voor Gradle 8+ compatibiliteit
rootProject.layout.buildDirectory.set(rootProject.projectDir.parentFile.resolve("build"))

subprojects {
    val newSubprojectBuildDir = rootProject.layout.buildDirectory.get().asFile.resolve(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}