val githubPackagesUsername = providers.gradleProperty("githubPackagesUsername")
    .orElse(providers.environmentVariable("GITHUB_ACTOR"))
val githubPackagesPassword = providers.gradleProperty("githubPackagesPassword")
    .orElse(providers.environmentVariable("GITHUB_TOKEN"))

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/zetic-ai/mlange_sdk")
            credentials {
                username = githubPackagesUsername.orNull
                password = githubPackagesPassword.orNull
            }
        }
    }
}

rootProject.name = "LFMVision"
include(":app")
