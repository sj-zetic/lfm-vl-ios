# Issues encountered building an LFM-VL app on ZeticMLange 1.9.0

Everything below was observed on a real device while building this app. Each
entry says what happened, how it was found, and where it stands.

**Environment:** ZeticMLangeiOS 1.9.0 · iPhone 16 Pro (iPhone17,1) · iOS 26.0.1 ·
A18 Pro · model `changgeun/LFM2.5-VL-450M` (model_key
`f359a1c7730640ce89e5fce7e864c9d7`, `coreml_1f2826b9`) · Xcode 26.4

---

## 1. Build fails to link: missing `vDSP_*` symbols — **BLOCKER, workaround known**

```
Undefined symbols for architecture arm64:
  "_vDSP_dotpr", referenced from: _ggml_vec_dot_f32 in ZeticMLange[arm64](vec.cpp.o)
  "_vDSP_vsmul", "_vDSP_sve", "_vDSP_vadd", …
ld: symbol(s) not found for architecture arm64
```

**Cause.** In 1.4.5 the package wrapped the binary in a `ZeticMLangeWrapper`
target carrying `.linkedFramework("Accelerate")`. In 1.9.0 `Package.swift` is a
bare `binaryTarget` with no `linkerSettings`, so `Accelerate` is no longer
linked transitively.

**Workaround.** Add to the app target:

```
OTHER_LDFLAGS = "-framework Accelerate"
```

**Ask.** Restore the linker setting in the package, or document it in the
release notes. Every project upgrading from ≤1.8 hits this.

## 2. No simulator slice — **by design? please confirm**

`ZeticMLange.xcframework` ships `ios-arm64` only. There is no
`ios-arm64-simulator`, so the app cannot build or run in the iOS Simulator at
all. All development and testing must be on a physical device.

## 3. `resetKVState()` unsupported on the CoreML backend — **misleading, not blocking**

```
[VLM] resetKVState THREW: resetKVState is only supported on
      KV-persistence-capable backends (current target: MLLM)
```

`ZeticMLangeLLMModel.resetKVState()` throws on every call when the selected
target is `MLLM` (CoreML). It only works on `LLAMA_CPP`.

**Impact.** Not blocking — `cleanUp()` clears context and works on this backend
(issue 4). But the error message says a reset is unavailable, which is false, and
it cost us a great deal of time.

**Ask.** Either implement reset for MLLM as an alias for `cleanUp()`, or change
the message to name the supported call.

## 4. VLM answers describe the *previous* image — **RESOLVED: our API misuse**

> **Resolved** by calling `ZeticMLangeLLMModel.cleanUp()` when the image changes.
> This was not an SDK bug. The remaining SDK work is discoverability, tracked by
> the Zetic team.

**Symptom.** Ask about photo A, get a correct answer. Switch to photo B and ask
again: the answer describes photo A.

**Root cause** (from the SDK team, confirmed against the native source):

`respond(…image:)` appends to a live transcript — `lm::TurnRunner` owns
`messages_` and re-renders it whole each turn — and
`prompt_input::spliceStagedMedia` attaches the newly staged image to the
**first** user turn of that transcript. So the second question is prompted with:

```
user:      <photo B pixels>  "turn 1's question"
assistant: "<photo A's description>"
user:      "turn 2's question"      ← no image attached
```

Photo B's pixels land in turn 1's slot, photo A's answer is still in context, and
the actual question carries no image at all. Repeating photo A's description is
the *correct* output for that prompt.

**The fix.** Call `cleanUp()` before asking about a different image — it clears
the transcript, the KV cache and the staged media in one call
(`cleanUp` → `LocalLfmVLModel.resetSession` → `vl_runner_reset_session` →
`GenericVlRunner::resetSession`):

```swift
if imageChanged { try model.cleanUp() }
```

**Do not call it between follow-up questions about the same image.** Context
persistence across calls is intentional and is what makes follow-ups work.

Verified — three unrelated photos in one session, each answered correctly:

```
ask imageID=98BFDE94 contextImageID=none     fingerprint=4756827734280873181
answer: "five vegetables on a white paper towel — yellow pepper, red pepper…"
ask imageID=CF3E8AC9 contextImageID=98BFDE94 fingerprint=10560470522907394792
image changed -> calling cleanUp() … succeeded
answer: "a hand holding a clear glass bowl containing several peeled apples"
ask imageID=AE516749 contextImageID=CF3E8AC9 fingerprint=13075407507220586608
image changed -> calling cleanUp() … succeeded
answer: "a slightly blurry scene focusing on a white towel … cotton"
```

**Why this took so long — the discoverability defect.** The obvious candidate,
`resetKVState()`, throws on this backend:

```
resetKVState is only supported on KV-persistence-capable backends
(current target: MLLM)
```

That reads as "this backend cannot clear context", which is false. It sent this
app through a model-reload workaround and then a force-quit-between-photos
workaround before `cleanUp()` was found. `cleanUp()` is undocumented, is not
obviously a session reset from its name, and the `LfmVL` reference sample hides
the requirement by creating a fresh model per run.

**Being addressed by the SDK team:** error text on the unsupported KV operations
will name `cleanUp()`; the public VL `respond` entry points on iOS, Android and
Flutter will document the session contract; and a native regression test will pin
where staged media lands in a multi-turn transcript.

## 5. Recreating the model crashes with SIGSEGV — **low priority now**

> With issue 4 resolved, recreating the model is no longer necessary. Kept for
> the record; the crash also occurred while the device was out of space and the
> extracted model was truncated (issue 7), so it may not be an API problem.

Working around issue 4 by calling `model.close()` and re-initialising a new
`ZeticMLangeLLMModel` in the same process crashes:

```
App terminated due to signal 11
```

**Ask.** Low priority: is `close()` followed by a new `init` supported
in-process? Worth confirming, since the `LfmVL` reference creates a model per run
and closes it in a `defer`.

## 6. Storage: ~6.3 GB for a 1.6 GB model, growing per launch — **MAJOR**

Full analysis in [SDK-STORAGE-DEFECT.md](SDK-STORAGE-DEFECT.md). Summary:

- One cold run stores the model **four times** (archive, extracted, compiled,
  staged) — 6.30 GB measured on a clean install.
- The compiled-artifact cache key changes every launch, so CoreML **recompiles
  ~1.4 GB on every cold start** and the old copies are never evicted. Measured
  on a clean baseline: `zetic_coreml_compiled` went from 4 entries (1.54 GB) to
  8 entries (3.08 GB) after a single relaunch.
- Extracted `.mlpackage`s are written to `Documents/`, which iOS never purges
  and iCloud backs up.

- Extracted models accumulate too: `Documents/NativeLfmVL` measured **3.08 GB —
  two full extractions** — after a fresh install, one added per model load with
  nothing removing the previous.
- Downloaded `.ztc` archives accumulate despite
  `cacheHandlingPolicy: .REMOVE_OVERLAPPING`. Confirmed in **Live Translate MT2**,
  a stock Zetic demo app we never modified: **four** `llmTargetModel-*` copies of
  one model, 4.49 GB in `Application Support`, 4.77 GB total.

This filled a 256 GB iPhone to the point where a 28 MB build could not install.
See issue 7 for how that escalates into an unrecoverable crash.

## 7. Storage exhaustion bricks the app: truncated extraction → SIGSEGV — **CRITICAL**

This is issue 6 taken to its conclusion, and it is the most damaging behaviour we
hit. It turned a storage annoyance into an unrecoverable app.

**Sequence**

1. Each launch adds ~1.5 GB of compiled artifacts to
   `Library/Caches/zetic_coreml_compiled` and evicts nothing (issue 6). After
   repeated launches we measured **15 entries, 7.19 GB**, container total 9.41 GB.
2. The device reached **0 bytes free**.
3. The SDK still attempted to extract the model. Extraction **silently
   truncated**: `Documents/NativeLfmVL` held 19 directory entries totalling
   ~0 bytes — the folder tree existed, the weight files did not.
4. The SDK then loaded that incomplete model and crashed during inference:

   ```
   [VLM] ask imageID=3BB14721 contextImageID=none rgb=384x512 fingerprint=1747114493727569960
   [VLM] first image -> nothing to clear
   App terminated due to signal 11
   ```

5. **The app could not be recovered by reinstalling**: with 0 bytes free, even a
   28 MB install fails —

   ```
   Not enough space for … PromiseStaging/… :
   28284324 bytes needed, 0 bytes available (0 bytes were purged)
   ```

   The wasted 7.19 GB lives *inside the app container*, so the only way out was to
   delete the app entirely, which also discards the 1.76 GB model and forces a
   full re-download.

**Asks**

- **Fail loudly when disk space is insufficient.** A truncated extraction that
  later segfaults during inference is the worst possible failure mode. Verify the
  extracted artifact set (size or checksum) before handing the model to CoreML,
  and surface a clear "insufficient storage" error.
- **Evict compiled artifacts**, so this state is not reachable in normal use.
- Consider whether extraction can stream from the `.ztc` rather than requiring a
  second full copy on disk.

## 8. No GGUF build published for this model — **request**

Passing `quantType: .GGUF_QUANT_Q4_K_M` has no effect; backend selection returns
CoreML regardless:

```json
"selection_mode": "AUTO", "total": 9,
"ztc_id": "coreml_1f2826b9", "download_size": 1756011264,
"configuration": "{prefill: NPU, decode: NPU,
                   vision_encoder: CPU, vision_projector: CPU}"
```

All 9 candidates are CoreML run-configurations. A llama.cpp/GGUF build would
plausibly fix issues 3, 4 and 6 at once — `resetKVState()` is supported on that
target, and a Q4_K_M build of a 450M model is a few hundred MB rather than four
copies of 1.5 GB.

**Ask.** Can a GGUF build of LFM2.5-VL-450M be published? This app already
requests it, so it would take effect with no code change.

---

## Which directories an app may safely clean

Learned the hard way. `Core/ModelStorageJanitor.swift` encodes all of this.

| Directory | Safe to delete? | Why |
|---|---|---|
| `tmp/` | **Yes** | The app's own temp dir. The SDK abandons ~1.5 GB of `.mlmodelc` here per launch. |
| `Caches/zetic_coreml_compiled` | **Yes, and necessary** | Zetic's compiled cache. Entries are never reused (new hash every launch), and leaving them fills the device — see issue 7. |
| `Caches/<bundle-id>` | **No — breaks the app** | Not Zetic's. Holds `com.apple.e5rt.e5bundlecache` (Apple's ANE bundle cache) and `Cache.db` (NSURLSession). Clearing it forced a full ANE recompile every launch *and* repeated 1.76 GB re-downloads, since the SDK appears to keep backend-selection state here too (cf. `invalidateBackendSelectionCaches()`). |
| `Application Support/ZeticMLangeCache` | **No** | The downloaded `.ztc`. Deleting it forces a full re-download. `ModelCacheManager.prune()` is the only supported way to touch it. |
| `Documents/NativeLfmVL` | **Not while in use** | Extracted `.mlpackage`s the loaded model reads from. |

The net effect of the safe subset is bounded growth, not a small app: the SDK
still writes the model to disk several times over per cold run, and no
application-side cleanup can change that.
