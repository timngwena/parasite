# Build notes

Working notes from building Parasite against one real machine. Most of what is
here was learned by measuring something, disbelieving the number, and finding out
why it was wrong. Kept because every one of these would have shipped silently.

## Measurement gotchas on Apple Silicon

### CPU time is in mach ticks, not nanoseconds

`proc_taskinfo.pti_total_user` and `pti_total_system` are documented loosely and
read naturally as nanoseconds. They are mach time units. On Intel the timebase is
1:1 so the distinction never shows; on Apple Silicon it is **125/3**, so treating
ticks as nanoseconds under-reports every process by a factor of ~41.7.

A fully pinned core read as **2.4%**. Caught because `yes` reported 2.5% and
2.5 × 41.67 ≈ 104%.

```swift
var info = mach_timebase_info_data_t()
mach_timebase_info(&info)                       // numer 125, denom 3
let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
```

### `[UInt64].map(Double.init)` silently means `Double(bitPattern:)`

Swift resolves the unapplied initialiser reference to the bit-pattern overload,
reinterpreting the integer's bytes as an IEEE double. 25 GB became `1.2e-313`.
It compiles, runs, and produces denormal garbage.

Use an explicit closure: `.map { Double($0) }`.

### Polling cannot see processes that live between two polls

`proc_listallpids` returns what exists at that instant. A build that spawns
hundreds of short-lived compiler processes was invisible to a 60-second sampler —
per-app attribution showed almost no CPU while the machine-wide figure (from host
tick counters, which miss nothing) showed full load.

Fixed by moving per-process sampling onto the 5-second loop. Anything living less
than one tick still escapes attribution; it is still counted in the machine-wide
total, and the README says so.

### `powermetrics` cluster `idle_ratio` is always 0.000

Not sometimes — always, on an idle machine as much as a busy one. The per-core
`idle_ratio` values inside `cpus[]` are the real signal, and they have to be
scaled by `online_ratio` because a cluster can be powered down entirely while its
cores report plausible-looking ratios for the slice of time they were up.

Using the cluster figure made every cluster read as 100% active, which in turn
made a throttling rule fire **at idle** (P-cores sit at 2698 of 4056 MHz when
there is nothing to do — busy-looking and downclocked, by the rule's logic).

### `powermetrics` rejects its own `smc` sampler

So no fan speed or die temperature from it, on an app whose most common question
is "why did the fans spin up". AppleSMC over IOKit gives more, needs **no root**,
and returns each fan's own min and max — which is what makes "2503 RPM" mean
something. Both fans were sitting exactly on their floor while the machine
sounded loud.

Per-process GPU time is absent too, even with `--show-process-gpu`. Reported as
unavailable rather than nil-as-zero.

### WebKit helpers cannot be attributed by process tree or path

WebKit content, GPU and networking processes are XPC services **reparented to
launchd**, so `ppid` is 1. They also live outside the owner's bundle, so the
executable path says `com.apple.WebKit.WebContent`. Both of the obvious links are
dead ends.

`NSWorkspace` names them after their owner — "Ardia Web Content",
"AutoFill (1Password)" — and that string is the only available connection.
Without it, a browser's web content, often the largest single block of memory on
the machine, is attributed to nobody.

### Synthesised `Codable` ignores your default values

Adding one field with a default to a persisted struct made every existing state
file fail to decode, which reset a ten-day study to "day 0". Swift's synthesised
`init(from:)` treats a missing key as an error regardless of the default.

Write `init(from:)` by hand with `decodeIfPresent` for anything that persists, and
make the derived file non-authoritative: Parasite now rebuilds its counters from
the sample files when they disagree with the bookkeeping.

### `String(format:)` with `%s` and a Swift String segfaults

`%s` wants a C string pointer. Passing a Swift `String`, or a `utf8String`
borrowed from a temporary `NSString`, reads freed memory. Pad with string
arithmetic instead.

### Other small ones

- `ps -o args=` splits on the first space, and macOS application paths contain
  spaces, so `/Applications/Google Chrome.app/...` truncated to `Google`. Use
  `-o comm=` for the executable path.
- `top` appends `+`/`-` to any column that changed since the last sample,
  including the counter columns, so a strict integer parse fails on exactly the
  rows that are moving.
- `top`'s `idlew` is cumulative since process start, not a per-interval rate.
- macOS offers scaled display modes **above** the panel's native resolution, so
  "largest available mode" is not native. The mode carrying IOKit's native flag
  (`0x02000000`) is. This machine was rendering a 3600x2338 framebuffer onto a
  3024x1964 panel — 42% more pixels than the screen can show, resampled every
  frame — while the backing scale read as exactly 2.0, so a scale-based check
  found nothing.

## Design decisions

### Two sampling cadences

Catching a spike wants frequent sampling; staying out of the way wants
infrequent sampling. Five seconds for threshold-watching and per-process
accounting, sixty for writing a row, ten minutes for the one collector that
forks. Measured cost: **0.06 s of CPU per 75 s of wall clock**.

### Nothing in the monitor path forks

The diagnostic half shells out to `top` and `powermetrics` and takes seconds. The
monitor reads mach counters, `libproc`, the IORegistry and AppleSMC in-process
and takes ~4 ms. A two-week study is only honest about "minimal impact" if it
never spawns anything.

### The rule engine sizes; the model maps

Specs come from measured percentiles, not from the model's priors. Claude's pass
only maps the requirement onto machines that exist — and is allowed to search the
web for that one job, because the lineup changes faster than training data.

The model has twice corrected the local analyser, both times rightly: once on a
"single-thread bound" verdict that fired on a process using 1.44 cores (the
busiest-process figure is a fraction of *one* core and can exceed 1.0, so a value
above 1.0 means the opposite of single-threaded), and once on treating static
swap as evidence of demand.

### Peak swap is not demand; concurrent demand is

macOS never shrinks the swap file, so a large static figure can be a scar from
last week. Sizing added six days of accumulated swap growth to a peak footprint
from some other day and produced **96 GB**. Pages written out on Tuesday and
never read again are not part of Thursday's working set.

Sizing now uses footprint + swap measured at the *same instant*, p95 — which gave
64 GB against 50.2 GB p95 / 58.3 GB peak concurrent demand.

### Spike events must be rare to be useful

`singleCore` fired 439 times in six days and drowned out everything else. One
pinned core while the machine is otherwise quiet is the normal shape of desktop
work, not an incident. Retired as a trigger; the characteristic lives in the
`cpu1` percentile distribution, which is where it belongs.

### Never force-quit

Apps are asked to quit via `NSRunningApplication.terminate()`, exactly as ⌘Q
does, so anything with unsaved work puts up its own sheet.
`forceTerminate()` would discard that work without asking, which is not a
decision a utility should make for you. Anything still open afterwards is
reported as still open rather than counted as a success.

### No button that claims to free swap

There is no supported way to shrink swap on macOS — no command, no API, no
setting. Anything claiming to "clear swap" is either rebooting or lying. Parasite
shows the ledger and ranks what genuinely helps, with `purge` explicitly labelled
as something that does *not* free swap.

## Things the data said about this machine

Measured over ~244 hours across ten days on a 14-inch M3 Max (14-core CPU,
30-core GPU, 36 GB):

- **Concurrent demand reached 50.2 GB at p95, 58.3 GB at peak**, against 36 GB
  installed. This is the finding that matters for a replacement.
- CPU demand hit 6.8 of 14 cores at p99. Core count is not the constraint.
- GPU was 16% busy at the median. Neither is the GPU.
- 13.7 GB of memory sits in menu-bar agents, CLIs and background tools rather
  than windowed apps, so an app list can only ever reach part of it.
- `spotlightknowledged.updater` was the single largest CPU consumer at 29.7
  core-hours over six days — more than the browser.
