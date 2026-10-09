# Brief: App Store size, asset delivery and iOS memory limits for Dee (Qwen3.5-4B Q4_K_M)

## 1. App Store build size limits
Source: https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes (verified)

| Deployment target | Max uncompressed app | Max executable |
|---|---|---|
| iOS 9.0+ | **4 GB** | **80 MB** (total of all `__TEXT` sections) |

- **Q4_K_M file size depends on who made the quant** (byte counts checked against the HF API):

  | Repo | File | Size |
  |---|---|---|
  | unsloth | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 B (about 2.74 GB) |
  | bartowski | `Qwen_Qwen3.5-4B-Q4_K_M.gguf` | 3,013,027,808 B (about 3.01 GB) |

  Sources: https://huggingface.co/unsloth/Qwen3.5-4B-GGUF, https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF
- The model is multimodal. Leave out the `mmproj` vision file (about 0.67 GB as F16/BF16) unless we need vision.
- If we bundle, budget 2.75 GB (unsloth) or 3.0 GB (bartowski). That leaves about 1.0–1.25 GB under the 4 GB limit.
- A llama.cpp static library with Metal fits well within 80 MB of `__TEXT`. The ggml Metal shaders compile into a `.metallib` resource, or are embedded as data with `GGML_METAL_EMBED_LIBRARY`. UNVERIFIED: the exact size for our build. Measure it with `size -m`.
- App Thinning does not help here. A GGUF is a single universal resource.
- No App Review guideline forbids bundling a large model file. UNVERIFIED: I found no explicit statement either way.

## 2. Cellular downloads
- The App Store asks before cellular downloads over **200 MB** by default ("Ask If Over 200 MB"). Users can switch to "Always Allow" (iOS 13+). Sources: https://techcrunch.com/2019/06/03/ios-13-will-let-you-bypass-the-app-store-download-cap-when-on-a-cellular-connection, https://www.idownloadblog.com/2019/10/25/about-app-store-cellular-download-limit/
- A 3 GB install will trigger this prompt on cellular.
- UNVERIFIED: whether `prefetch` and `onDemand` asset-pack downloads follow the same rule.

## 3. On-Demand Resources (deprecated)
- Confirmed in the local iOS 27.0 SDK. `NSBundle.h` marks `NSBundleResourceRequest` as `API_DEPRECATED("Use Background Assets instead.", ios(9.0, 27.0), …)`.
- **Do not use ODR.**

## 4. Background Assets and Apple-hosted asset packs (WWDC25 session 325)
Sources: https://developer.apple.com/videos/play/wwdc2025/325/, https://developer.apple.com/help/app-store-connect/reference/app-uploads/apple-hosted-asset-pack-size-limits

- **Minimum OS:** the managed `AssetPackManager` API is introduced in iOS 26 (per the SDK annotations). Our target is iOS 27, so this is fine.
- **Limits (verified on Apple's page):**
  - 200 GB in total per app record. Each pack counts at the largest of its eligible versions.
  - 200 packs per app record.
  - Apple emails a warning at 80% of the total.
  - Archiving a pack frees its space.
  - The per-pack size limit is not documented (the page doesn't mention one), so it remains UNVERIFIED.
- **Download policies:**
  - `essential`: downloads as part of install.
  - `prefetch`: starts during install and may finish after it.
  - `onDemand`: downloads only when the app asks.
- **Packaging:** build packs with `xcrun ba-package` and upload with Transporter or the App Store Connect API. Pack versions are independent of app builds and reach all installed app versions, so GGUF compatibility must be kept.
- **Info.plist keys:** `BAHasManagedAssetPacks` and `BAUsesAppleHosting` are confirmed as symbols in the SDK. For the app group, the SDK symbol is `BAApplicationGroupIdentifier`. `BAAppGroupID` is the key used in WWDC/sample Info.plists (UNVERIFIED which spelling is canonical; check the Xcode target template). You also need an App Group and a downloader extension that conforms to `StoreDownloaderExtension`, which is declared in **StoreKit**, not BackgroundAssets.
- **APIs** (`actor AssetPackManager`, `.shared`), checked against the iOS 27.0 SDK swiftinterface:

  | API | Status in the iOS 27 SDK |
  |---|---|
  | `manager.assetPack(withID:)` | **Deprecated in iOS 27.** Use `try await manager.manifest.assetPack(withID:)` instead. |
  | `ensureLocalAvailability(of:)` | **Deprecated in 26.4.** Use `ensureLocalAvailability(of:requireLatestVersion:)`. |
  | `statusUpdates(forAssetPackWithID:)` | Current. Yields `.began`, `.paused`, `.downloading(pack, Progress)`, `.finished`, `.failed`. |
  | `contents(at: FilePath, searchingInAssetPackWithID:options:)` | Current. Defaults to `.mappedIfSafe`. |
  | `descriptor(for: FilePath, searchingInAssetPackWithID:)` | Current. Returns a `FileDescriptor`. |
  | **`url(for: FilePath) -> URL`** | **New in iOS 27.** |
  | `remove(assetPackWithID:)` | Current. |
  | `checkForUpdates()` | Current. |
  | `localStatus(ofAssetPackWithID:)` | Current. |
  | `assetPackIsAvailableLocally(withID:)` | Current. |

- **Storage:** packs are not auto-purged while the app is installed. UNVERIFIED against primary docs; this comes from the WWDC session.
- **Restrictions:** an app can't mix Apple-hosted and self-hosted packs, or the managed and unmanaged APIs (https://developer.apple.com/forums/thread/827100). A plain `URLSession` download is fine.
- **Can llama.cpp read the model in place?** This is much more likely now. The iOS 27 `url(for:)` returns a file URL that can be passed straight to `llama_model_load_from_file`. Whether mmap works on that path is still to be confirmed in the Phase 0 spike. The fallback is a one-time copy (about 3 GB extra).

## 5. iOS memory limits
- **`com.apple.developer.kernel.increased-memory-limit`** (iOS 15+): applies only on some device models. Read the actual allowance with `os_proc_available_memory()`. Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit (the page is JS-rendered and could not be re-fetched; the content matches known docs).
- **`com.apple.developer.kernel.extended-virtual-addressing`** (iOS 14+): gives a larger address space, which suits mmapped GPU assets. Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing
- **Use both.** Check the signed IPA with `codesign -d --entitlements :-`. DTS has seen release signatures that were missing the entitlement (https://developer.apple.com/forums/thread/770868). `increased-debugging-memory-limit` applies to debug builds only.
- **Metal ceiling:** the 12 GB iPhone Air reportedly gives `recommendedMaxWorkingSetSize` ≈ 8 GB (https://developer.apple.com/forums/thread/805161; this is a forum report, not re-verified).
- **mmap:** UNVERIFIED how footprint accounting works once pages are wrapped as Metal buffers. Measure `phys_footprint` in Instruments.
- **Default jetsam limit:** about 50–65% of RAM. UNVERIFIED; there is no Apple figure.

## 6. Which iPhones can run it
- **The architecture is confirmed hybrid.** Qwen3.5-4B has 32 layers with `full_attention_interval` = 4, so 8 layers use full attention and 24 use Gated DeltaNet linear attention. Each full-attention layer has 4 KV heads and `head_dim` 256 (https://huggingface.co/Qwen/Qwen3.5-4B/raw/main/config.json).
- Local llama.cpp classifies `LLM_ARCH_QWEN35` as hybrid/recurrent and supports rs-rollback (`src/llama-arch.cpp`).
- **KV cache at 4096 tokens, f16:** 8 × 2 × 4 × 256 × 4096 × 2 B ≈ **128 MiB**, plus a small fixed recurrent state.
- **Estimated total:** 2.75–3.0 GB weights + about 0.15 GB KV/state + about 0.3–0.5 GB compute buffers ≈ **3.2–3.7 GB**.

| RAM | Devices (examples) | Verdict |
|---|---|---|
| 6 GB | iPhone 14 Pro, 15/15 Plus | Marginal; needs the entitlement |
| 8 GB | iPhone 15 Pro, 16 family, 16e, 17 | **Recommended minimum** |
| 12 GB | iPhone 17 Pro/Pro Max, Air | Comfortable |

- At runtime, check that `os_proc_available_memory()` is at least about 4.0 GB before loading, and fail gracefully if it isn't.
- `UIRequiredDeviceCapabilities` has no RAM key. UNVERIFIED whether a performance-tier capability key could act as a device floor.

## 7. Recommendation: use an Apple-hosted Background Assets pack, not a bundle
Use a managed, Apple-hosted pack with the `essential` policy, or `prefetch` plus a "Dee is waking up…" animation.

Why:
1. **Updates stay small.** The app binary stays small and the model has its own version.
2. **Headroom.** The model alone takes 69–75% of the 4 GB cap. Asset packs come out of a separate 200 GB quota.
3. **The experience matches bundling.** `essential` packs install with the app.
4. **ODR is deprecated** in the iOS 27 SDK.
5. **Model swaps don't need an app update.** Ship a new model as a new pack ID.

What to do:
- **Phase 0 spike:** call `llama_model_load_from_file` on `AssetPackManager.shared.url(for:)` with mmap, and measure peak `phys_footprint` on an 8 GB device.
- **Development loop:** keep a debug-only local-path GGUF fallback.
- **Entitlements:** both kernel entitlements, plus an App Group.
- **Use the non-deprecated APIs:** `manifest.assetPack(withID:)` and `ensureLocalAvailability(of:requireLatestVersion:)`.
- **Pack hygiene:** keep pack IDs stable, keep GGUF compatibility with older builds, and call `remove(assetPackWithID:)` after migrating.
- **Choose the unsloth Q4_K_M (2.74 GB)** over bartowski's (3.01 GB) unless quality testing favours bartowski's.

## Corrections
1. **Q4_K_M sizes:** pinned to exact bytes. Unsloth's is 2.74 GB, bartowski's is 3.01 GB. Added that the vision `mmproj` file (about 0.67 GB) should not be shipped.
2. **ODR deprecation:** now cited to the iOS 27.0 SDK `NSBundle.h` instead of a blog post.
3. **Deprecated APIs named:**
   - `AssetPackManager.assetPack(withID:)` is deprecated in iOS 27; use `manifest.assetPack(withID:)`.
   - The one-argument `ensureLocalAvailability(of:)` is deprecated in 26.4; use the `requireLatestVersion:` overload.
4. **New `url(for:) -> URL` in iOS 27:** this resolves most of the "can llama.cpp mmap from the pack" uncertainty.
5. **`StoreDownloaderExtension`** is declared in StoreKit. The app-group key's SDK symbol is `BAApplicationGroupIdentifier`, and the `BAAppGroupID` spelling is flagged UNVERIFIED.
6. **Asset-pack limits:** removed the claim that Apple's page sets a minimum OS (it doesn't). Added the 80% warning and archiving.
7. **Hybrid attention:** confirmed from config.json and the local llama.cpp tree. KV cache computed as about 128 MiB, total estimate revised to 3.2–3.7 GB, and the runtime gate lowered to about 4.0 GB.
8. **Device list:** added the iPhone 16e (8 GB).