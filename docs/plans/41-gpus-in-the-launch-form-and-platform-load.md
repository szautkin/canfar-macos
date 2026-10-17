# Plan 41 — GPUs in the launch form and the platform load

**Date:** 2026-10-16 · **Branch:** `dev_1_4_1` (from `4b88fd0d`) · **Release:** the person's call: 1.4.1 or
the next (see Decided)

The person's request: CANFAR is about to report GPUs. Staging has them now, and production gets them
next week. Be ready to receive them, defensively:

- **The launch form** gets a GPU checkbox. Ticked, the launch sends `gpus=1`. An interactive session
  needs no more than one GPU.
- **Batch jobs**, and the tool that launches them, take as many GPUs as the context's options offer.
- **No GPUs reported, no GPU controls.** If the context or the platform load has no GPUs, the checkbox
  is disabled and the GPU part of the platform load is greyed out. Disabled is fine until the data comes,
  and the app must switch on by itself once it does.
- **The platform load becomes donut charts,** one per resource, with the percentage of load inside.

What staging sends (the person's paste, 2026-10-16):

- **The context** (`/science-portal/api/sessions/context`, the same shape as Skaha's `/v1/context`):
  `gpus: {options: [1…7]}`. It also has fields Verbinal does not read yet: `defaultRequest`,
  `defaultLimit` and `maxInteractiveSessions`.
- **The platform load** (`/science-portal/api/sessions/platform-load`): `cpu`, `ram` and `gpu`, each
  `{used, free}`, plus `maxValues: {cpu, ram, gpu}`. For example GPUs 20 used and 92 free, of 112.

## How it works today

1. **The context.**
   - `ImageService.getContext` decodes `SessionContext` strictly, and `gpus` is required.
   - `PortalImageCacheService` stores the context. If it fails to decode, it stores `nil`.
   - The launch model takes `gpuOptions` from it.
2. **The interactive form** (Standard, Advanced, and iOS) has the GPU stepper only under **Fixed**:
   `ResourceSelectorView`, 0 up to the most offered, shown when that is more than 0.
   - `SessionLaunchModel.launch` sends GPUs only with Fixed.
   - `SessionService.post` adds `gpus` only with `resourceType=custom`.
3. **The batch job form** reuses `ResourceFormSection` and the same stepper.
   `HeadlessService` sends `gpus` when it is more than 0.
4. **Settings ▸ Portal** has a GPUs default picker over `gpus.options`, hidden when the options are
   `[0]`.
5. **The platform load** reads Skaha's `/v1/session?view=stats`.
   - It reads `cores.requestedCPUCores` / `cpuCoresAvailable` and `ram.requestedRAM` / `ramAvailable`.
   - It shows two bars (`MetricBarView`) and the instance counts.
   - Nothing reads GPUs.
6. **The tools.**
   - `launch_session` takes any `gpus` ≥ 0.
   - `launch_headless_job` takes any `gpus` ≥ 0 and warns about scheduling.
   - `show_launch_form` checks `gpus` against 0…max.
   - `get_platform_load` has no GPU.

## What is wrong

| | What | Where | Who it reaches |
|---|---|---|---|
| A | A context without `gpus`, or with `gpus` in another shape, fails to decode as a whole. The cache then stores no context, and the form loses its cores and RAM options as well as GPUs. | `SessionContext`, `PortalImageCacheService.refresh` | Anyone on a platform whose context changes shape. This is the change that is coming. |
| B | Staging's options are `[1…7]`, with no `0`. The Settings picker has no "none", and on load it sets the default to the first option, so the saved default becomes **1 GPU**. | `SettingsView` (`resourceGpus = gpuOptions.first`) | Anyone who opens Settings ▸ Portal once the new context is published. |
| C | An interactive session can ask for up to 7 GPUs: the stepper, `launch_session`, `show_launch_form`, and a relaunch of a recorded launch. | `ResourceSelectorView`, the tools | GPUs are scarce, and a request for 7 waits in Pending. |
| D | A batch job's GPUs are not checked against the options. `launch_headless_job` passes any number to Skaha, which refuses it, or the job waits forever. | `HeadlessAgentTools` | Assistants. |
| E | The platform load cannot show GPUs, and nothing tells an assistant whether there are any. | `SkahaStatsResponse`, `PlatformLoadModel`, `PlatformLoadView`, `get_platform_load` | Everyone, from next week. |

## Steps

One commit per step. After each step: `xcodegen generate`; the gates (macOS tests, package tests, iOS
build); and the string catalogue back to `HEAD` plus the step's own strings, in English and French.
**Tests come first in every step.** Each test named here is written and seen to fail before the code
that makes it pass.

### Step 0 — Settle two facts (the person, or a read that needs the person's OK)

1. **Where the GPU load is in Skaha's stats.** Verbinal reads Skaha's `/v1/session?view=stats` for CPU
   and RAM. The paste above is the Science Portal's own summary, and its field names are not Skaha's.
   Needed: one raw `…/skaha/v1/session?view=stats` from staging, or leave to read Skaha's source. Step 2
   decodes exactly those fields.
2. **Whether Skaha takes `gpus=1` with a Flexible session** (`resourceType=shared`). Settled without a
   launch (Decided, 3): ticking the checkbox makes the form Fixed.

Both are settled under Decided, below, without a request outside Verbinal.

### Step 1 — The context, read defensively (fixes A)

- **`SessionContext.gpus` becomes optional.** A `gpus` that is missing, `null`, or the wrong shape
  decodes as "no GPUs" instead of failing the whole context.
  - Cores and memory decode as before.
  - Unknown fields are ignored, as now.
- **One answer for what is offered.** `GPUOffer`, derived from the context:
  - `none`: no `gpus`, no options, or only `0`;
  - `upTo(n)`: the largest positive option.
  - The launch model, the batch form, Settings and the tools all ask it, so the rule lives in one place.
- **Re-read on every context refresh.** The cache already refreshes stale-while-revalidate. An open form
  follows the new offer when it arrives, with no relaunch.

**Tests** (`SessionContextTests`, new):
- `testStagingsContextDecodes`: the person's paste, with `defaultRequest`, `defaultLimit` and
  `maxInteractiveSessions`, gives `upTo(7)`, cores 1…32 and memory 1…512.
- `testAContextWithoutGPUsStillGivesCoresAndMemory`: no `gpus` key gives `none`, with cores and memory
  read.
- `testAContextWithGPUsInAnotherShapeStillDecodes`: `gpus: null`, `gpus: {}`, `gpus: {options: "1,2"}`
  and `gpus: [1, 2]` each give `none`, and none of them fails.
- `testOnlyZeroOffersNone`: `[0]` gives `none`; `[0, 1, 2]` gives `upTo(2)`.
- `PortalImageCacheServiceTests.testAContextWithoutGPUsIsKept`: the cache stores it, not `nil`.

### Step 2 — The platform load: donuts, with GPUs when reported (E)

**The model:**
- `PlatformLoadModel` keeps three optional loads, CPU, RAM and GPU, each `used` and `total`, with
  `percent` and `free` derived from them.
- GPU is `nil` unless Skaha's stats carry it, in the fields found in step 0, and the numbers make sense:
  `total > 0` and `0 ≤ used ≤ total`.
- Each refresh decides again, so the GPU donut lights up at the first refresh that has GPUs.

**The card** (`PlatformLoadView`, macOS and iOS) shows three donuts side by side: **CPU**, **RAM**,
**GPU**.
- **The ring** is the share used, coloured as the bars are now: accent, orange above 70 %, red above
  90 %. It eases between refreshes (`AppMotion`).
- **Inside**, the percentage of load, for example **39 %**.
- **Below**, the name, then "1,836 of 3,000 cores free". RAM is in GB, GPUs as a count.
- **No GPU data:** the GPU donut is a grey ring with "—" inside and "Not reported" below, at secondary
  contrast, and its help text says "This platform does not report GPUs yet". CPU and RAM are greyed the
  same way when their numbers are missing.
- **Unchanged:** the refresh button, "Last updated" and the instances line.
- **Narrow cells:** a cell too narrow for three donuts in a row stacks them, with
  `ViewThatFits`, a row and then a 2 + 1 grid.
- **For assistive reading,** each donut is one element. For example, label "CPU load", value "39 %,
  1,836 of 3,000 cores free". The ids are `portal.load.cpu`, `portal.load.ram` and `portal.load.gpu`.

**The tool:** `get_platform_load` adds `gpu: {used, free, total, percent}`. When there is none it gives
`gpu: null` and `gpuNote: "This platform does not report GPUs."`

**Tests:**
- **`PlatformServiceTests`**
  - `testStatsWithGPUsGiveTheGPULoad`: a staging sample.
  - `testStatsWithoutGPUsGiveNoGPULoad`: today's production shape.
  - `testNonsenseGPUNumbersGiveNoGPULoad`: `total` 0, `used > total`, or negative.
- **`PlatformLoadModelTests`**
  - `testTheGPULoadLightsUpWhenItArrives`: a refresh without GPUs, then one with them, then one
    without again. Nothing is kept from an earlier refresh.
  - `testPercentagesAreTheShareUsed`: CPU 1,164.4 of 3,000 is 39 %, and GPU 20 of 112 is 18 %.
- **`PlatformLoadToolTests`**
  - `testTheToolGivesTheGPULoad`;
  - `testTheToolSaysWhenThereIsNoGPULoad`.
- **On screen** (`PlatformLoadLayoutTests`, real window, AX):
  - `testThreeDonutsWithTheirPercentages`: the AX values read "39 %", "79 %" and "18 %".
  - `testTheGPUDonutIsGreyWithoutData`: its value is "Not reported".
  - `testTheDonutsFitTheNarrowestCell`: at the card's narrowest and widest widths, nothing spills out
    of the card. Checked again after another screen and back, as in `ViewerLayoutTests`.
  - A window capture to the scratchpad, to look at, in light and dark.

### Step 3 — The interactive launch form: a GPU checkbox (C, and B)

**The form:**
- On the Standard and Advanced tabs, and on iOS, the GPU stepper is replaced by a checkbox, **Use a
  GPU** (`portal.launch.gpu`).
  - Where it shows: under Resources, in both modes. Ticking it in Flexible makes the form Fixed
    (Decided, 3).
  - **Ticked**, the launch sends `gpus=1`.
  - **Not ticked**, it sends no `gpus` at all, as now.
- **Disabled when `GPUOffer` is `none`**, greyed, with the help text "This platform offers no GPUs".
  - A tick from before is cleared and not sent.
  - It enables by itself when a refreshed context offers GPUs.
- The checkbox does not depend on the platform load. Skaha checks a launch against the context, and a
  load that has not been fetched should not block a launch. (Decided, 2.)

**Settings and saved launches:**
- **Settings ▸ Portal:** the GPUs default becomes the same checkbox, **Use a GPU by default**, disabled
  with no offer. **B is fixed:** options without a `0` no longer make the default 1.
- **Saved defaults and recent launches:**
  - A recorded interactive launch with more than one GPU relaunches with one.
  - With no offer, it relaunches with none, and the status says "Relaunched without a GPU: this
    platform offers none".
  - The record itself is not rewritten.

**The tools:**
- `launch_session` takes `gpus` 0 or 1. Refused, as `invalidArgument`:
  - `gpus` 2 or more: "An interactive session takes at most one GPU; batch jobs take more";
  - `gpus` 1 with no offer: "This platform offers no GPUs".
- `show_launch_form` checks the same on the Standard and Advanced tabs.

**Tests:**
- **`SessionLaunchModelTests`**
  - `testTheCheckboxSendsOneGPU`: ticked in Flexible, the form becomes Fixed and sends `gpus=1`.
  - `testNoTickSendsNoGPUs`;
  - `testNoOfferDisablesAndClearsTheTick`;
  - `testAnOfferArrivingEnablesTheCheckbox`: the context refreshes while the form is open.
  - `testARecordedLaunchWithSeveralGPUsRelaunchesWithOne`;
  - `testARecordedLaunchRelaunchesWithoutAGPUWhenNoneIsOffered`.
- **`SessionServiceTests`**
  - `testTheFormCarriesGPUsOneWhenTicked`: the posted form data has `gpus=1`.
  - `testTheFormCarriesNoGPUsUnticked`: no `gpus` key.
- **`SettingsPortalDefaultsTests`**
  - `testOptionsWithoutZeroDoNotMakeAGPUTheDefault`: B, written to fail first.
- **`LaunchSessionToolTests`**
  - `testTwoGPUsAreRefusedForAnInteractiveSession`;
  - `testAGPUIsRefusedWhenNoneIsOffered`;
  - `testOneGPUIsSent`.
- **On screen**, in the launch form in a real window: the checkbox is there, enabled or disabled as
  offered, its AX value follows the tick, and the form still fits its sheet at its narrowest width.

### Step 4 — Batch jobs: as many as offered (D)

**The form:**
- The batch form keeps its stepper. It now runs 0 up to the most `GPUOffer` offers, and a gap such as
  `[1, 2, 4]` steps only through the options plus 0.
- With no offer it is disabled at 0, with the same help text.
- It shows under the batch form's own Resources, as now.

**The tool:** `launch_headless_job` checks `gpus` against the options. Outside them, it is refused with
the range named: "GPUs: 0, or one of 1–7". With no offer, any `gpus > 0` is refused. The scheduling
warning stays.

**Tests:**
- **`HeadlessLaunchModelTests`**
  - `testTheStepperRunsThroughTheOptions`: `[1…7]`, then `[1, 2, 4]`.
  - `testNoOfferDisablesItAtZero`;
  - `testTheJobCarriesItsGPUs`: the form pairs have `gpus=7`.
- **`LaunchHeadlessJobValidationTests`**
  - `testGPUsBeyondTheOptionsAreRefused`: 8 with options `[1…7]`;
  - `testSevenGPUsAreSent`;
  - `testNoOfferRefusesGPUs`.

### Step 5 — Seen on screen; the manual and the handout

**On the live app,** over MCP with the person's OK:
- Today's production shows the GPU donut grey and the checkbox disabled, with `get_platform_load`
  `gpu: null`.
- If the person points Endpoints at staging, the GPU donut has its numbers and the checkbox enables. A
  launch with it ticked has `GPU: 1` on the session's card. That launch is the person's choice, as it
  spends their allocation.

**The manual, English and French:**
- the Portal's platform load, as donuts with GPUs;
- the launch form's **Use a GPU**;
- batch jobs' GPUs;
- Settings ▸ Portal's default.

**The handout:** handout 37 gains section O: production without GPUs, staging with them, and the
tools' limits.

## For the person

- **The platform load** is three rings, CPU, RAM and GPU, each with how loaded it is inside. GPU stays
  grey until CANFAR reports GPUs.
- **The launch form** has **Use a GPU**, greyed while the platform offers none.
- **Batch jobs** can ask for as many GPUs as the platform offers.
- **Next week** none of this needs an update: it lights up when the data comes.

## What it costs

- **No new requests.** The context and stats are fetched as now: the context through its cache, the
  stats on the card's own refresh.
- **The donuts** are three `Circle().trim` shapes, cheaper than today's `ProgressView`s, animated only
  when a number changes.

## Not doing

- **No reading of the Science Portal's own `platform-load` API.** Verbinal keeps to Skaha, where it
  already signs in. (Decided, 1.)
- **`maxInteractiveSessions`, `defaultRequest` and `defaultLimit`** are not read. They are new fields
  for other features.
- **No GPU type or model choice.** The context offers counts only.

## Decided (2026-10-16)

The person asked for the plan to be implemented without answering the questions. Each takes the plan's
recommendation, and each can be changed later:

1. **Skaha's GPU fields: not looked up outside Verbinal.** The GPU load is read when Skaha's stats carry
   one of two shapes, under `gpus` or `gpu`:
   - Skaha's own shape for CPU and RAM: a `requested…` count and an `…Available` total;
   - the Science Portal's: `used` and `free`, with `maxValues.gpu`.
   Anything else is "no GPU data". When the stats carry GPU fields of another shape, `get_platform_load`
   names them in `gpuNote`, so the reader can be pinned to the real fields after next week's publication.
2. **The context alone enables the checkbox.** The load only colours the donut.
3. **The checkbox shows in both modes, and ticking it makes the form Fixed.** That is the combination
   Skaha is known to take: `resourceType=custom` with `gpus=1`. The switch shows on screen: the cores and
   RAM pickers appear at the context's defaults. Unticking leaves Fixed as it is. The same rule applies
   to an assistant: `show_launch_form` with `gpus` already makes the form Fixed.
4. **Branch:** `dev_1_4_1`, where the work is. Which release ships it stays the person's choice.

## Where it ended (2026-10-16)

| Step | Commit | What |
|---|---|---|
| Plan | `f85eecdb` | This plan, and what was decided without the person's answers. |
| 1 | `8a418530` | The context read defensively. `gpus` missing, null or in an unknown shape means no GPUs; cores and memory are read as before. `GPUOffer` is the one rule for what is offered. |
| 2 | `cd22245a` | The platform load as three rings, with the percentage inside and "N of M … free" below. The GPU ring is grey until the stats carry GPUs, in Skaha's shape or the Science Portal's. `get_platform_load` gives `gpu`, or `gpu: null` and a `gpuNote` that names any GPU fields it could not read. |
| 3 | `f7cf5da4` | **Use a GPU** for an interactive session. Ticked, it makes the form Fixed and sends `gpus=1`. One GPU at most everywhere: saved defaults, relaunches, `show_launch_form`, `launch_session`. Settings ▸ Portal's default is a checkbox, which fixes B. Settings ▸ Portal moved to a file of its own. |
| 4 | `57cc020a` | Batch jobs step through 0 and the counts offered, greyed when none is. `launch_headless_job` refuses a count outside the offer and names the range. |
| 5 | (this commit) | Manual, English and French: the Portal's platform load and launch form, batch jobs, and Settings ▸ Portal. Handout 37 gains section O. |

**Where it differs from the plan, and why:**
- **Step 2: a ring with no numbers before the first load** shows "—", not "Not reported". Nothing has been read yet, so "not reported" would be untrue.
- **Step 3: an open form follows the cache.** The form reads the context when it loads, and refreshes a cache older than a day in the background. It now also takes the offer when it appears and whenever the cache changes, so Settings' **Refresh Now** reaches an open form. It takes only the offer, and resets none of the person's choices.
- **Step 3: before the context is known, nothing is judged.** A relaunch keeps its one GPU, and `show_launch_form` does not refuse one. Both tools judge only against a context the app has; without one, Skaha judges.
- **Step 4: `show_launch_form` keeps its resources for the interactive form.** It applied them to that form even with the Headless tab shown, before this plan too. Its `gpus` is therefore 0 or 1, and a batch job's count is `launch_headless_job`'s.
- **Step 4: the GPU row is greyed as a whole.** A disabled stepper alone looked the same as an enabled one in the window capture: its label and count kept their colour.

**Verified:** the full gates after every step, ending at 2,255 tests, the package tests and the iOS build. The accessibility tests ran with the screen unlocked. Each fix's test was seen to fail with the old behaviour put back: the GPU reader stubbed in step 2, five lines in step 3, three in step 4. Window captures, looked at:
- the rings at 240, 323, 420 and 1,000 points, light and dark, with GPUs and without;
- the launch form's checkbox enabled, greyed, and ticked with the fixed sizes;
- the batch tab's stepper enabled and greyed.

**Still to verify:**
- **On the live app,** after the person runs a build from `57cc020a` or later: handout 37 section O. On production now (O1, O2), and on staging-src (O3–O7). The running app was `745d4bf1`, built before this plan.
- ~~**Skaha's GPU fields**~~ — known since plan 42 step 1: `gpu: {requestedGPU, gpuAvailable, maxGPU}` on `view=stats`, from science-portal 2026.3's server code. The reader takes those names, and the guessed shapes are gone.
- **The manual's Portal picture** (`docs/images/*/06-portal-sessions/portal.png`) still shows the bars. It is retaken with the other pictures.
