# Parasite

Two things, sharing one set of measurements.

**A two-week usage study.** A background agent watches how you actually use this
machine — CPU, memory, GPU, thermals, and which applications are responsible —
then sizes your next laptop from the evidence instead of from a guess. It runs
always, costs well under a tenth of one percent of a single core, and captures a
detailed snapshot whenever something hits a limit.

**A symptom diagnoser.** Hit the menu bar icon when something feels wrong,
describe it in your own words, and it measures the machine against what this
specific hardware can do.

Built for one M3 Max MacBook Pro. Never going near the App Store.

## The usage study

```bash
./scripts/build.sh --install      # build and install the app
./scripts/install-monitor.sh      # start collecting (runs at every login)
```

Then use the machine normally for two weeks. The **Usage study** pane shows what
it has learned; `./scripts/install-monitor.sh --status` answers "is it running".

### What it costs you

Measured, not estimated: **0.06 seconds of CPU per 75 seconds of wall clock**, and
about 18 MB resident. It runs as a `ProcessType: Background` LaunchAgent at
`nice 10` with low-priority I/O, so macOS schedules it on the efficiency cores
and it never competes with your work. Two weeks of data is a few megabytes.

That is only possible because none of the monitoring path forks a process. The
diagnostic half of Parasite shells out to `top` and `powermetrics`; the monitor
reads the same facts in-process — mach counters for CPU and memory, `libproc` for
per-process accounting, the IORegistry for GPU utilisation, and AppleSMC over
IOKit for fans and temperatures. A full per-process pass costs about 4 ms.

### Two cadences, because the jobs conflict

Catching a spike wants frequent sampling; staying out of the way wants
infrequent sampling. So:

- **Every 5s** — read the near-free counters, sample every process, watch
  thresholds. Per-process sampling has to happen here rather than on the slow
  loop: a process that is born and dies between two polls is invisible to
  `proc_listallpids`, so polling once a minute would erase every short-lived
  compiler or script process from per-app attribution.
- **Every 60s** — write one aggregated row (mean *and* peak, so a spike inside
  the window is not averaged away).
- **Every 10 min** — one `powermetrics` sample, the only collector that forks,
  to anchor real SoC power.
- **On a spike** — a full capture: what crossed, what was running, what was
  frontmost, and what that implies for the next machine.

A spike must hold for 15 seconds before it counts, and each kind has a 15-minute
cooldown, so a page load or a compile does not become an "event".

### How the recommendation is made

Two layers, deliberately separate.

**The local analyser** does the sizing, because that is what the measurements can
actually support. It works in percentiles over *active* hours only (time at a
locked screen is excluded), sizes memory from the 99th percentile plus 25%
headroom, and treats swap as decisive evidence: if pages went to disk, the
observed footprint understates real demand. It also distinguishes a workload that
would use more cores from one pinned on a single thread — where more cores would
buy nothing.

**Claude** maps that requirement onto machines you can actually order. This one
pass is allowed to search the web, because which Macs and memory configurations
are on sale changes faster than any model's training data, and a recommendation
for a machine you cannot buy is worthless.

The split matters: the specs come from your data, not from the model's priors.

### What it deliberately tells you not to buy

Over-specifying is the common failure. The analyser reports where the GPU sat
idle, where core count was never the constraint, and where heat was never a
limiting factor — each with the number behind it.

## Reclaim: idle apps and swap

The **Reclaim** pane answers two questions: what is holding memory that you are
not using, and what can actually be done about swap.

### Quitting what you aren't using

Running apps are ranked by memory held, weighted by how long since each was last
in front. "Last used" comes from the usage study, so it only knows about time
since monitoring began.

Memory is `phys_footprint` from `proc_pid_rusage` — the figure Activity Monitor
calls "Memory", and the right one here: resident size understates an app that has
already been partly paged out.

Helper processes are folded into their owner, including the awkward case. WebKit
content, GPU and networking processes are XPC services reparented to launchd, so
their ppid is 1 and they do not live inside the owner's bundle — the process tree
and the executable path are both useless. NSWorkspace names them after their
owner ("Ardia Web Content", "AutoFill (1Password)"), and that name is the only
link available. Without it, a browser's web content — often the largest single
block of memory on the machine — is attributed to nobody.

Apps are asked to quit exactly the way ⌘Q does, via `NSRunningApplication.terminate()`.
**Never `forceTerminate`.** A graceful request lets an app save, flush, and put up
its own "do you want to save?" sheet; force quitting would discard unsaved work
without asking, which is not a decision a utility should make for you. Nothing is
quit without a confirmation naming the apps, Finder and Parasite itself are never
offered, and whatever is still open afterwards is reported as still open rather
than counted as a success.

### Swap, honestly

**There is no supported way to shrink swap on macOS.** No command, no API, no
setting. The kernel allocates swapfiles under pressure and deletes them when the
pages they back are released, on its own schedule. Anything claiming to "clear
swap" is either rebooting or lying, so Parasite does not offer a button that
frees it.

What it offers instead is the ledger that explains the number — resident, of which
compressed, of which wired, plus what has been pushed out, against what is
installed — and the actions ranked by how much they genuinely help:

1. **Quit what you aren't using.** The only lever that works while the machine
   stays up, and it works indirectly: releasing pages is what lets the kernel
   delete swapfiles, which it does lazily.
2. **Restart.** The only guaranteed way back to zero.
3. **`sudo purge`.** Frees cached and inactive pages. Does *not* free swap, and
   the pane says so.

Per-app swapped-out bytes are available on demand via `vmmap --summary`, under a
separate button because vmmap walks the target's entire VM map — seconds per
browser. It is capped at the largest few processes per app and reports a lower
bound when it could not measure them all, rather than quietly under-reporting.

```bash
P=/Applications/Parasite.app/Contents/MacOS/Parasite
$P --reclaim          # the ledger, the idle apps, and what actually helps
$P --reclaim --deep   # also read per-app swapped-out bytes (slow)
```

The CLI is read-only. Quitting applications is only ever done from the UI, behind
a confirmation.

## Why it is contextualised, not generic

Most monitors tell you a number. Parasite tells you how close that number is to
*your* ceiling:

- It knows the chip's sustained power envelope (about 55 W on a 30-core M3 Max),
  so it can say "the fans are ramping because you are at the SoC's sustained
  limit" rather than "CPU is at 60%".
- It knows the memory bandwidth ceiling (300 GB/s on this variant) and the
  14-inch chassis's smaller thermal headroom.
- It reads each display's *native* panel resolution and compares it to the
  framebuffer actually being rendered. A 3600×2338 framebuffer on a 3024×1964
  panel means the GPU renders 42% more pixels than the screen can show and
  resamples every frame — a continuous cost that a pixel count alone hides.
- It separates a cluster that is *busy* from one that is *busy and downclocked*,
  which is the difference between working hard and being throttled.

## Two layers, deliberately separate

**The rule engine** is local and deterministic. Same snapshot, same findings,
every time — measurements plus thresholds, nothing else. It runs with or without
a network, and it is what you should trust.

**The reasoning pass** sends those findings, the evidence behind them, your
symptom, and matching prior cases to Claude via the `claude` CLI. It weighs them,
picks a primary cause, and may disagree with a rule when the finding does not fit
the symptom. If it fails, you still have the full local report — the capture is
saved to disk *before* the model is ever called, because the machine will not be
in that state again.

## Symptom, habit, and a library that learns

- **Symptom** — what you type. Your words.
- **Activity context** — what you were doing. Auto-detected (running apps, display
  configuration, microphone in use, uptime) and always editable. These tags are
  what later captures match against.
- **Habits** — mined across the whole library, never typed. Once there are a few
  cases it starts finding things like "your bad sessions average 9 days of uptime
  against 2 for the calm ones", or "captures tagged Teams call reach high severity
  70% of the time against a 30% baseline". It needs at least 3 cases before it
  claims anything, because anything less is noise dressed up as insight.
- **Outcomes** — after you act on a diagnosis, say whether it worked. That answer
  goes into the prompt next time, so the model can tell you "this is the fourth
  time, and restarting Descript fixed it before".

Cases are plain JSON, one file per case, in
`~/Library/Application Support/Parasite/cases/`. Nothing is uploaded. A future
agent can read that directory directly.

## Install

Either grab the prebuilt app, or build it:

```bash
# Prebuilt: unzip dist/Parasite.app.zip, move it to /Applications, then
xattr -dr com.apple.quarantine /Applications/Parasite.app
```

A downloaded copy is quarantined by macOS and the app is ad-hoc signed rather
than notarised, so Gatekeeper needs that one command. Building locally avoids it:

```bash
./scripts/build.sh --install --run
```

That builds `Parasite.app`, copies it to `/Applications`, and launches it. It is a
menu bar app (`LSUIElement`), so there is no Dock icon.

### Thermal, power and GPU telemetry (recommended)

`powermetrics` needs root, and it is what makes fan and throttling questions
*measured* rather than inferred — SoC power per domain, per-cluster residency and
frequency, thermal pressure, fan RPM, and per-process GPU time.

```bash
sudo ./scripts/install-privileges.sh
```

This installs a **root-owned wrapper** at `/usr/local/libexec/parasite-powermetrics`
that runs powermetrics with a fixed sampler set, plus a sudoers rule permitting
only that wrapper.

It deliberately does **not** grant `powermetrics` itself. A plain
`NOPASSWD: /usr/bin/powermetrics` rule would be a full root escalation, because
powermetrics can write arbitrary files as root via its `-o` flag — anything running
as your user could then write to `/etc/sudoers.d`. Fixing the arguments in
root-owned code that your user cannot modify closes that path.

Undo it at any time:

```bash
sudo ./scripts/install-privileges.sh --uninstall
```

### The reasoning pass

Uses your existing `claude` CLI sign-in, so there is no API key to store and
nothing billed separately. If analysis fails with an authentication error, open a
terminal, run `claude`, and sign in.

Parasite never executes the commands it suggests. They are shown with a copy
button, and you decide.

## Headless

The same collectors and engine, without the UI. This is the hook for scheduled
jobs and for anything that wants to read the data directly.

```bash
P=/Applications/Parasite.app/Contents/MacOS/Parasite
```

**The usage study**

```bash
$P --usage                  # the study so far, as text
$P --usage --recommend      # also ask Claude for the buying recommendation
$P --usage --json           # the whole profile as JSON
$P --usage --prompt         # exactly what the model is asked, without asking it
```

**Reclaim** — read-only; quitting apps is only ever done from the UI, behind a
confirmation.

```bash
$P --reclaim                # the swap ledger, idle apps, and what actually helps
$P --reclaim --deep         # also read per-app swapped-out bytes (slow)
```

**Symptom diagnosis**

```bash
$P --cli --deep --symptom "fans spun up while editing video"
$P --cli --json --save --analyse --symptom "screen freezing in Teams" \
   --tags "Teams call,External display"
$P --cli --prompt           # print the analysis prompt without calling the model
```

| flag | meaning |
|---|---|
| `--quick` / `--deep` | 4s or 30s capture window (default: standard, 10s) |
| `--symptom "text"` | what you are experiencing |
| `--tags "a,b,c"` | activity context |
| `--analyse` | also run the reasoning pass |
| `--save` | store in the case library |
| `--json` | full case as JSON |
| `--prompt` | print the prompt and exit |

**The monitor daemon** takes `--fast-interval`, `--sample-interval`,
`--power-interval`, `--spike-sustain` and `--spike-cooldown` if you want to trade
resolution against overhead.

## What it measures

| Source | Signals | Root? |
|---|---|---|
| `host_statistics64`, `vm.swapusage` | active/wired/compressed/free, swap use, page and swap I/O *rates* | no |
| `top -l 3` | per-process CPU over the interval, resident size, idle-wakeup *rates* | no |
| `ps -o comm=` | full executable paths, helper roles from `--type=` | no |
| CoreGraphics + IOKit mode flags | framebuffer vs **native panel** resolution, refresh, compositor throughput | no |
| CoreAudio | whether anything is recording — reliable "are you on a call" | no |
| `ProcessInfo.thermalState` | nominal / fair / serious / critical | no |
| **AppleSMC via IOKit** | **fan RPM against each fan's own min/max, die temperatures, system watts** | **no** |
| `pmset -g assertions` | which process is holding the machine awake | no |
| `powermetrics` | SoC power per domain, per-core residency **and frequency**, thermal pressure, per-process energy and disk | **yes** |

Anything a collector could not read is listed in the report as *not measured*, and
passed to the model as an explicit unknown. A missing signal never quietly becomes
a zero.

## A note on numbers that look absurd

Some measurements are genuinely strange rather than wrong. A process reporting a
footprint larger than physical memory is mapping files, not occupying RAM; grouped
totals count pages shared between helpers more than once. Parasite says so inline
rather than hiding it or presenting it as fact.

## Layout

```
Sources/Parasite/
  Models/        machine envelope, snapshot, case, findings
  Monitor/       the usage study and reclaim: fast in-process collectors,
                 daemon, store, analyser, recommendation, swap advisor
  Collectors/    memory, processes, displays, system, powermetrics
  Analysis/      heuristic rules, pattern mining, prompt, claude CLI
  Storage/       case library, settings
  UI/            menu bar panel, capture, report, history, habits, settings
  CLIRunner      headless mode
scripts/
  build.sh                  build / install the .app
  install-monitor.sh        start / stop / inspect the usage study
  install-privileges.sh     one-time powermetrics grant
  parasite-powermetrics     the root-owned wrapper it installs
```

## Known limits

- Camera use is inferred from a camera daemon consuming CPU, not from an
  entitlement. It is labelled as inferred wherever it appears.
- `powermetrics` rejects its `smc` sampler on Apple Silicon, and reports no
  per-process GPU time even with `--show-process-gpu`. Fans and temperatures
  therefore come from AppleSMC over IOKit instead (no root needed); per-process
  GPU time is simply unavailable and is reported as such.
- `powermetrics` reports `idle_ratio` as 0.000 on every CPU *cluster* regardless
  of load. Cluster activity is computed from the per-core ratios instead, scaled
  by `online_ratio` so a powered-down cluster does not look busy.
- Chip power envelopes are a lookup table. Unknown chips report "no figure on
  record" rather than being scored against a guess.
- The reasoning pass needs the `claude` CLI signed in. Without it you get the
  local report and a clear reason why.
- Per-app attribution covers your own processes. Root-owned ones (WindowServer,
  kernel_task) are invisible to a user agent, so they appear in the machine-wide
  CPU figure — which comes from host tick counters and misses nothing — but not
  in the per-app table.
- A process that lives for less than one 5-second tick still escapes per-app
  attribution. Its CPU is counted in the machine-wide total.
- The per-app memory list covers windowed applications. Menu-bar agents, CLIs and
  background tools are a real share of memory (13+ GB on this machine) and are
  reported as a separate line rather than folded in, because quitting them is not
  something a list of apps should invite.
- Converting a sample count to a duration needs the sampling cadence, which the
  monitor now records in its state file. Two places had hard-coded a minute and
  so reported foreground time as 12x reality.
- `proc_taskinfo` reports CPU time in **mach ticks, not nanoseconds**. On Apple
  Silicon the timebase is 125/3, so treating them as nanoseconds under-reports
  every process by ~41.7x — a pinned core reads as 2.4%. Likewise
  `[UInt64].map(Double.init)` silently binds to `Double(bitPattern:)` and yields
  denormal garbage. Both were real bugs here before they were caught.
