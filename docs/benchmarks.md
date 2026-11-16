# Benchmarks

Anchor against stock ProfileStore 1.0.3, on two datasets:

- **small**: 20 fields, about 0.5 KB of JSON.
- **large**: a card-game save with 670 cards × 10 fields plus 16 top-level keys, about 112 KB of JSON.

::: warning Numbers from before the performance pass
These results were measured on 2026-11-16, **before** the current performance pass that removes Anchor's
extra Luau work from the default Compat format. CPU numbers for Anchor will change; sizes and call counts
should not. This page will be refreshed. Raw results:
[bench/RESULTS.md](https://github.com/Acidgorgon/anchor/blob/main/bench/RESULTS.md).
:::

## How it was measured

Plain Luau 0.700 (native and interpreted) with a Roblox mock running in virtual time. Every timing is a
median of 7 runs. **Work Roblox does in C++ is excluded** (JSON encode/decode of the stored value, base64,
compression), and so is garbage collection. Stock ProfileStore does almost all of its saving work in
that C++ JSON step, so these tables make Anchor look relatively slower than it would on Roblox, by an
amount we can't measure here.

## Save size

| Data | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| small | 724 B | 724 B | 741 B |
| large | 112.1 KB | 112.1 KB | **39.1 KB** (−65%) |

Compat writes byte-for-byte what stock writes. If Roblox zstd-compresses the buffer, a large Compact save
would be about 26 KB (−77%); that part is an estimate. In a 50-player, 30-minute simulation, Compact wrote
14.2 MB against 40.7 MB.

## CPU: where Anchor costs more

Library Luau time, large dataset, native:

| | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| Load (`StartSessionAsync`) | 0.84 ms | 2.39 ms | 1.2–1.8 ms |
| Autosave with changes | ~0.05 ms | 5.0 ms | 3.8 ms |
| Autosave, nothing changed | ~0.03 ms | 0.85 ms (write skipped) | 0.83 ms (write skipped) |
| 50 players × 30 min, total | 83 ms | 1 302 ms | 1 185 ms |

The single-save rows ran with a 10-second autosave period, so an unchanged profile could be skipped
(see [DataStore calls](#datastore-calls) for why that doesn't happen at the default period).

At the time of this run Anchor did about **15× stock's Luau CPU** on large saves: it encoded, validated and
verified the data on every save, where stock hands the table to Roblox's C++ JSON encoder. Spread over 31
minutes that is about 0.07% of one core, but it arrives as 4–5 ms bursts, one per autosave. Interpreted
(non-native) timings were up to about 2.5× higher. With small data the difference is small (56 ms against 42 ms
for the whole 50-player run).

On Roblox, Compact gives some of this back: the C++ JSON step handles a third of the bytes on every load
and save.

## Memory per loaded profile

| Data | Stock | Anchor Compat | Anchor Compact |
|---|---:|---:|---:|
| small | 7.1 KB | 6.6 KB | 6.5 KB |
| large | 1 038 KB | 554 KB | 530 KB |

At the time of the run, Anchor kept `LastSavedData` as a compact buffer and decoded it only when read;
reading it brought memory back to stock's level. The performance pass changes Compat back to stock's
behaviour here and adds the `LastSavedData = false` option, which skips that copy entirely.

## DataStore calls

Steady state, calls per hour per player (small data, 10 players, 3 hours):

| Setup | Stock | Anchor (idle player) | Anchor (active player) |
|---|---:|---:|---:|
| Default constants (`AUTO_SAVE_PERIOD` 300) | 11.9 | 11.9 | 11.9 |
| `AUTO_SAVE_PERIOD` 60 | 60 | **10** | 60 |
| `AUTO_SAVE_PERIOD` 60, `LockRefresh` 400 | 60 | **8.3–8.6** | 60 |

**No savings at default constants.** Anchor only skips an unchanged autosave while the last write is
recent enough that no other server could think the lock is dead:
`min(LockRefresh, 0.75 × 630 − AUTO_SAVE_PERIOD)`. With a 300-second period that window (172.5 s) is
shorter than the period, so every autosave writes, same as stock.

With a shorter autosave period, idle players are written about every 6 minutes instead of every minute.
Players whose data changed are written every period, like stock.

Loading and releasing cost 1 `UpdateAsync` each, plus 1 MessagingService subscription per session, the
same for all three.
