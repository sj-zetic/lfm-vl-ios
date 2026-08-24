# Integrating LFM-VL on iOS with ZeticMLange

How to build a working vision-language app with `ZeticMLangeLLMModel` — the
session contract, image conversion, build setup, and the storage behaviour to
plan for. Written from a real integration; every code sample is running code.

**Tested on:** ZeticMLange 1.9.0 · iPhone 16 Pro (A18 Pro) · iOS 26.0.1 ·
`LFM2.5-VL-450M` (CoreML/MLLM backend) · Xcode 26.4.

---

## 1. Read this first: the session contract

**Context persists across `respond()` calls, by design.** That is what makes
follow-up questions about the same image work. It also means:

> **Call `cleanUp()` before asking about a *different* image.**
> **Do not call it between follow-up questions about the same image.**

```swift
if imageID != contextImageID {
    try model.cleanUp()          // clears transcript + KV cache + staged media
    contextImageID = imageID
}
let stream = try model.respond(systemPrompt: system, userText: question, image: rgb)
```

### What goes wrong without it

`respond(…image:)` appends to a live transcript that is re-rendered whole each
turn, and the newly staged image is attached to the **first** user turn. Ask
about photo A, then photo B, and the model is prompted with:

```
user:      <photo B pixels>  "your first question"
assistant: "<photo A's description>"
user:      "your second question"      ← no image attached
```

Photo B's pixels sit in turn 1's slot, photo A's answer is still in context, and
the question you actually asked has no image on it. **The model returns photo A's
description** — which is the correct output for that prompt. There is no error,
no warning, and the answer looks plausible, so this is easy to miss.

### `resetKVState()` is not the reset you want

On the CoreML/MLLM backend it throws:

```
resetKVState is only supported on KV-persistence-capable backends
(current target: MLLM)
```

This means *"wrong call for this backend"*, **not** *"this backend cannot clear
context"*. `cleanUp()` is the supported reset here. `saveKVState` / `loadKVState`
are likewise KV-persistence-only.

---

## 2. Minimal working integration

```swift
import ZeticMLange

let model = try await ZeticMLangeLLMModel(
    personalKey: "dev_…",                 // https://mlange.zetic.ai/settings?tab=pat
    name: "account/LFM2.5-VL-450M",
    modelMode: .RUN_AUTO,
    onDownload: { progress in print("download \(progress)") }
)

let image = try ZeticMLangeLLMModel.Image(rgb: rgbBytes, width: w, height: h)

for try await piece in try model.respond(
    systemPrompt: "You are a concise vision assistant.",
    userText: "What is this image about?",
    image: image
) {
    print(piece, terminator: "")          // tokens stream in
}
```

Both `init` and `respond` block for a noticeable time on a 450M vision model.
Keep them off the main thread — an `actor` is a clean way to do it:

```swift
actor VisionEngine {
    private var model: ZeticMLangeLLMModel?
    private var contextImageID: UUID?

    func answer(question: String,
                image: ZeticMLangeLLMModel.Image,
                imageID: UUID) throws -> AsyncThrowingStream<String, Error> {
        guard let model else { throw VisionEngineError.notLoaded }
        if let current = contextImageID, current != imageID {
            try model.cleanUp()
        }
        contextImageID = imageID
        return try model.respond(systemPrompt: systemPrompt, userText: question, image: image)
    }
}
```

Full version: [`Core/VisionEngine.swift`](../ZeticMLangeLLMSample/Core/VisionEngine.swift).

---

## 3. Converting a `UIImage`

The model takes **packed 24-bit RGB** — three bytes per pixel, no alpha, no row
padding:

```swift
public struct Image {
    public init(rgb: [UInt8], width: Int, height: Int) throws
    public static func byteCount(width: Int, height: Int, channels: Int) -> Int?
}
```

Two things bite here.

**Orientation.** Camera photos store rotation in `UIImage.imageOrientation`,
which `CGImage` ignores — a portrait photo reaches the model sideways and the
answer describes a rotated scene. Redraw upright before converting.

**Size.** The vision encoder works on a small grid, so a full 12 MP photo costs
memory and prefill time for no gain. Cap the longest edge at ~512 px.

Both, in one pass:

```swift
let scale = min(1, maxDimension / max(size.width, size.height))
let target = CGSize(width: (size.width * scale).rounded(),
                    height: (size.height * scale).rounded())

let format = UIGraphicsImageRendererFormat.default()
format.scale = 1
format.opaque = true
// draw(in:) honours imageOrientation, so the result is upright.
let upright = UIGraphicsImageRenderer(size: target, format: format).image { _ in
    draw(in: CGRect(origin: .zero, size: target))
}
```

Then draw into an RGBA context and strip the alpha channel:

```swift
var rgba = [UInt8](repeating: 0, count: width * height * 4)
rgba.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress,
                            width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
}

var rgb = [UInt8](repeating: 0, count: width * height * 3)
var s = 0, d = 0
while d < rgb.count {
    rgb[d] = rgba[s]; rgb[d+1] = rgba[s+1]; rgb[d+2] = rgba[s+2]
    s += 4; d += 3
}
return try ZeticMLangeLLMModel.Image(rgb: rgb, width: width, height: height)
```

Full version: [`Core/UIImage+ZeticRGB.swift`](../ZeticMLangeLLMSample/Core/UIImage+ZeticRGB.swift).

---

## 4. Build setup

**Swift Package Manager** — `https://github.com/zetic-ai/ZeticMLangeiOS.git`,
from `1.9.0`.

**Link Accelerate yourself.** 1.9.0 ships as a bare `binaryTarget` with no
`linkerSettings`, so `Accelerate` is no longer linked transitively as it was in
1.4.5. Without it the build fails at link time:

```
Undefined symbols for architecture arm64:
  "_vDSP_dotpr", "_vDSP_vsmul", "_vDSP_sve", …
```

Add to the app target:

```
OTHER_LDFLAGS = "-framework Accelerate"
```

**Device only.** The xcframework ships an `ios-arm64` slice with no simulator
slice, so the app cannot build or run in the iOS Simulator. Plan for on-device
development from the start.

**Info.plist** — `NSCameraUsageDescription` for capture. `PhotosPicker` needs no
photo-library entry, since selection happens out of process.

---

## 5. Storage: plan for several gigabytes

A ~1.6 GB model occupies about **6.3 GB** on a clean first run. It is stored
several times over:

| Copy | Location |
|---|---|
| Downloaded archive | `Application Support/ZeticMLangeCache` (`.ztc`) |
| Extracted | `Documents/NativeLfmVL` (`.mlpackage`) |
| Compiled | `Caches/zetic_coreml_compiled` (`.mlmodelc`) |
| Staged | `tmp/` |

The compiled set is rebuilt on each cold start and old sets are not evicted, so
an app that is opened repeatedly grows steadily. Budget for it and warn users
before the first download.

### Model storage ownership

The SDK manages downloaded, extracted, and compiled model artifacts. This app
does not delete or prune model storage; deleting SDK-managed cache can force
model preparation or a new download.

**If the device runs out of space**, extraction can truncate silently — the
directory tree appears but weight files are missing — and inference then crashes
with `SIGSEGV`. If you see that crash, check free space first.

### First-run UX

The download is ~1.76 GB for this model. The `onDownload` callback reports a
`Float` fraction only — no byte totals — so the honest display is percentage plus
elapsed time and an ETA derived from the observed rate. Note that after the
callback reaches `1.0` there is still a **compile** phase of tens of seconds;
show it as a separate step or the UI looks stuck at 100%.

---

## 6. Debugging on device

`devicectl … --console` **restarts the app when it attaches and SIGKILLs it when
the session ends**, so it cannot capture a normal user-driven session. Modern
macOS also no longer supports `log stream --device-udid`.

Write diagnostics to a file and pull it afterwards:

```swift
let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("trace.log")
// append lines as you go
```

```bash
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier com.your.app \
  --source Documents/trace.log --destination ./trace.log
```

Inspect on-device storage the same way:

```bash
xcrun devicectl device info files --device "$UDID" \
  --domain-type appDataContainer --domain-identifier com.your.app
```

Logging a cheap fingerprint of the RGB buffer you pass in is worth the few lines
— it distinguishes "the wrong image reached the model" from "the model answered
about the wrong image", which are very different bugs.

Full version: [`Core/TraceLog.swift`](../ZeticMLangeLLMSample/Core/TraceLog.swift).

---

## 7. Checklist

- [ ] `OTHER_LDFLAGS = -framework Accelerate`
- [ ] Building and testing on a physical device
- [ ] `cleanUp()` called when the image changes — **not** between same-image turns
- [ ] Image redrawn upright and downscaled before conversion
- [ ] Packed RGB, 3 bytes per pixel, no alpha
- [ ] `init` and `respond` off the main thread
- [ ] First-run download surfaced with progress, elapsed time and a separate
      "preparing" phase
- [ ] Storage cleanup before `init`, touching only the directories listed as safe
- [ ] `isExcludedFromBackup` set on the large directories
