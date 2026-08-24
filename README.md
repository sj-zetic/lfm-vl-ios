# LFM Vision App

Cross-platform sample apps for asking questions about a photo with
LFM2.5-VL-450M through ZETIC.MLange.

```text
ios/      iOS app
android/  Android app (to be added in Phase 2)
```

## Shared setup

The iOS app uses the repository-root `.env` file for the personal access key:

```sh
cp .env.example .env
```

Set `ZETIC_PERSONAL_KEY` in `.env`. The raw `.env` file is ignored and is never
bundled directly.

See [the iOS README](ios/README.md) for iOS setup and usage.
