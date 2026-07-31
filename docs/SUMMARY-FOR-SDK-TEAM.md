# ZeticMLange 1.9.0 — summary for the SDK team

One page. Details in [ISSUES-ENCOUNTERED.md](ISSUES-ENCOUNTERED.md) and
[SDK-STORAGE-DEFECT.md](SDK-STORAGE-DEFECT.md); raw evidence in
[vlm-trace-example.log](vlm-trace-example.log).

**Setup:** iPhone 16 Pro · iOS 26.0.1 · A18 Pro · `changgeun/LFM2.5-VL-450M`
(`coreml_1f2826b9`, model_key `f359a1c7730640ce89e5fce7e864c9d7`) · SDK 1.9.0.

---

## The headline

**Multi-image VLM cannot ship on the CoreML backend today.** Two defects
compound, and neither is fixable from application code:

1. `respond(…image:)` **retains vision context** across calls, so the second
   photo returns the first photo's description, and no public API clears it.
2. The obvious remedy — reloading the model — **duplicates ~3 GB on disk per
   load**, so it cannot be used freely. (We could not validate it: our one
   attempt crashed, though under out-of-disk conditions that make it
   inconclusive.)

The only clear we have verified is a **process restart**. Ours therefore refuses
the second photo and asks the user to relaunch.

---

## Ranked asks

| # | Ask | Why it matters |
|---|---|---|
| 1 | **Publish a GGUF / `LLAMA_CPP` build of LFM2.5-VL-450M** | Highest leverage by far — `resetKVState()` is supported on that target, and a Q4_K_M build is a few hundred MB instead of four copies of 1.5 GB. Plausibly resolves asks 2–4 at once. Our app already requests it; no code change needed. |
| 2 | **A way to clear vision context on MLLM** | `resetKVState()` throws: *"only supported on KV-persistence-capable backends (current target: MLLM)"*. `MultimodalPipeline.resetSession()` and `mlange_multimodal_reset` exist but are unreachable from `ZeticMLangeLLMModel`. |
| 3 | **Stop duplicating the model per load** | Each init writes a fresh extraction (~1.5 GB) and compiled set (~1.5 GB); neither replaces its predecessor. This is what makes ask 2's workaround unusable. |
| 4 | **Stabilise the compiled-artifact cache key** | A new `zetic_coreml_compiled/<hash>` appears every launch for the same model on the same device, so the cache never hits — ~1.4 GB recompiled on **every cold start**, and nothing evicted. |
| 5 | **Fail loudly on insufficient storage** | With a full disk, extraction truncated silently (directory tree present, weight files absent) and inference later **segfaulted**. Validate the extracted set before handing it to CoreML. |
| 6 | **Replace `.ztc` on re-download** | Despite `REMOVE_OVERLAPPING`, re-downloads add a new `llmTargetModel-<hash>`. Confirmed in **Live Translate MT2** (untouched stock demo): four copies of one model, 4.49 GB. |
| 7 | **Restore `Accelerate` to `Package.swift`** | 1.9.0's bare `binaryTarget` dropped the linker setting 1.4.5 carried. Every upgrader fails to link with missing `vDSP_*` until they add `-framework Accelerate`. Undocumented in the release notes. |

---

## The single most convincing piece of evidence

The same image — **byte-for-byte identical**, fingerprint `9590206458097600543` —
submitted twice:

| Context | Answer |
|---|---|
| 3rd photo of a session that had answered about two others | "various objects on a table, white plates, two wine glasses, white tablecloth" ❌ |
| 1st photo after a force-quit (fresh process) | "metallic art displayed in a white storage chest… large silver bucket… golden" ✅ |

The only variable is whether the process had previously answered about another
photo. This rules out the image pipeline and locates the state in the model
instance, where it dies only with the process.

---

## Two measurement traps

Anyone trying to reproduce should know:

- **Container size shrinks on its own.** iOS purges `Library/Caches` under
  pressure. We observed ~35 GB drop back to 5.29 GB unaided;
  `zetic_coreml_compiled` reading zero entries is the signature. A measurement
  taken minutes after the user's Settings screenshot will legitimately disagree.
- **Do not clear `Library/Caches/<bundle-id>` to reclaim space.** It holds
  `com.apple.e5rt.e5bundlecache` (Apple's ANE cache) and `Cache.db`, not Zetic
  data. We tried; it forced ANE recompiles *and* repeated 1.76 GB re-downloads,
  and we initially misattributed both to the SDK.
  `ModelStorageJanitor.swift` documents which directories are safe.
