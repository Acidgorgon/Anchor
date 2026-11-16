# Anchor vs stock ProfileStore 1.0.3: benchmark results

Run with `bench/run_compare.sh` (source: `bench/compare_bench.luau`). Raw output is in `bench/results/compare/`. Host: Luau 0.700 `luau-bench`, `-O2`, native (`--codegen`) and interpreted. Every timing is the median of 7 runs. Run on 2026-11-16, after the SPEC section 9 perf pass, on a 4-core Linux VM; treat absolute µs as relative.

**Everything Roblox does in C++ is excluded from every CPU and alloc number below: JSON encode/decode of the stored value, base64, and zstd.** The mock does that work in Luau; the bench meters it and subtracts it. Mock plumbing and idle frames are subtracted too, and GC work is excluded (see Methodology).

## Summary

This run is after the SPEC section 9 perf pass. "Before" numbers are from the previous run of this bench (same host, same day), before that pass.

| FM data, native, library Luau CPU | stock | Compat before | Compat now | Compact before | Compact now |
|---|---:|---:|---:|---:|---:|
| load (`StartSessionAsync`) | 0.88–1.05 ms | 2.39 ms | **0.86–0.89 ms** | 1.2–1.8 ms | 1.3–1.7 ms |
| dirty autosave, default constants | ~0.03 ms (noise) | 5.0 ms | **~0.03–0.05 ms (noise)** | 3.8 ms | **2.2–2.4 ms** |
| 50-player server, 30 min | 80.5 ms | 1 302 ms | **83.9 ms** | 1 185 ms | **772 ms** |
| 50-player server, interpreted | 94.0 ms | 2 158 ms | **102.8 ms** | 2 124 ms | **1 405 ms** |

1. **Compat now costs what stock costs.** At default constants a Compat load, autosave, `Save`, `SaveAsync`, message or release makes zero Codec calls (a test counts them). The 50-player FM server spends 83.9 ms of library CPU against stock's 80.5 ms (102.8 vs 94.0 interpreted), within run-to-run noise. Allocations are the same as stock (53.3 vs 52.8 MB). `Codec.validate` runs only after an UpdateAsync call fails, to add the bad path to that call's `OnError` message.
2. **Compact costs one encode plus one verify per save.** That is about 2.2–2.5 ms native (4.1–4.4 ms interpreted) per FM autosave, against 3.8 ms before. Load is one decode, unchanged. Over the 50-player server it is 772 ms of library CPU, 9.6× stock's Luau CPU, down from 15×. In exchange it writes 14.2 MB instead of 40.7 MB, and Roblox's C++ JSON handles 3× less text per save and load, which this bench can't measure.
3. **Compat lost its memory advantage, by design.** Compat now keeps `LastSavedData` as a full deep copy, as stock does: 1 040 KB per FM profile, against 554 KB before and 1 038 KB for stock. `LastSavedData = false` skips that copy (and `LastSavedData` stays nil). Compact still keeps a ~29 KB blob and holds 530 KB per FM profile until `LastSavedData` is read.
4. **Smaller saves (Compact only).** An FM profile is stored as 39.1 KB of JSON instead of 112.1 KB (−65%), about 26 KB if Roblox zstd-compresses the buffer. Compat writes exactly the bytes stock writes.
5. **The clean-save skip still costs one encode, only where it can trigger.** At default constants a skip can never trigger (see section 5), so Anchor no longer encodes for it. With a short period (here 10 s), a Compat autosave pays one compare encode: about 0.8–0.9 ms native for FM, written or skipped. An `IsDirty` hook removes that encode. The call savings are unchanged: at a 60 s period an idle player costs 10 calls/h instead of stock's 60.

## 1. Load (`StartSessionAsync`), library Luau CPU and allocations

C++ JSON decode of the stored value is not included; the "mock JSON" column shows how much Luau-JSON time the mock spent and was removed. The tables that decode creates land in the Luau heap on Roblox for all three libraries, and the alloc column excludes them.

| dataset | library | native µs (median / min) | interp µs | alloc KB | before: native / interp µs | mock Luau JSON removed, native µs |
|---|---|---:|---:|---:|---:|---:|
| small | stock | 22.5 / 22.0 | 26.5 | 15.0 | 20.4 / 28.0 | 82 |
| small | Anchor-Compat | 30.0 / 24.0 | 28.2 | 16.4 | 43.2 / 65.0 | 83 |
| small | Anchor-Compact | 31.4 / 30.3 | 43.2 | 18.0 | 32.2 / 49.7 | 69 |
| fm | stock | 1 048 / 882 | 909 | 948 | 841 / 912 | 15 595 |
| fm | Anchor-Compat | **891 / 856** | **1 131** | 950 | 2 390 / 4 427 | 14 308 |
| fm | Anchor-Compact | 1 713 / 1 283 | 2 139 | 857 | 1 817 / 1 911 | 3 731 |

What each library does on load:
- **Stock** deep-copies Data into `LastSavedData`. That copy is the 948 KB of allocations.
- **Anchor-Compat** does the same deep copy and no Codec work, so it matches stock (the native stock median is high in this run; the minimums are 882 and 856 µs). With `LastSavedData = false` it skips the copy.
- **Anchor-Compact** decodes the blob into Data once. The stored buffer is kept as the lazy `LastSavedData` and as the clean-skip baseline, so there is no encode or verify on load. It is 1.5–2.3× stock in Luau, but the stored JSON Roblox's C++ must decode is 3× smaller (39 KB instead of 112 KB).

The native Compact median is noisy: runs fall either near 1.3 ms or near 1.7–1.8 ms.

## 2. Save (one autosave), library Luau CPU and allocations

C++ JSON encode of the written value is not included. Stock rows are at the method's noise floor (about ±50 µs for FM, from the frame window).

The bench uses `AUTO_SAVE_PERIOD = 10` so that it can collect samples quickly. At that period a clean skip *can* trigger, so the plain Anchor rows pay the skip check. The **no-skip** rows add `LockRefresh = 5`, so a skip can never trigger. That is the path every autosave takes at default constants (period 300), and the one the 50-player server runs.

| dataset | library | autosave | native µs | interp µs | alloc KB | DataStore call | before: native µs |
|---|---|---|---:|---:|---:|---|---:|
| small | stock | dirty | 4.7 | 9.1 | 0.2 | UpdateAsync | 6.9 |
| small | stock | clean | 2.7 | 7.0 | 0.2 | UpdateAsync | 6.5 |
| small | Anchor-Compat no-skip | dirty | 9.3 | 11.1 | 0.9 | UpdateAsync | - |
| small | Anchor-Compat no-skip | clean | 8.7 | 10.6 | 0.9 | UpdateAsync | - |
| small | Anchor-Compact no-skip | dirty | 29.4 | 50.1 | 8.1 | UpdateAsync | - |
| small | Anchor-Compact no-skip | clean | 34.5 | 47.1 | 8.1 | UpdateAsync | - |
| small | Anchor-Compat | dirty | 19.6 | 32.9 | 3.7 | UpdateAsync | 50.9 |
| small | Anchor-Compat | clean | 14.5 | 24.2 | 3.9 | skipped | 14.5 |
| small | Anchor-Compact | dirty | 41.7 | 53.7 | 7.3 | UpdateAsync | 57.3 |
| small | Anchor-Compact | clean | 14.5 | 24.5 | 3.9 | skipped | 12.1 |
| fm | stock | dirty | ~24 (noise) | ~9 (noise) | 0.2 | UpdateAsync | ~47 |
| fm | stock | clean | ~27 (noise) | ~15 (noise) | 0.2 | UpdateAsync | ~33 |
| fm | Anchor-Compat no-skip | dirty | **~46 (noise)** | **~41 (noise)** | 1.0 | UpdateAsync | - |
| fm | Anchor-Compat no-skip | clean | ~31 (noise) | ~23 (noise) | 1.0 | UpdateAsync | - |
| fm | Anchor-Compact no-skip | dirty | **2 222** | **4 144** | 875 | UpdateAsync | - |
| fm | Anchor-Compact no-skip | clean | 2 179 | 4 195 | 875 | UpdateAsync | - |
| fm | Anchor-Compat | dirty | 1 309 | 1 837 | 37 | UpdateAsync | 5 014 |
| fm | Anchor-Compat | clean | 813 | 1 911 | 37 | skipped | 852 |
| fm | Anchor-Compact | dirty | 3 157 | 4 372 | 879 | UpdateAsync | 3 787 |
| fm | Anchor-Compact | clean | 876 | 1 794 | 37 | skipped | 830 |

The "before" column had no no-skip rows. Before the pass every autosave ran the full pipeline whatever the constants, so the before value of a no-skip row is the plain row's value (5 014 µs for FM Compat dirty).

Native FM timings vary between runs. A second native run of this section gave 906 µs (Compat dirty), 858 (Compat clean), 2 470 (Compact dirty), 832 (Compact clean), 2 412 and 2 379 (Compact no-skip). The 1 309 and 3 157 µs above are high outliers of that range: the alloc column shows the same work in both runs.

What an autosave costs now (FM, native, measured with Codec alone):

| path | Codec work | cost |
|---|---|---:|
| Compat, default constants | none | ~0 |
| Compat, skip possible, no `IsDirty` hook | one Data encode (the compare), written or skipped | ~0.8 ms |
| Compat, skip possible, `IsDirty` hook | none (hook decides) | ~0 |
| Compact, any constants | encode + verify (decode + deep-compare); the blob is reused as the skip baseline and as `LastSavedData` | ~2.2 ms |
| Compact, clean skip | one encode (the compare) | ~0.8 ms |
| any format, after a failed UpdateAsync | `Codec.validate`, to name the bad path in `OnError` | ~0.7 ms |

In Compat skip-capable mode, an autosave that already paid the compare encode and found a change writes without encoding a new baseline. The next autosave then writes without comparing and takes its baseline from that write. So it is never more than one encode per autosave, and a player who goes idle costs at most one extra write before the skips start.

Stock pays its serialization cost in C++ JSON encode of 112 KB per save. That is not modelled here.

## 3. Resident heap per loaded profile

Measured with 50 profiles loaded: retained heap after a full GC, divided by 50, with the growth of the mock's own stored strings removed. Native and interpreted give identical numbers.

| dataset | library | after load KB | after 1 save each KB | after reading `LastSavedData` KB | before: after load KB |
|---|---|---:|---:|---:|---:|
| small | stock | 7.1 | 7.2 | 7.2 | 7.1 |
| small | Anchor-Compat | 8.2 | 8.3 | 8.3 | 6.6 |
| small | Anchor-Compact | 6.4 | 6.6 | 8.6 | 6.5 |
| fm | stock | 1 038 | 1 039 | 1 039 | 1 038 |
| fm | Anchor-Compat | **1 040** | 1 040 | 1 040 | 554 |
| fm | Anchor-Compact | **530** | 531 | 1 026 | 530 |

- **Compat** now keeps stock's semantics: `LastSavedData` is a full table copied at load and replaced after each save. It holds what stock holds, plus about 1 KB of session state. Use `LastSavedData = false` to skip the copy if you never read it.
- **Compact** keeps the stored blob and decodes it on first read of `LastSavedData`. Code that reads `LastSavedData`, or listens to `OnAfterSave`, which receives it, gets the saving back only until the next save drops the decoded copy.

## 4. Stored bytes per profile

Lengths are the JSON text the mock stores under Roblox rules. In Compact the blob is stored as `{"m":null,"t":"buffer","base64":"..."}` without compression.

| dataset | library | stored JSON bytes | of which Data | blob raw | blob base64 | blob zstd-3 | zstd + base64 | est. stored with zbase64 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| small | stock | 724 | 533 | - | - | - | - | 724 |
| small | Anchor-Compat | 724 | 533 | - | - | - | - | 724 |
| small | Anchor-Compact | 741 | 518 | 350 | 468 | 346 | 464 | ~737 |
| fm | stock | 112 127 | 111 936 | - | - | - | - | 112 127 |
| fm | Anchor-Compat | 112 127 | 111 936 | - | - | - | - | 112 127 |
| fm | Anchor-Compact | **39 141** | 38 918 | 29 151 | 38 868 | 19 228 | 25 640 | **~25 900** |

- **zbase64 is Studio-only behaviour.** Roblox may zstd-compress buffers in DataStore JSON, but whether it does, at what level, and how the 4 MB limit counts it are unknown. The "est." column assumes zstd level 3 via python `zstandard` and is an estimate only.
- For reference, zstd-3 of the Compat FM Data JSON is 23.2 KB. Roblox does not compress plain JSON values, as far as we know.
- On small data Compact is 17 bytes larger, because of the buffer wrapper and the Anchor metadata.

## 5. DataStore calls per hour per player

These are steady-state numbers: 10 players, 3 virtual hours, `small` data. Each session also costs 1 UpdateAsync to load, 1 to release and 1 MessagingService `SubscribeAsync`, the same for all three libraries.

| config | library | idle calls/h | idle KB written/h | active calls/h | active KB written/h |
|---|---|---:|---:|---:|---:|
| defaults (period 300) | stock | 11.9 | 9.2 | 11.9 | 10.9 |
| defaults (period 300) | Anchor-Compat | 11.9 | 9.2 | 11.9 | 10.9 |
| defaults (period 300) | Anchor-Compact | 11.9 | 9.4 | 11.9 | 9.6 |
| `AUTO_SAVE_PERIOD` 60 | stock | 60.0 | 46.3 | 60.0 | 54.8 |
| `AUTO_SAVE_PERIOD` 60 | Anchor-Compat | **10.0** | 7.7 | 60.0 | 54.8 |
| `AUTO_SAVE_PERIOD` 60 | Anchor-Compact | **10.0** | 7.9 | 60.0 | 48.6 |
| period 60, `LockRefresh` 400 | Anchor-Compat | 8.6 | 6.7 | 60.0 | 54.8 |
| period 60, `LockRefresh` 400 | Anchor-Compact | 8.6 | 6.8 | 60.0 | 48.6 |

How the lock-refresh clamp limits the savings:
- **The formula.** A clean autosave may be skipped only while the last write is younger than `min(LockRefresh, 0.75 × ASSUME_DEAD − AUTO_SAVE_PERIOD)`. This keeps the next possible write before another server treats the lock as dead at 630 s.
- **At the default period of 300 s,** the limit is `min(300, 472.5 − 300)` = 172.5 s. Autosaves come 300 s apart, so the last write is always older than the limit. **Anchor never skips at defaults, idle or active.**
- **At a period of 60 s,** the limit is `min(300, 412.5)` = 300 s. An idle profile is written about every 360 s (5 skips, then a write), so 10/h.
- **Raising `LockRefresh`.** At a 60 s period the highest useful value is 412.5. `LockRefresh = 400` gives about one write every 420 s, so 8.6/h.
- **Active players** (any change in each period) are written every period by all three libraries.

## 6. 50-player server simulation

50 players join over 60 s, each plays 30 virtual minutes with an edit every 10–60 s, then leaves. Latency is 0.1–0.3 s with default constants. Values are medians of 7 seeds. Library CPU excludes C++ JSON, mock plumbing and the cost of the same run with no library.

| dataset | library | lib CPU native ms | lib CPU interp ms | lib alloc MB | DataStore calls | Messaging calls | MB written | released | before: native / interp ms | before: alloc MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| small | stock | 37.9 | 48.8 | 7.2 | 378 | 50 | 0.30 | 50/50 | 42.1 / 49.2 | 7.2 |
| small | Anchor-Compat | 40.0 | 51.5 | 7.7 | 378 | 50 | 0.30 | 50/50 | 55.5 / 74.7 | 11.8 |
| small | Anchor-Compact | 45.5 | 62.9 | 9.6 | 378 | 50 | 0.29 | 50/50 | 55.5 / 72.7 | 11.8 |
| fm | stock | 80.5 | 94.0 | 52.8 | 378 | 50 | 40.66 | 50/50 | 82.8 / 89.4 | 52.8 |
| fm | Anchor-Compat | **83.9** | **102.8** | 53.3 | 378 | 50 | 40.66 | 50/50 | 1 302 / 2 158 | 333 |
| fm | Anchor-Compact | **772** | **1 405** | 287 | 378 | 50 | **14.19** | 50/50 | 1 185 / 2 124 | 332 |

- All DataStore calls were UpdateAsync: per player, 1 load, 1 release and about 5.6 autosaves. This runs at default constants, where a clean skip can't trigger, so Anchor does no skip-check encode.
- **Compat is within noise of stock:** 1.04× native, 1.09× interpreted, the same allocations. Before the pass it was about 16× (1.3 s).
- **Compact uses 9.6× stock's library Luau CPU on FM data** (15× before), about 0.77 s over 31 minutes, in ~2.2 ms bursts, one per autosave and release. Its allocations are 5.4× stock's (encode buffers and verify decodes), which become GC work excluded from the CPU columns.
- Stock's real per-save cost is C++ JSON encode of 112 KB, plus decoding the UpdateAsync result. Neither is in these numbers. Compact cuts that C++ work by about 3× and the bytes written by 65%, which is what its Luau cost buys.

## Methodology

- **Host and libraries.**
  - Host: `tests/host/build/luau-bench` (Luau 0.700), `-O2`, native (`--codegen`) and interpreted.
  - Libraries are loaded through the Roblox mock (`tests/mock`): each server has its own library copy and virtual time runs in 1/60 s frames.
  - The three libraries: `reference/ProfileStore-1.0.3.luau`, and `src` with `{Format = "Compat"}` or `{Format = "Compact"}`. All other Anchor options are defaults (`VerifyWrites = true`, `LockRefresh = 300`, `LastSavedData = true`), except the save section's no-skip rows (`LockRefresh = 5`). All three are driven through the same stock API.
- **Datasets.** A deterministic xorshift generator builds them.
  - `small`: 20 fields, about 530 B of JSON.
  - `fm`: `Owned` is a map of 670 `i<N>` cards. Each card has 10 fields: ints, two floats, rarity/position strings, two bools and a 6-int array. There are also 16 top-level keys: `Cash`, `Gems`, `Level`, `Xp`, `Stats`, `Settings`, `Squad`, `Subs`, `Formation`, `Achievements`, `Packs`, `DailyStreak`, `LastLogin`, `Version`, `NextId`. About 112 KB of JSON. Each player in section 6 gets its own seed.
- **Library CPU and allocations.** Real host time (`os.clock`) and `__alloc_bytes`, minus three things:
  1. The mock's Luau JSON encode/decode: `JSON.encode`/`decode` are wrapped and metered. On Roblox this runs in C++.
  2. Mock per-call plumbing (scheduler, coroutines, KeyInfo). This is calibrated with a raw `UpdateAsync(k, function(v) return v end)` on a server without a library, holding the same data.
  3. Idle frames, using the median Heartbeat-only frame cost.

  The incremental GC is stopped and full collections run between timed regions. CPU therefore **excludes GC**, and the alloc column is the proxy for GC cost.
- **Load.** `StartSessionAsync` on a key the same library saved, with latency 0. Each run is 5 loads (fm) or 40 loads (small). The release happens between loads, outside the timer.
- **Save.** `AUTO_SAVE_PERIOD = 10`. Frames are stepped one at a time. A sample is the frame window from the skip check until the write lands, minus idle frames and one calibrated call. "dirty" means one gameplay edit before each autosave. 7 samples after a warm-up.
- **Memory.** A seeder server saves 50 profiles and is then crashed. On a fresh server: full GC and `__live_bytes`, load 50 profiles, full GC and `__live_bytes` again. The mock's change in stored JSON is subtracted (`maxVersions = 1`), and the result is divided by 50.
- **Calls per hour.** UpdateAsync, GetAsync and other DataStore methods, counted per server. MessagingService calls are counted separately.

## Caveats

- **C++ work is not in any CPU or alloc number.** That is JSON encode/decode, base64 and zstd. Stock's real save and load cost is mostly there, so these tables overstate Anchor's relative slowdown. By how much is unknown: we have no Roblox C++ JSON timings.
- **Compression is estimated.** zbase64 behaviour and the size it is charged at are Studio-only facts. The zstd column uses python `zstandard` level 3.
- **Mock plumbing is subtracted using a calibration.** It is not exact, so values under ~50 µs, notably every stock save row, are within noise. Native medians varied up to ±20% between full runs.
- **GC is excluded from CPU.** Compact allocates 5.4× stock in the server run, so with GC its real cost is higher than shown. Compat allocates the same as stock.
- **What the decoded JSON costs.** On Roblox the tables that JSON decode creates are allocated in the Luau heap, but they are excluded from the alloc columns. They are the same size for stock and Compat.
- **Memory side effects.** Resident memory includes small per-session mock objects (the MessagingService subscription and its signals), equally for all three libraries. Reading `LastSavedData` removes Compact's memory advantage until the next save. Compat has none: it keeps stock's full copy.
- **What section 5 does not show.** It uses small data: call counts don't depend on size, and section 6 shows bytes for FM. The idle 10/h figure depends on a period of 60 s or less, and is 0% better than stock at the default constants.
