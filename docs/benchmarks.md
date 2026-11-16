# Benchmarks

Anchor against stock ProfileStore 1.0.3, on two datasets:

- **small**: 20 fields, about 0.5 KB of JSON.
- **large**: a card-game save with 670 cards × 10 fields plus 16 top-level keys, about 112 KB of JSON.

Full tables and method: [bench/RESULTS.md](https://github.com/Acidgorgon/anchor/blob/main/bench/RESULTS.md).
These numbers may be refreshed as the code changes.

## The short version

- **Compat (the default) costs what ProfileStore costs.** At default constants it makes no codec calls
  on load or save, and allocates the same.
- **Compact costs Luau time: about 2.2–2.6 ms per save** of the large dataset (one encode plus a verify).
  In exchange it stores 65% less and hands Roblox's C++ JSON a third of the text.
- **No DataStore call savings at default constants.** With a shorter autosave period, idle players cost
  far fewer calls.

## How it was measured

Plain Luau 0.700 (native and interpreted) with a Roblox mock running in virtual time; medians of 7 runs.
**Work Roblox does in C++ is excluded** (JSON encode/decode of the stored value, base64, compression),
and so is garbage collection. Stock ProfileStore does almost all of its saving work in that C++ JSON
step, which we can't measure outside Roblox. Native timings vary by up to about ±20% between runs, and
anything under ~50 µs is noise.

## CPU

Library Luau time, large dataset, native:

| | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| Load (`StartSessionAsync`) | 0.88–1.05 ms | 0.86–0.89 ms | 1.3–1.7 ms |
| Autosave, default constants | ~0.03 ms (noise) | ~0.03–0.05 ms (noise) | 2.2–2.6 ms |
| 50 players × 30 min, total | 80.5 ms | 83.9 ms | 772 ms |
| 50 players × 30 min, interpreted | 94.0 ms | 102.8 ms | 1 405 ms |

- **Compat** matches stock: same deep copy on load, no codec work on save. A test counts codec calls and
  finds none for load, autosave, `Save`, `SaveAsync`, messages and release.
- **Compact** pays one encode plus one verify (decode and compare) per save, and one decode per load.
  Over the 50-player run that is 9.6× stock's Luau CPU, about 0.77 s in 31 minutes, arriving as ~2.2 ms
  bursts, one per autosave or release. It also allocates 5.4× stock (encode buffers and verify decodes),
  which turns into GC work not counted above. What it buys is in the next section.
- When a save fails, Anchor runs a validation pass (about 0.7 ms for the large dataset) to name the bad
  value in `OnError`. Normal saves never pay it.

With small data all three are close: 37.9 ms (stock), 40.0 ms (Compat) and 45.5 ms (Compact) for the
whole 50-player run.

## Save size

| Data | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| small | 724 B | 724 B | 741 B |
| large | 112.1 KB | 112.1 KB | **39.1 KB** (−65%) |

Compat writes byte-for-byte what stock writes. If Roblox zstd-compresses the buffer, a large Compact save
would be about 26 KB; that part is an estimate. In the 50-player run Compact wrote 14.2 MB against
40.7 MB.

## Memory per loaded profile

| Data | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| small | 7.1 KB | 8.2 KB | 6.4 KB |
| large | 1 038 KB | 1 040 KB | 530 KB |

Compat keeps a full `LastSavedData` copy like stock. Pass `LastSavedData = false` to skip it if you never
read it. Compact keeps the stored buffer instead and decodes it only when `LastSavedData` is read (which
brings it back to about stock's size until the next save).

## DataStore calls

Steady state, calls per hour per player (small data, 10 players, 3 hours):

| Setup | Stock | Anchor, idle player | Anchor, active player |
|---|---:|---:|---:|
| Default constants (`AUTO_SAVE_PERIOD` 300) | 11.9 | 11.9 | 11.9 |
| `AUTO_SAVE_PERIOD` 60 | 60 | **10** | 60 |
| `AUTO_SAVE_PERIOD` 60, `LockRefresh` 400 | 60 | **8.6** | 60 |

**No savings at default constants.** Anchor only skips an unchanged autosave while the last write is
recent enough that no other server could think the lock is dead:
`min(LockRefresh, 0.75 × 630 − AUTO_SAVE_PERIOD)`. With a 300-second period that window (172.5 s) is
shorter than the period, so every autosave writes, same as stock, and Anchor doesn't spend anything
checking.

With a shorter period, idle players are written about every 6 minutes instead of every minute. The check
costs one encode (about 0.8 ms for the large dataset) per autosave in Compat, or nothing with an
[`IsDirty` hook](/guide/ripple#skipping-clean-saves-with-ripple-s-dirty-flag-advanced). Players whose
data changed are written every period, like stock.

Loading and releasing cost 1 `UpdateAsync` each, plus 1 MessagingService subscription per session, the
same for all three. Each two-sided trade adds one `UpdateAsync` on its decision key.
