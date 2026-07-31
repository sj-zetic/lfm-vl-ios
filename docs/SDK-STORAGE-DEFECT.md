# ZeticMLange iOS — unbounded on-device storage growth

**SDK:** ZeticMLangeiOS 1.9.0
**Device:** iPhone 16 Pro (iPhone17,1), iOS 26.0.1, A18 Pro
**Model:** `changgeun/LFM2.5-VL-450M` → `coreml_1f2826b9.ztc`, model_key `f359a1c7730640ce89e5fce7e864c9d7`
**Backend:** CoreML, `status: BENCHMARKED`, `match_level: SOC_MODEL`

## Summary

A minimal app around `ZeticMLangeLLMModel` grows to **~10 GB of container for a
1.76 GB model**, and keeps growing by roughly **700 MB per launch**. On the test
device this eventually made the phone unable to install a 28 MB build.

This is not app-specific. Four unrelated ZeticMLange apps on the same phone:

| App | Size |
|---|---|
| AI 개인비서 | 8.22 GB |
| ZeticMLangeLLMSample (this app, 27 MB binary) | 6.84 GB |
| Brew-Gemma | 5.91 GB |
| Litve Translate MT2 | 4.83 GB |

## Measurement

```
xcrun devicectl device info files --device <udid> \
  --domain-type appDataContainer --domain-identifier com.sjk.lfmvision
```

| Location | Size | Contents |
|---|---|---|
| `Library/Caches/zetic_coreml_compiled/` | **3.59 GB** | 7 compiled `.mlmodelc` copies |
| `tmp/` | **2.92 GB** | 7 abandoned `.mlmodelc` bundles |
| `Library/Caches/<bundle-id>/` | **1.36 GB** | CoreML spill |
| `Library/Application Support/ZeticMLangeCache/` | 1.64 GB | the downloaded `.ztc` — legitimate |
| `Documents/NativeLfmVL/` | 0.86 GB | extracted `.mlpackage`s, one set per launch |
| **Total** | **~9.7 GB** | for a 1.76 GB model |

The shipped `.app` bundle is 27 MB. All of the above is runtime data.

### The clearest evidence: one cold run stores the model four times

Measured on a **fresh install after exactly one launch** — no accumulation
involved:

| # | Copy | Size | Location |
|---|---|---|---|
| 1 | Downloaded archive | 1.64 GB | `Application Support/ZeticMLangeCache` (`.ztc`) |
| 2 | Extracted | 1.54 GB | `Documents/NativeLfmVL` (`.mlpackage`) |
| 3 | Compiled | 1.54 GB | `Caches/zetic_coreml_compiled` (`.mlmodelc`) |
| 4 | Staged | 1.54 GB | `tmp/` |
| | **Total** | **6.46 GB** | for a 1.6 GB model |

So there are two compounding problems: **4× duplication on every cold run**, and
**unbounded accumulation across launches** (below). Neither the staged copy nor
the superseded compiled copies are ever removed.

---

## Defect 1 — compiled-artifact cache key is not stable across launches (primary)

Each launch creates a **new** hash-named directory under
`Library/Caches/zetic_coreml_compiled/` for the *same* model on the *same*
device:

```
a3405fe82a329ac2.mlmodelc   6:24 PM   ← launch 1
d36b9aeb37db1745.mlmodelc   6:24 PM
7cfe577df3b187d2.mlmodelc   6:25 PM
ac8c15c5f053fe19.mlmodelc   6:28 PM   ← launch 2
f88a31236b767f31.mlmodelc   6:29 PM   ← launch 3
6959135b62ed3c79.mlmodelc   6:35 PM   ← launch 4
8cf8140789f408c0.mlmodelc   6:52 PM   ← launch 5
```

Each `prefill` copy is 684 MB, each `decode` copy 676 MB.

**Direct proof the cache never hits:** we deleted all but the four newest
entries, then launched again. Rather than reusing any retained artifact, the SDK
compiled a brand-new one (`8cf8140789f408c0`, 6:52 PM).

**Consequences**

1. Storage grows without bound, ~700 MB per launch.
2. CoreML recompiles ~1.4 GB of model on **every cold start** — this is also a
   significant, entirely avoidable startup-latency cost.

**Expected:** the key should be derived from model identity + run config +
device/OS/compiler version, so an unchanged model on an unchanged device
compiles once and is reused thereafter.

## Defect 2 — no eviction

Nothing in `zetic_coreml_compiled/` is ever removed. Combined with Defect 1,
growth is unbounded. Even with a stable key, an LRU cap would be appropriate.

## Defect 3 — `tmp/` is never cleaned

Intermediate bundles are left in the app's temp directory and accumulate across
launches:

```
tmp/prefill.mlmodelc                                        684 MB
tmp/prefill_2720574E-019F-474B-A28A-EF9DCE35F7B8.mlmodelc   684 MB
tmp/prefill_635E5687-A5D5-444C-AAE1-AD522D402A70.mlmodelc   684 MB
tmp/decode.mlmodelc                                         676 MB
tmp/decode_C5894C97-4D5F-4E7F-BFDC-5769DB49B933.mlmodelc    676 MB
tmp/vision_encoder.mlmodelc                                 163 MB
tmp/71E6BD70…B855/                                          560 MB   (opaque, no extension)
```

The UUID-suffixed copies appear when a second `ZeticMLangeLLMModel` is created
in one process. Staged files should be removed once compilation completes, and
on init the SDK should clear its own previous leftovers.

## Defect 4 — regenerable artifacts written to `Documents/`

Extracted packages are written to
`Documents/NativeLfmVL/<modelKey>/<archive>.ztc-<hash>/`.

`Documents/` is the wrong location for regenerable data:

- iOS never purges it, even under storage pressure.
- It is included in iCloud/iTunes backups, so multiple GB per app count against
  the user's iCloud quota.
- Apple's [iOS Data Storage Guidelines][guidelines] specifically call this out;
  it is a plausible App Review rejection.

`Application Support` or `Caches`, with `isExcludedFromBackup` set, would be
correct. A new hash directory also appears per launch here, with no eviction.

[guidelines]: https://developer.apple.com/icloud/documentation/data-storage/

## Defect 5 — `ModelCacheManager.prune()` does not cover any of the above

`prune()` is the only supported cleanup entry point, but it does not touch
`zetic_coreml_compiled`, `tmp/`, or the `Documents/NativeLfmVL` extractions —
which together are ~85% of the footprint. Applications currently have no
supported way to reclaim this space.

---

## Suggested fixes, in priority order

1. **Make the compiled-artifact cache key content-addressed and stable.** Fixes
   both the growth and the per-launch recompile. Highest value by far.
2. **Delete staged `tmp/` artifacts** after compilation, and sweep leftovers on init.
3. **Add eviction** (LRU or keep-current) to `zetic_coreml_compiled`.
4. **Move extracted packages out of `Documents/`**, and set
   `isExcludedFromBackup` on all large SDK-owned directories.
5. **Extend `prune()`** to cover every directory the SDK writes, so apps have a
   supported remedy while the above lands.

## Clean-baseline confirmation

An earlier version of our workaround also cleared `Library/Caches/<bundle-id>`.
That was our mistake — that directory holds Apple's
`com.apple.e5rt.e5bundlecache` and `Cache.db`, not Zetic data, and clearing it
forced ANE recompiles and repeated re-downloads. **Everything below was
re-measured after removing that step**, so none of it is self-inflicted.

Clean install, one launch, janitor limited to sweeping the app's own `tmp/`:

| Area | Size |
|---|---|
| `Application Support/ZeticMLangeCache` | 1.64 GB |
| `Documents/NativeLfmVL` | 1.54 GB |
| `Caches/zetic_coreml_compiled` | 1.54 GB (4 entries) |
| `tmp/` | 1.54 GB |
| **Total** | **6.30 GB** |

Then a single relaunch, nothing else changed:

| Area | After 1 launch | After 2 launches |
|---|---|---|
| `ZeticMLangeCache` archives | 1 dir (`llmTargetModel-15a2f2fe…`) | **1 dir, unchanged** |
| `Caches/zetic_coreml_compiled` | 1.54 GB, 4 entries | **3.08 GB, 8 entries** |
| **Container total** | 6.30 GB | **8.00 GB** |

This isolates Defect 1 cleanly: the downloaded archive is correctly reused
across launches, while the **compiled artifacts double on every launch** because
their cache key is not stable. Nothing evicts them.

## Defect 6 — downloaded `.ztc` archives accumulate, confirmed in an untouched app

`ModelCacheHandlingPolicy.REMOVE_OVERLAPPING` is the default, but re-downloads
add a new `llmTargetModel-<hash>` directory rather than replacing the previous
one, and nothing removes the old ones.

We first saw this in our own app but withdrew the claim, because our cleanup code
had (wrongly) been clearing `Caches/<bundle-id>` and could have caused the
re-downloads itself. It is now confirmed independently in **Live Translate MT2**
(`com.zeticai.demo.livetranslatehymt2`), a stock Zetic demo app on the same
device that we have never modified and which contains none of our code:

```
Library/Application Support/ZeticMLangeCache/artifacts/4165c19af9034cd28cd89fc8ce90a0ad/
    llmTargetModel-468793e74f5f7003
    llmTargetModel-50cfb9e04e270efb
    llmTargetModel-a8824919358a62a8
    llmTargetModel-b606f6e61074df79
```

Four archive copies of the same model, timestamped 7/25–7/28. Container total
**4.77 GB, of which 4.49 GB is `Application Support`**. The app also carries a
`tmp/model_COREML_FP32.mlmodelc` left behind, matching Defect 3.

Applications cannot safely fix this themselves: deleting the wrong directory
removes the live model and forces a full re-download (we tried; it broke the
app). The SDK must either replace on re-download or expose which artifact
directory is current.

## Defect 7 — every model load duplicates the model on disk

Each `ZeticMLangeLLMModel` init writes a fresh extraction and a fresh compiled
set, and neither replaces its predecessor:

- `Documents/NativeLfmVL/<modelKey>/` measured **3.08 GB — two full extractions**
  — on a *fresh install*, i.e. from two model loads.
- `Caches/zetic_coreml_compiled` gains a new ~1.5 GB set per load (Defect 1).

**Why this is severe, not just wasteful.** Growth is per *model load*, and loads
are frequent: the device trace records **8 model loads in one testing session**.
Over that session the container reached **roughly 35 GB** as observed in
Settings, filling a 256 GB iPhone. iOS then purged `Library/Caches` under
pressure and it fell back to 5.29 GB unaided — so a measurement taken minutes
later will disagree with what the user saw. `zetic_coreml_compiled` reading zero
entries is the signature of that purge.

It also blocks the obvious fix for the context bug (ISSUES-ENCOUNTERED issue 4):
clearing context requires reloading the model, and every reload pays this cost
again. The two defects compound, and neither is fixable from application code.

## How this ends: the app bricks itself

Left to run, Defect 1 does not merely waste space — it makes the app
unrecoverable. Observed on the test device:

| Measurement | Value |
|---|---|
| `Caches/zetic_coreml_compiled` | **7.19 GB across 15 entries** |
| Container total | 9.41 GB |
| Device free space | **0 bytes** |
| `Documents/NativeLfmVL` | 19 directory entries, **~0 bytes of weights** |

With the disk full, extraction **silently truncated** — the folder tree was
created but the weight files were not written, and no error was raised. The SDK
then loaded that incomplete model and crashed during inference with **SIGSEGV**.

Reinstalling did not help, because the wasted 7.19 GB lives inside the app
container and there was no room to stage even a 28 MB build:

```
Not enough space for … PromiseStaging/… :
28284324 bytes needed, 0 bytes available (0 bytes were purged)
```

The only recovery was deleting the app, which also discards the 1.76 GB model.

**Two asks beyond the eviction fix:** validate the extracted artifact set (size
or checksum) before handing the model to CoreML, and surface an explicit
insufficient-storage error rather than segfaulting later.

## Workaround currently used by this app

`Core/ModelStorageJanitor.swift` runs before model init and:

- calls `ModelCacheManager.shared.prune()`,
- empties the app's own `tmp/` (~1.5 GB abandoned per launch),
- **deletes every entry in `Caches/zetic_coreml_compiled`** — they are never
  reused while Defect 1 stands, and leaving them is what bricks the device,
- sets `isExcludedFromBackup` on the large directories.

It deliberately does **not** touch `Library/Caches/<bundle-id>` (Apple's ANE
cache and NSURLSession) or `Application Support/ZeticMLangeCache` (the live
`.ztc`). Clearing either broke the app — the first with ANE recompiles and
repeated re-downloads, the second by forcing a full re-download.

This keeps growth bounded but cannot make the app small: the SDK still writes
the model to disk four times per cold run, and the compiled set is rebuilt every
launch. Every app on this SDK needs equivalent code today.

---

## Unrelated, but worth fixing in the same release

**1.9.0 dropped the `Accelerate` linker setting.** In 1.4.5 the package wrapped
the binary in a `ZeticMLangeWrapper` target carrying
`.linkedFramework("Accelerate")`. 1.9.0 is a bare `binaryTarget` with no
`linkerSettings`, so every app upgrading fails to link with missing `vDSP_*`
symbols (`vDSP_vsmul`, `vDSP_sve`, `vDSP_dotpr`, …) until it adds
`-framework Accelerate` itself. This is undocumented in the release notes.
