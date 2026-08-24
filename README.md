# LFM Vision App

Cross-platform sample apps for asking questions about a photo with
LFM2.5-VL-450M through ZETIC.MLange.

```text
ios/      iOS app
android/  Android Jetpack Compose app
```

## Shared setup

Both apps use the repository-root `.env` file for the personal access key:

```sh
cp .env.example .env
```

Set `ZETIC_PERSONAL_KEY` in `.env`. The raw `.env` file is ignored and is never
bundled directly. Android compiles the key into `BuildConfig`; APK contents can
be extracted, so never distribute a build that contains a personal key.

See [the iOS README](ios/README.md) for iOS setup and usage.
See [the Android README](android/README.md) for Android setup and usage.
