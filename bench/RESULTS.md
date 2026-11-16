# Anchor vs stock ProfileStore 1.0.3: benchmark results

Run with `bench/run_compare.sh` (source: `bench/compare_bench.luau`). Raw output is in `bench/results/compare/`. Host: Luau 0.700 `luau-bench`, `-O2`, native (`--codegen`) and interpreted. Every timing is the median of 7 runs. Run on 2026-11-16 on a 4-core Linux VM; treat absolute µs as relative.

**Everything Roblox does in C++ is excluded from every CPU and alloc number below: JSON encode/decode of the stored value, base64, and zstd.** The mock does that work in Luau; the bench meters it and subtracts it. Mock plumbing and idle frames are subtracted too, and GC work is excluded (see Methodology).

## Summary

1. **Smaller saves (Compact only).** An FM profile is stored as 39.1 KB of JSON instead of 112.1 KB (−65%). If Roblox zstd-compresses the buffer (zbase64), the estimate is about 26 KB (−77%). In the 50-player server, Compact wrote 14.2 MB instead of 40.7 MB. Compat writes exactly the bytes stock writes.
2. **About half the resident memory with large data.** An FM profile holds 554 KB (Compat) or 530 KB (Compact) of heap, against 1038 KB for stock, because `LastSavedData` is kept as a ~29 KB blob instead of a second full table. Reading `profile.LastSavedData` once brings Anchor back to stock's level. Small data: about 7 KB per profile for all three.
3. **Anchor is much slower than stock in Luau, and this is the main cost.** Stock's autosave does almost nothing in Luau, because Roblox serializes in C++. Anchor encodes, validates and verify-decodes the data on every save:
   - FM dirty autosave: about 3.8–5.0 ms native and 9–10 ms interpreted, on one frame, versus stock's ~0.05 ms.
   - FM load: 2.4 ms (Compat) or 1.2–1.8 ms (Compact), versus 0.84 ms for stock.
   - 50-player FM server over 30 minutes: 1.2–1.3 s of library CPU versus 0.08 s for stock (about 15×).

   On Roblox, Compact gives back part of this because C++ then handles 3× less JSON per save and load. We can't measure that here.
4. **No call savings at default constants.** The lock-refresh clamp (`min(LockRefresh, 0.75·630 − AUTO_SAVE_PERIOD)` = 172.5 s at the default 300 s period) forces every autosave to write. Idle and active players both cost 11.9 UpdateAsync/h, the same as stock.
5. **Large call savings at a short period, idle players only.** With `AUTO_SAVE_PERIOD = 60`, an idle player costs 10 calls/h instead of stock's 60 (8.3–8.6/h with `LockRefresh = 400`). An active player still costs 60/h. A clean autosave that Anchor skips still costs about 0.85 ms native of Luau CPU for FM data, because it encodes the data to compare it.

## 1. Load (`StartSessionAsync`), library Luau CPU and allocations

C++ JSON decode of the stored value is not included; the "mock JSON" column shows how much Luau-JSON time the mock spent and was removed. The tables that decode creates land in the Luau heap on Roblox for all three libraries, and the alloc column excludes them.

| dataset | library | native µs (median / min) | interp µs | alloc KB | mock Luau JSON removed, native µs |
|---|---|---:|---:|---:|---:|
| small | stock | 20.4 / 19.3 | 28.0 | 15.0 | 80 |
| small | Anchor-Compat | 43.2 / 41.3 | 65.0 | 17.9 | 82 |
| small | Anchor-Compact | 32.2 / 29.3 | 49.7 | 17.2 | 69 |
| fm | stock | 841 / 806 | 912 | 948 | 14 026 |
| fm | Anchor-Compat | **2 390** / 2 347 | **4 427** | 885 | 13 975 |
| fm | Anchor-Compact | 1 817 / 1 203 | 1 911 | 856 | 4 869 |

What each library does on load:
- **Stock** deep-copies Data into `LastSavedData`. That copy is the 948 KB of allocations.
- **Anchor-Compat** encodes Data to a blob and verifies it (encode, decode, deep-compare) to build the lazy `LastSavedData`. That is 2.8× stock's CPU (4.9× interpreted).
- **Anchor-Compact** decodes the blob into Data and does no verify on load. It is 1.4–2.2× stock in Luau, but the stored JSON Roblox's C++ must decode is 3× smaller (39 KB instead of 112 KB).

The native Compact median is noisy: runs fell either near 1.2 ms or near 1.8 ms.

## 2. Save (one autosave), library Luau CPU and allocations

C++ JSON encode of the written value is not included. Stock rows are at the method's noise floor (about ±50 µs for FM, from the frame window).

| dataset | library | autosave | native µs | interp µs | alloc KB | DataStore call |
|---|---|---|---:|---:|---:|---|
| small | stock | dirty | 6.9 | 7.3 | 0.2 | UpdateAsync |
| small | stock | clean | 6.5 | 6.9 | 0.2 | UpdateAsync |
| small | Anchor-Compat | dirty | 50.9 | 80.6 | 14.8 | UpdateAsync |
| small | Anchor-Compat | clean | 14.5 | 22.7 | 7.0 | skipped |
| small | Anchor-Compact | dirty | 57.3 | 78.3 | 14.9 | UpdateAsync |
| small | Anchor-Compact | clean | 12.1 | 23.8 | 7.0 | skipped |
| fm | stock | dirty | ~47 (noise) | ~0 (noise) | 0.2 | UpdateAsync |
| fm | stock | clean | ~33 (noise) | ~21 (noise) | 0.2 | UpdateAsync |
| fm | Anchor-Compat | dirty | **5 014** | **9 064** | 911 | UpdateAsync |
| fm | Anchor-Compat | clean | 852 | 1 812 | 36 | skipped |
| fm | Anchor-Compact | dirty | **3 787** | **9 794** | 911 | UpdateAsync |
| fm | Anchor-Compact | clean | 830 | 1 751 | 36 | skipped |

**Anchor is slower than stock here, by about 100× in Luau for FM data.** A dirty autosave in Anchor runs, in order:

| step | cost (native, FM, measured with Codec alone) |
|---|---|
| `CanSkipAutoSave`: encode and compare | ~0.8 ms |
| `PreSaveCheck`: `Codec.validate` | ~0.7 ms |
| `EncodeVerified`: encode | ~0.8 ms |
| `EncodeVerified`: decode | ~1.0 ms |
| `EncodeVerified`: deep-compare | ~0.4–0.5 ms |
| encode the aux blob, twice | small |

That is about 4 ms on the frame that runs the save. Native timings varied about ±20% between full runs (an earlier run measured 4.1 ms for Compat dirty).

Possible cuts, not made here because `src/` is out of scope for this task:
- Reuse the skip-check blob when Data has not changed since that check.
- Drop the separate validate pass, since encode already rejects bad data.
- Provide an `IsDirty` hook, for example from Ripple, which removes the skip-check encode.

Stock pays its serialization cost in C++ JSON encode of 112 KB per save. That is not modelled here.

## 3. Resident heap per loaded profile

Measured with 50 profiles loaded: retained heap after a full GC, divided by 50, with the growth of the mock's own stored strings removed. Native and interpreted give identical numbers.

| dataset | library | after load KB | after 1 save each KB | after reading `LastSavedData` KB |
|---|---|---:|---:|---:|
| small | stock | 7.1 | 7.2 | 7.2 |
| small | Anchor-Compat | 6.6 | 6.7 | 8.7 |
| small | Anchor-Compact | 6.5 | 6.6 | 8.7 |
| fm | stock | 1 038 | 1 039 | 1 039 |
| fm | Anchor-Compat | **554** | 554 | 1 049 |
| fm | Anchor-Compact | **530** | 531 | 1 026 |

Stock keeps `Data` plus a full `LastSavedData` table. Anchor keeps `Data` plus a blob, and decodes the blob only on first read. Code that reads `LastSavedData`, or listens to `OnAfterSave`, which receives it, gets the saving back only until the next save drops the decoded copy.

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
| period 60, `LockRefresh` 400 | Anchor-Compat | 8.3 | 6.4 | 60.0 | 54.8 |
| period 60, `LockRefresh` 400 | Anchor-Compact | 8.6 | 6.8 | 60.0 | 48.6 |

How the lock-refresh clamp limits the savings:
- **The formula.** A clean autosave may be skipped only while the last write is younger than `min(LockRefresh, 0.75 × ASSUME_DEAD − AUTO_SAVE_PERIOD)`. This keeps the next possible write before another server treats the lock as dead at 630 s.
- **At the default period of 300 s,** the limit is `min(300, 472.5 − 300)` = 172.5 s. Autosaves come 300 s apart, so the last write is always older than the limit. **Anchor never skips at defaults, idle or active.**
- **At a period of 60 s,** the limit is `min(300, 412.5)` = 300 s. An idle profile is written about every 360 s (5 skips, then a write), so 10/h.
- **Raising `LockRefresh`.** At a 60 s period the highest useful value is 412.5. `LockRefresh = 400` gives about one write every 420 s, so 8.3–8.6/h.
- **Active players** (any change in each period) are written every period by all three libraries.

## 6. 50-player server simulation

50 players join over 60 s, each plays 30 virtual minutes with an edit every 10–60 s, then leaves. Latency is 0.1–0.3 s with default constants. Values are medians of 7 seeds. Library CPU excludes C++ JSON, mock plumbing and the cost of the same run with no library.

| dataset | library | lib CPU native ms | lib CPU interp ms | lib alloc MB | DataStore calls | Messaging calls | MB written | released |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| small | stock | 42.1 | 49.2 | 7.2 | 378 | 50 | 0.30 | 50/50 |
| small | Anchor-Compat | 55.5 | 74.7 | 11.8 | 378 | 50 | 0.30 | 50/50 |
| small | Anchor-Compact | 55.5 | 72.7 | 11.8 | 378 | 50 | 0.29 | 50/50 |
| fm | stock | 82.8 | 89.4 | 52.8 | 378 | 50 | 40.66 | 50/50 |
| fm | Anchor-Compat | **1 302** | **2 158** | 333 | 378 | 50 | 40.66 | 50/50 |
| fm | Anchor-Compact | **1 185** | **2 124** | 332 | 378 | 50 | **14.19** | 50/50 |

- All DataStore calls were UpdateAsync: per player, 1 load, 1 release and about 5.6 autosaves. Every player edits more often than every 300 s, so no autosave is ever skipped.
- **Anchor uses about 15× stock's library Luau CPU on FM data.** That is roughly 1.2 s over 31 minutes (about 0.07% of one core), concentrated in 4–5 ms bursts, one per autosave.
- Stock's real per-save cost is C++ JSON encode of 112 KB, plus decoding the UpdateAsync result. Neither is in these numbers. Compact cuts that C++ work by about 3× and the bytes written by 65%.
- **Allocations are 6× stock's.** These are encode buffers and verify decodes, and they become GC work, which is excluded from the CPU columns.

## Methodology

- **Host and libraries.**
  - Host: `tests/host/build/luau-bench` (Luau 0.700), `-O2`, native (`--codegen`) and interpreted.
  - Libraries are loaded through the Roblox mock (`tests/mock`): each server has its own library copy and virtual time runs in 1/60 s frames.
  - The three libraries: `reference/ProfileStore-1.0.3.luau`, and `src` with `{Format = "Compat"}` or `{Format = "Compact"}`. All other Anchor options are defaults (`VerifyWrites = true`, `LockRefresh = 300`). All three are driven through the same stock API.
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
- **GC is excluded from CPU.** Anchor allocates 6× stock in the server run, so with GC its real cost is higher than shown.
- **What the decoded JSON costs.** On Roblox the tables that JSON decode creates are allocated in the Luau heap, but they are excluded from the alloc columns. They are the same size for stock and Compat.
- **Memory side effects.** Resident memory includes small per-session mock objects (the MessagingService subscription and its signals), equally for all three libraries. Reading `LastSavedData` removes Anchor's memory advantage until the next save.
- **What section 5 does not show.** It uses small data: call counts don't depend on size, and section 6 shows bytes for FM. The idle 10/h figure depends on a period of 60 s or less, and is 0% better than stock at the default constants.
