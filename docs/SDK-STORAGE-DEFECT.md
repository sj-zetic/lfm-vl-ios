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

## Workaround currently used by this app

`Core/ModelStorageJanitor.swift` runs before model init and sweeps only the
app's own `tmp/` (safe, ~1.5 GB per launch), calls
`ModelCacheManager.shared.prune()`, and sets `isExcludedFromBackup`. It
deliberately does **not** touch `Library/Caches/<bundle-id>` or
`Application Support/ZeticMLangeCache` — both broke the app when cleared.

There is no safe application-side fix for the compiled-artifact growth: deleting
those entries forces a recompile, and leaving them doubles storage per launch.
This needs the SDK fixes above.

---

## Unrelated, but worth fixing in the same release

**1.9.0 dropped the `Accelerate` linker setting.** In 1.4.5 the package wrapped
the binary in a `ZeticMLangeWrapper` target carrying
`.linkedFramework("Accelerate")`. 1.9.0 is a bare `binaryTarget` with no
`linkerSettings`, so every app upgrading fails to link with missing `vDSP_*`
symbols (`vDSP_vsmul`, `vDSP_sve`, `vDSP_dotpr`, …) until it adds
`-framework Accelerate` itself. This is undocumented in the release notes.
