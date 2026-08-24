# LFM Vision App

Ask questions about a photo, answered fully on-device by **LFM2.5-VL-450M** via
ZETIC.MLange. Take a picture or pick one from the library, type a question, and
the answer streams back token by token.

This repo doubles as a **reproduction case** for several ZeticMLange 1.9.0
issues found while building it — see [docs/ISSUES-ENCOUNTERED.md](docs/ISSUES-ENCOUNTERED.md).

> **Status: working.** Multiple photos per session are answered correctly.
>
> The one thing to know: call `ZeticMLangeLLMModel.cleanUp()` **when the image
> changes**, and not between follow-up questions about the same image. Without it
> the new photo's pixels are spliced onto the first user turn of a transcript that
> still holds the previous answer, so you get the *previous* photo's description
> back — silently. See [issue 4](docs/ISSUES-ENCOUNTERED.md) and the
> [integration guide](docs/LFM-VL-INTEGRATION-GUIDE.md).
>
> Model storage is managed by ZeticMLange; this app does not delete or prune
> model artifacts.

## Requirements

- **A physical iPhone.** The 1.9.0 xcframework ships an `ios-arm64` slice only —
  there is no simulator slice, so this cannot run in the iOS Simulator.
- Xcode 16+ (developed on 26.4), iOS 18.0+ deployment target.
- A Melange personal access key with access to the model.
- ~7 GB free on the device. Yes, really — see issue 6.

## Setup

1. Clone and open `ZeticMLangeLLMSample.xcodeproj`.
2. Copy `.env.example` to `.env`, set `ZETIC_PERSONAL_KEY`, then generate the
   ignored build configuration. Get a key at https://mlange.zetic.ai/settings?tab=pat.

   ```sh
   cp .env.example .env
   ./scripts/generate-secrets-xcconfig.sh
   ```

   The generated `Secrets.xcconfig` stays out of git, but its value is embedded
   in the built app's `Info.plist` and can be extracted from the app bundle.

3. Set your signing team, select your device, and run.

The first launch downloads ~1.76 GB and then compiles it — expect several
minutes on "Downloading" followed by "Preparing model".

### Required build setting

The target sets `OTHER_LDFLAGS = -framework Accelerate`. **Without it the build
fails to link** with missing `vDSP_*` symbols — SDK 1.9.0 dropped the
`Accelerate` linker setting that 1.4.5 carried. See issue 1.

## Command-line build, install and run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ZeticMLangeLLMSample.xcodeproj -scheme ZeticMLangeLLMSample -configuration Debug -destination "id=$UDID" -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device "$UDID" /path/to/ZeticMLangeLLMSample.app
```

```bash
xcrun devicectl device process launch --device "$UDID" --terminate-existing --console com.sjk.lfmvision
```

Two things that cost us time:

- `--console` holds the process and **SIGKILLs it when the session ends**. Drop
  `--console` for a run that survives; you then lose stdout, because
  `log stream --device-udid` is not supported on current macOS.
- Inspect on-device storage with:

  ```bash
  xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier com.sjk.lfmvision
  ```

---

## How it works

| File | Role |
|---|---|
| `ContentView.swift` | Image picker, transcript, composer |
| `Core/VisionEngine.swift` | Actor owning `ZeticMLangeLLMModel`; context handling |
| `Core/UIImage+ZeticRGB.swift` | `UIImage` → packed 24-bit RGB the model expects |
| `ViewModel/VisionChatViewModel.swift` | Load, ask, stream, cancel, metrics |
| `View/AnswerBubble.swift` | Streaming states, timings, copy/share |

Two details worth knowing if you touch the image path:

- **Orientation.** Camera photos store rotation in `imageOrientation`, which
  `CGImage` ignores. `zeticRGBImage()` redraws upright and downscales to 512 px
  in one pass, then packs RGBA → RGB.
- **Size.** The vision encoder works on a small grid, so a full 12 MP photo
  costs memory and prefill time for nothing. `Constants.maxImageDimension`
  caps it.

## The `cleanUp()` requirement

The single most important thing to know when building on this SDK:

```swift
// after the response stream finishes
try model.cleanUp()
```

Without it, vision context accumulates across calls and **every answer describes
the first image you asked about** — silently, with no error. `resetKVState()`,
the obvious candidate, throws on the CoreML backend:

```
resetKVState is only supported on KV-persistence-capable backends
(current target: MLLM)
```

which reads as "no reset available here". It isn't true; `cleanUp()` works.
`Core/VisionEngine.swift` calls it after every generation and again when the
image changes.

To see the failure mode, comment out those calls and ask about two different
photos. The build logs a fingerprint of the exact pixel buffer sent to the model,
so you can confirm a genuinely different image is being passed while the answer
stays stuck on the first:

```
ask imageID=… contextImageID=… rgb=384x512 fingerprint=…
image changed -> calling cleanUp() … succeeded
answer for imageID=…: …
```

Logs go to `Documents/vlm-trace.log`; pull them with:

```bash
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.sjk.lfmvision --source Documents/vlm-trace.log --destination ./vlm-trace.log
```

## Documents

Read in this order:

1. **[docs/VLM-PLAYBOOK.md](docs/VLM-PLAYBOOK.md)** — do / don't / what to check
   next. **Start here**, whether you are a developer or an AI agent.
2. **[docs/LFM-VL-INTEGRATION-GUIDE.md](docs/LFM-VL-INTEGRATION-GUIDE.md)** — the
   code: session contract, image conversion, build setup, storage, debugging.
   Written to be publishable on docs.zetic.ai.

Reference material, mostly for the SDK team:

- [docs/ISSUES-ENCOUNTERED.md](docs/ISSUES-ENCOUNTERED.md) — every issue hit while
  building this, with reproductions and how each was found.
- [docs/SDK-STORAGE-DEFECT.md](docs/SDK-STORAGE-DEFECT.md) — the storage analysis,
  the one substantive item still open.
- [docs/SUMMARY-FOR-SDK-TEAM.md](docs/SUMMARY-FOR-SDK-TEAM.md) — one-page summary.
- [docs/vlm-trace-example.log](docs/vlm-trace-example.log) — raw device trace.
