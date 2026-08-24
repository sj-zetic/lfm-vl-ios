# ZeticMLange 1.9.0 — summary for the SDK team

One page. Details in [ISSUES-ENCOUNTERED.md](ISSUES-ENCOUNTERED.md) and
[SDK-STORAGE-DEFECT.md](SDK-STORAGE-DEFECT.md); raw evidence in
[vlm-trace-example.log](vlm-trace-example.log).

**Setup:** iPhone 16 Pro · iOS 26.0.1 · A18 Pro · `changgeun/LFM2.5-VL-450M`
(`coreml_1f2826b9`, model_key `f359a1c7730640ce89e5fce7e864c9d7`) · SDK 1.9.0.

---

## The headline

**The image-switching bug is resolved and was our API misuse, not an SDK bug.**
`cleanUp()` must be called when the image changes; we never called it. Fixed in
[PR #1](https://github.com/sj-zetic/lfm-vl-ios/pull/1), root cause in
[ISSUES-ENCOUNTERED.md](ISSUES-ENCOUNTERED.md) issue 4. The discoverability
follow-ups — error text naming `cleanUp()`, session-contract docs on the public
`respond` entry points, and a native regression test on staged-media placement —
are already ticketed by the SDK team.

**Storage is the remaining substantive issue and is not covered by that ticket.**
A 1.6 GB model occupies 6.30 GB on a clean run and grows ~1.5 GB per launch with
no eviction. In our testing that filled a 256 GB iPhone until the app could no
longer be reinstalled and inference segfaulted on a truncated model.

For integrators rather than SDK maintainers, see
[LFM-VL-INTEGRATION-GUIDE.md](LFM-VL-INTEGRATION-GUIDE.md).

## Ranked asks

| # | Ask | Why it matters |
|---|---|---|
| 1 | **Stop duplicating the model per load** | Each init writes a fresh extraction (~1.5 GB) and compiled set (~1.5 GB); neither replaces its predecessor. 6.30 GB on disk for a 1.6 GB model. |
| 2 | **Stabilise the compiled-artifact cache key** | A new `zetic_coreml_compiled/<hash>` appears every launch for the same model on the same device, so the cache never hits — ~1.4 GB recompiled on **every cold start**, and nothing evicted. |
| 3 | **Publish a GGUF / `LLAMA_CPP` build of LFM2.5-VL-450M** | Still valuable: a Q4_K_M build is a few hundred MB rather than four copies of 1.5 GB, and would sidestep the CoreML storage behaviour entirely. Our app already requests it; no code change needed. |
| 4 | **Fail loudly on insufficient storage** | With a full disk, extraction truncated silently (directory tree present, weight files absent) and inference later **segfaulted**. Validate the extracted set before handing it to CoreML. |
| 5 | **Replace `.ztc` on re-download** | Despite `REMOVE_OVERLAPPING`, re-downloads add a new `llmTargetModel-<hash>`. Confirmed in **Live Translate MT2** (untouched stock demo): four copies of one model, 4.49 GB. |
| 6 | **Restore `Accelerate` to `Package.swift`** | 1.9.0's bare `binaryTarget` dropped the linker setting 1.4.5 carried. Every upgrader fails to link with missing `vDSP_*` until they add `-framework Accelerate`. Undocumented in the release notes. |

---

## How the context bug looked before we found `cleanUp()`

Kept because it shows how the missing call presents — silently wrong answers, no
error anywhere. The same image, **byte-for-byte identical** (fingerprint
`9590206458097600543`), submitted twice:

| Context | Answer |
|---|---|
| 3rd photo of a session that had answered about two others, no `cleanUp()` | "various objects on a table, white plates, two wine glasses, white tablecloth" ❌ |
| 1st photo of a fresh process | "metallic art displayed in a white storage chest… large silver bucket… golden" ✅ |

With `cleanUp()` called after each generation, three unrelated photos in a single
session are all answered correctly and no relaunch is needed.

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
  The app now leaves model storage to the SDK rather than attempting cleanup.
