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

**What this implies.** `respond(systemPrompt:userText:image:)` retains state
between calls. Combined with issue 3, an app cannot clear that state, so the
only remedy available today is to tear down and recreate the whole model per
image — see issue 5 for why that also fails.

**Note.** The MLLM backend reports itself as *not* KV-persistence-capable
(issue 3), which would suggest `respond()` is stateless. The observed behaviour
contradicts that. Clarifying which is true is the key question for the SDK team.

**Ask.** How should an application ask about a second image?

## 5. Recreating the model crashes with SIGSEGV — **BLOCKER**

Working around issue 4 by calling `model.close()` and re-initialising a new
`ZeticMLangeLLMModel` in the same process crashes:

```
App terminated due to signal 11
```

**Ask.** Is `close()` followed by a new `init` supported in-process? Zetic's own
`ZeticMLangeValidationLab/LfmVL` reference creates a model per run and closes it
in a `defer`, which suggests it should be — but it segfaults here.

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

This filled a 256 GB iPhone to the point where a 28 MB build could not install.

## 7. No GGUF build published for this model — **request**

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

## Lesson recorded for whoever picks this up

Do **not** clear `Library/Caches/<bundle-id>` in an attempt to reclaim space. It
holds `com.apple.e5rt.e5bundlecache` (Apple's Neural Engine bundle cache) and
`Cache.db` (NSURLSession). We tried it; the result was a full ANE recompile on
every launch plus repeated 1.76 GB re-downloads, because the SDK appears to keep
backend-selection state there too (cf. `invalidateBackendSelectionCaches()`).
The app's own `tmp/` is safe to sweep. `Application Support/ZeticMLangeCache`
must not be touched — deleting the live `.ztc` forces a full re-download.
