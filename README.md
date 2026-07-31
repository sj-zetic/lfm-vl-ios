# LFM Vision App

Ask questions about a photo, answered fully on-device by **LFM2.5-VL-450M** via
ZETIC.MLange. Take a picture or pick one from the library, type a question, and
the answer streams back token by token.

This repo doubles as a **reproduction case** for several ZeticMLange 1.9.0
issues found while building it — see [docs/ISSUES-ENCOUNTERED.md](docs/ISSUES-ENCOUNTERED.md).

> **Status:** works for a single photo. Two known blockers, both in the SDK
> rather than this app:
>
> - Asking about a **second** photo returns the *first* photo's description
>   ([issue 4](docs/ISSUES-ENCOUNTERED.md)). `resetKVState()` is unsupported on
>   the CoreML backend and recreating the model segfaults, so there is no
>   application-side remedy.
> - Compiled artifacts grow ~1.5 GB per launch with no eviction. Left unchecked
>   this **fills the device, truncates model extraction, and crashes inference
>   with SIGSEGV** — at which point the app cannot even be reinstalled
>   ([issue 7](docs/ISSUES-ENCOUNTERED.md)). This app ships a janitor that keeps
>   it bounded; see `Core/ModelStorageJanitor.swift` for which directories are
>   safe to clean and which break the app.

---

## Requirements

- **A physical iPhone.** The 1.9.0 xcframework ships an `ios-arm64` slice only —
  there is no simulator slice, so this cannot run in the iOS Simulator.
- Xcode 16+ (developed on 26.4), iOS 18.0+ deployment target.
- A Melange personal access key with access to the model.
- ~7 GB free on the device. Yes, really — see issue 6.

## Setup

1. Clone and open `ZeticMLangeLLMSample.xcodeproj`.
2. Provide your access key. Either set `MLANGE_PERSONAL_KEY` in the scheme's
   environment (preferred — keeps it out of git), or edit
   `ZeticMLangeLLMSample/Core/Constants/Constants.swift`:

   ```swift
   static let personalAccessKey = "dev_…"          // https://mlange.zetic.ai/settings?tab=pat
   static let modelName = "changgeun/LFM2.5-VL-450M"
   ```

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
| `ContentView.swift` | Image picker, transcript, composer, storage menu |
| `Core/VisionEngine.swift` | Actor owning `ZeticMLangeLLMModel`; context handling |
| `Core/UIImage+ZeticRGB.swift` | `UIImage` → packed 24-bit RGB the model expects |
| `Core/ModelStorageJanitor.swift` | Reclaims leftover model files (see caveats) |
| `Core/ModelStorageReport.swift` | Per-area byte accounting for the SDK's directories |
| `ViewModel/VisionChatViewModel.swift` | Load, ask, stream, cancel, metrics |
| `View/AnswerBubble.swift` | Streaming states, timings, copy/share |

Two details worth knowing if you touch the image path:

- **Orientation.** Camera photos store rotation in `imageOrientation`, which
  `CGImage` ignores. `zeticRGBImage()` redraws upright and downscales to 512 px
  in one pass, then packs RGBA → RGB.
- **Size.** The vision encoder works on a small grid, so a full 12 MP photo
  costs memory and prefill time for nothing. `Constants.maxImageDimension`
  caps it.

## Reproducing the headline bug (issue 4)

1. Launch, wait for the model to become ready.
2. Pick photo **A**, ask "What is this image about?" → correct answer.
3. Pick photo **B**, visually unrelated. Ask the same question.
4. **The answer describes photo A.**

The build logs a fingerprint of the exact pixel buffer handed to the model on
every question, so you can confirm a different image really is being passed:

```
[VLM] ask imageID=… contextImageID=… rgb=384x512 fingerprint=…
[VLM] image changed -> proceeding WITHOUT reset (diagnostic)
[VLM] answer for imageID=…: …
```

Capture with `--console` as above.

`resetKVState()` — the obvious remedy — throws on this backend:

```
resetKVState is only supported on KV-persistence-capable backends
(current target: MLLM)
```

and recreating the model instead crashes with SIGSEGV. Details in issue 3 and 5.

## Documents

- **[docs/ISSUES-ENCOUNTERED.md](docs/ISSUES-ENCOUNTERED.md)** — all seven issues,
  with reproductions and asks for the SDK team. Start here.
- **[docs/SDK-STORAGE-DEFECT.md](docs/SDK-STORAGE-DEFECT.md)** — the storage
  analysis in full, with clean-baseline measurements.
