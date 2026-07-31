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

## 3. `resetKVState()` unsupported on the CoreML backend — **BLOCKER, no workaround**

```
[VLM] resetKVState THREW: resetKVState is only supported on
      KV-persistence-capable backends (current target: MLLM)
```

`ZeticMLangeLLMModel.resetKVState()` throws on every call when the selected
target is `MLLM` (CoreML). It only works on `LLAMA_CPP`.

**Impact.** There is no supported way to clear model context on the CoreML
backend. See issue 4 — this is what makes the stale-image bug unfixable from
application code.

**Ask.** Either implement reset for MLLM, or expose an equivalent (the SDK has
`MultimodalPipeline.resetSession()` and a `mlange_multimodal_reset` C entry
point, but neither is reachable from `ZeticMLangeLLMModel`).

## 4. VLM answers describe the *previous* image — **BLOCKER, user-visible**

**Reproduction**

1. Select photo A, ask "What is this image about?" → correct description of A.
2. Select photo B (visually unrelated), ask the same question.
3. **The answer describes photo A again.**

Confirmed by the app's author: photo A was a woman standing in a garden; after
switching to an unrelated photo, the model re-described the garden photo.

**Instrumented proof.** The app logs an FNV fingerprint of the exact RGB buffer
handed to `respond()`. Three consecutive photos in one session:

| Question | Fingerprint | Answer |
|---|---|---|
| A | `13912044058735840761` | "round table, **black** surface, wine glass of deep red liquid, white plate" |
| B | `10048966414806669662` | "**white** table, several plates of food, two wine glasses" |
| C | `9590206458097600543` | "various objects on a table, white plates, two wine glasses, white tablecloth" |

Raw trace:

```
ask imageID=3857AB0B contextImageID=none     rgb=384x512 fingerprint=13912044058735840761
ask imageID=DEA86212 contextImageID=3857AB0B rgb=384x512 fingerprint=10048966414806669662
ask imageID=C3A717A8 contextImageID=DEA86212 rgb=384x512 fingerprint=9590206458097600543
```

**Every fingerprint differs**, so a genuinely different image reaches the model
each time. Yet all three answers describe photo A's dining scene, growing vaguer
with each turn. Photos B and C were not dining scenes.

**Controlled comparison — the same image, two different answers.** The image with
fingerprint `9590206458097600543` was submitted twice, byte for byte identical:

| Context | Answer |
|---|---|
| 3rd photo of a session that had already answered about two others | "various objects on a table, white plates, two wine glasses, white tablecloth" ❌ |
| 1st photo after a force-quit (fresh process) | "metallic art displayed in a white storage chest… large silver bucket… golden" ✅ |

The only variable is whether the process had previously answered about another
photo. The second answer is correct; the first is a paraphrase of the *first*
photo in that session.

**Force-quitting between photos always produces correct answers.** Verified for
three different images in a row, each in its own process:

```
session start
ask imageID=A7B537D5 contextImageID=none fingerprint=4756827734280873181
answer: "a top-down view of a brown cardboard box … white, paper towel-lined countertop … kitchen setting"

session start
ask imageID=AFF85CD0 contextImageID=none rgb=512x283 fingerprint=14439312451596884767
answer: "Here is the text from the card: …"
```

**What this implies.** The retained state lives in the model instance / native
side and dies with the process. It is not reachable through any public API on
`ZeticMLangeLLMModel` — `resetKVState()` throws (issue 3), and reloading the
model in-process clears it but is unshippable on storage grounds (below).
A process restart is the only reliable clear.

**The contradiction we need resolved.** The MLLM backend reports itself as *not*
KV-persistence-capable (issue 3, hence `resetKVState()` throwing), which would
imply `respond()` is stateless. The trace above shows it is not. Whatever holds
that state is not reachable through any public API on `ZeticMLangeLLMModel`.
**This is the single most important question for the SDK team.**

**There is no viable workaround.** We tried reloading the whole model on every
photo change (`VisionEngine.rebuild()`). It *does* clear the context and produce
correct answers — but it is unshippable:

- Each reload **re-extracts ~1.5 GB and re-compiles ~1.5 GB**, and nothing
  reclaims either until the next launch (issues 6 and 7).
- Three photo switches in one session took the container from ~5 GB to
  **roughly 35 GB** and filled a 256 GB device. It then fell back to 5.29 GB on
  its own when iOS purged `Library/Caches` under pressure, which is why a
  container measurement taken minutes later disagrees with what Settings showed.

So the choice today is between a wrong answer and a bricked phone. This app now
does neither: it refuses the second photo with an explicit message telling the
user to relaunch. **Fixing this properly requires an SDK change** — either a way
to clear vision context, or caching that does not duplicate the model per load.

**Ask.** How should an application ask about a second image?

## 5. Recreating the model crashes with SIGSEGV — **BLOCKER**

Working around issue 4 by calling `model.close()` and re-initialising a new
`ZeticMLangeLLMModel` in the same process crashes:

```
App terminated due to signal 11
```

**Caveat on this one.** The crash occurred while the device was out of space and
the extracted model was truncated (issue 7), so it may have been a corrupt-model
crash rather than an API limitation. With storage healthy the app now reloads
the model on every photo change as the workaround for issue 4 — whether that is
stable is the open question.

**Ask.** Is `close()` followed by a new `init` supported in-process? Zetic's own
`ZeticMLangeValidationLab/LfmVL` reference creates a model per run and closes it
in a `defer`, which suggests it should be. If it is supported, it is currently
the *only* way to ask about a second image — so its stability matters a great
deal.

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
