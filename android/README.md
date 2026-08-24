# LFM Vision for Android

Jetpack Compose sample app for LFM2.5-VL-450M using exactly
`com.zeticai.mlange:mlange:1.10.0`.

## Setup

From the repository root, create the ignored shared configuration file:

```sh
cp .env.example .env
```

Set `ZETIC_PERSONAL_KEY` in `.env`, then build:

```sh
cd android
./gradlew :app:assembleDebug
```

The Gradle build reads only that key and writes it to `BuildConfig`. If it is
missing, empty, or still a placeholder, the app does not initialize the SDK.
The raw `.env` is neither tracked nor bundled. `BuildConfig` is compiled into
the APK, so a personal key in a distributable APK can be extracted; do not
publish builds that contain a personal key.

The app leaves the SDK-managed `filesDir/mlange_cache` untouched. It uses the
photo picker or camera capture, scales images so the longest edge is 512px,
and streams response tokens into the Compose UI.
