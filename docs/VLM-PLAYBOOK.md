# VLM playbook — do, don't, and what to check next

Practical rules for building an LFM-VL app on ZeticMLange iOS 1.9.0, written so a
developer or an AI agent can follow them without rediscovering what cost us a day.

Every DO and DON'T below is something we verified on a device. The OPEN section is
explicitly *not* verified — treat it as a to-do list, not as guidance.

**Read [LFM-VL-INTEGRATION-GUIDE.md](LFM-VL-INTEGRATION-GUIDE.md) for the code.**
This file is the checklist and the reasoning.

---

## Verified working

| Behaviour | Status |
|---|---|
| Single photo, one or many questions | ✅ |
| Follow-up questions about the same photo (context preserved) | ✅ |
| Switching photos mid-session (A → B → C) | ✅ with `cleanUp()` |
| Streaming token-by-token | ✅ |
| Cold start from cache, no re-download | ✅ ~45 s |
| Storage bounded across launches | ✅ with the janitor |

---

## DO

### 1. Call `cleanUp()` when the image changes — and only then

```swift
if let current = contextImageID, current != imageID {
    try model.cleanUp()
}
contextImageID = imageID
```

Context persistence across calls is **intentional** — it is what makes follow-up
questions work. `cleanUp()` clears the transcript, KV cache and staged media
together. See [`Core/VisionEngine.swift`](../ZeticMLangeLLMSample/Core/VisionEngine.swift).

### 2. Run `init` and `respond` off the main thread

Both block for seconds on a 450M model. An `actor` owning the model is a clean fit
and serialises access for free.

### 3. Normalise orientation and downscale before converting

`CGImage` ignores `UIImage.imageOrientation`, so camera photos reach the model
rotated. Redraw upright and cap the longest edge (~512 px) in one pass — a full
12 MP photo costs memory and prefill time for no quality gain.

### 4. Link Accelerate explicitly

`OTHER_LDFLAGS = -framework Accelerate`. 1.9.0 is a bare `binaryTarget` and
dropped the linker setting 1.4.5 carried.

### 5. Clean storage before `init`, not during

Only `tmp/` and `Caches/zetic_coreml_compiled` are safe to empty; keep the newest
extraction under `Documents/NativeLfmVL/<model>/`. Run it while nothing is mapped.
See [`Core/ModelStorageJanitor.swift`](../ZeticMLangeLLMSample/Core/ModelStorageJanitor.swift).

### 6. Set `isExcludedFromBackup` on the large directories

`Documents/` is backed up to iCloud by default. Several GB per app counts against
the user's quota.

### 7. Log to a file, not stdout

`devicectl --console` restarts the app on attach and SIGKILLs it on detach, so it
cannot capture a real session. Append to `Documents/…log` and pull it with
`devicectl device copy from`. See [`Core/TraceLog.swift`](../ZeticMLangeLLMSample/Core/TraceLog.swift).

### 8. Log a fingerprint of the RGB buffer you pass in

A few lines that separate "the wrong image reached the model" from "the model
answered about the wrong image" — very different bugs. This is what finally
identified the context issue.

### 9. Budget ~7 GB free on the test device

Below that, extraction truncates silently and inference segfaults later.

### 10. Show the download and the compile as separate phases

`onDownload` reports a `Float` only — no byte totals. After it reaches `1.0`
there is still a compile of tens of seconds; without a separate phase the UI
looks frozen at 100%.

---

## DON'T

### 1. Don't call `cleanUp()` after every generation

It destroys same-image follow-up context, which is supported behaviour. Image
change only.

### 2. Don't reach for `resetKVState()` on the CoreML backend

It throws:

```
resetKVState is only supported on KV-persistence-capable backends
(current target: MLLM)
```

This means *"wrong call for this backend"*, **not** *"context cannot be
cleared"*. Misreading it is what sent this project through a model-reload
workaround and then a force-quit-between-photos workaround. Same applies to
`saveKVState` / `loadKVState`.

### 3. Don't clear `Library/Caches/<your-bundle-id>`

It holds Apple's `com.apple.e5rt.e5bundlecache` (Neural Engine bundles) and
`Cache.db` — not Zetic data. Clearing it forced a full ANE recompile every launch
*and* repeated 1.76 GB re-downloads, which we then misattributed to the SDK.

### 4. Don't delete `Application Support/ZeticMLangeCache`

That is the downloaded `.ztc`. Removing it forces a full re-download.

### 5. Don't call `ModelCacheManager.prune()` alongside manual cleanup

`prune()` deletes files the SDK's index no longer references. Purging compiled
artifacts and stale extractions leaves index entries dangling, so the next
`prune()` drops the `.ztc` as an orphan — a complete 1.64 GB archive vanished
between launches and the app re-downloaded every time.

### 6. Don't recreate the model to clear context

`cleanUp()` does it in milliseconds. A reload re-extracts ~1.5 GB and recompiles
~1.5 GB with nothing reclaiming them mid-session.

### 7. Don't expect the Simulator to work

The xcframework ships `ios-arm64` only. There is no simulator slice.

### 8. Don't pass full-resolution photos

Memory and prefill cost with no benefit; the vision encoder works on a small grid.

### 9. Don't set `quantType` expecting a GGUF backend

For `LFM2.5-VL-450M` the selection service returns CoreML regardless — all nine
candidates are CoreML. The parameter is currently inert for this model.

### 10. Don't iterate install → launch → test loops casually on a real device

Each cold start writes ~1.5 GB of compiled artifacts and can re-download 1.76 GB.
Our own test loop filled a 256 GB iPhone twice, to the point where a 28 MB build
could not install. Batch changes; test deliberately.

---

## OPEN — unverified, worth checking next

Ranked by how likely they are to bite a real app. **None of this is tested.**

### 1. Context window exhaustion — `nCtx` defaults to 2048

```swift
LLMInitOption(kvCacheCleanupPolicy: .CLEAN_UP_ON_FULL, nCtx: 2048, runConfigId: 0)
```

A 512 px image consumes a substantial share of that before any text. With a system
prompt and several follow-up turns, 2048 could fill quickly — and
`.CLEAN_UP_ON_FULL` then does *something* undocumented, possibly evicting the
image mid-conversation.

**Check:** ask 10+ follow-ups about one photo and watch for the moment answers
stop referring to the image. Then try `nCtx: 4096` and compare. Also try
`.DO_NOT_CLEAN_UP` and see whether it errors or truncates.
**This is the most likely next bug.**

### 2. No sampling control on the remote-init path

`SamplingParams(temperature:topK:topP:maxTokens:)` exists, but only
`init(localZtcURL:…samplingParams:)` accepts it. The
`init(personalKey:name:…)` path has no such parameter, and `respond()` takes
none either — so temperature and `maxTokens` (default 256) appear unsettable
when loading a hosted model.

**Check:** whether long answers truncate at 256 tokens. If so, ask the SDK team to
expose `SamplingParams` on the remote initialiser or on `respond()`.

### 3. Cancellation does not appear to exist

There is no `stop()`/`cancel()` on the model. Cancelling the Swift `Task` stops
*consuming* the stream, but native generation probably continues to completion —
wasting battery and possibly leaving the next call queued behind it.

**Check:** cancel mid-generation, then immediately ask again, and time it. If the
second answer is delayed by roughly the remainder of the first, generation did not
stop. Worth an SDK ask.

### 4. Multiple images in one conversation

`spliceStagedMedia` attaches the staged image to the **first** user turn, so
interleaved multi-image chat is not supported today. The SDK team tracks this as
a separate epic (per-turn media placement).

**Check:** nothing to do until that lands — but don't design a UI around
comparing two images in one turn.

### 5. Backgrounding during generation

Untested. iOS may suspend the app mid-stream; the model holds ~1.5 GB, making it a
prime jetsam target.

**Check:** start a long answer, background the app for 30 s, return. Look for a
crash, a stalled stream, or silent truncation.

### 6. Thermal and battery behaviour under sustained use

Untested. NPU prefill plus CPU vision encoding is heavy; sustained use may throttle.

**Check:** 20 consecutive questions, watching tokens/sec (the app already records
it per turn) for degradation.

### 7. Concurrent `respond()` calls

Our actor serialises them, so the SDK's behaviour under concurrent calls is
unknown.

**Check:** only if you plan to drop the actor. Otherwise keep serialising.

### 8. Function calling combined with vision

`registerTool` / `functionCallingSystemPrompt` exist on the same class, but we
never combined them with `respond(…image:)`.

### 9. Whether `close()` + re-init is safe in-process

We saw one SIGSEGV, but the device was out of space and the model was truncated,
so it proves nothing. Low priority now that `cleanUp()` removes the need.

### 10. Storage — the remaining SDK-side work

Not fixable from an app. Tracked in
[SDK-STORAGE-DEFECT.md](SDK-STORAGE-DEFECT.md): ~6.3 GB for a 1.6 GB model,
~1.5 GB added per launch with no eviction, extraction truncating silently when the
disk is full, and `.ztc` archives accumulating (confirmed in a stock Zetic demo
app we never modified).

---

## Where to look in this repo

| Need | File |
|---|---|
| Session contract, image conversion, build setup | [LFM-VL-INTEGRATION-GUIDE.md](LFM-VL-INTEGRATION-GUIDE.md) |
| Model ownership, `cleanUp()` placement | [`Core/VisionEngine.swift`](../ZeticMLangeLLMSample/Core/VisionEngine.swift) |
| `UIImage` → packed RGB | [`Core/UIImage+ZeticRGB.swift`](../ZeticMLangeLLMSample/Core/UIImage+ZeticRGB.swift) |
| Safe storage cleanup, with the unsafe paths documented | [`Core/ModelStorageJanitor.swift`](../ZeticMLangeLLMSample/Core/ModelStorageJanitor.swift) |
| On-device file logging | [`Core/TraceLog.swift`](../ZeticMLangeLLMSample/Core/TraceLog.swift) |
| Load phases, streaming, metrics | [`ViewModel/VisionChatViewModel.swift`](../ZeticMLangeLLMSample/ViewModel/VisionChatViewModel.swift) |
| Everything we hit and how it was found | [ISSUES-ENCOUNTERED.md](ISSUES-ENCOUNTERED.md) |
| Storage analysis for the SDK team | [SDK-STORAGE-DEFECT.md](SDK-STORAGE-DEFECT.md) |
| Raw device trace | [vlm-trace-example.log](vlm-trace-example.log) |

---

## If you are an AI agent starting a new VLM app

1. Copy `Core/VisionEngine.swift`, `Core/UIImage+ZeticRGB.swift`,
   `Core/ModelStorageJanitor.swift` and `Core/TraceLog.swift`. They encode most of
   this document.
2. Apply DO 1–4 before writing any UI.
3. Read the DON'T list in full. Every entry cost real time or real damage to a
   device.
4. Test on a physical device with ≥7 GB free. There is no simulator slice, and a
   full disk produces a silent SIGSEGV rather than an error.
5. Verify **both** photo switching *and* same-image follow-ups. They break in
   opposite directions and one passing does not imply the other.
