# Plan 42 — GPUs by tab, the guides, and the Portal's three cards

**Date:** 2026-10-16 · **Branch:** `dev_1_4_1` (from `131a0f27`, after plan 41) · **Release:** 1.4.1,
with plan 41 (the person, 2026-10-16)

The person's review of plan 41:

1. **GPUs.**
   - The context's `gpus.options` are not for the launch form. In Verbinal's Portal a person gets one
     choice, a GPU or not: a checkbox.
   - Batch jobs take as many GPUs as the options list.
   - So, the person asks, do calls through the API for sessions that serve an endpoint, such as
     contributed sessions?
2. **The cards.** Platform Load, Storage and Batch Jobs should share what they have in common:
   - the reload button;
   - one layout;
   - nothing that jumps when reload is clicked or its spinner shows.
3. **Platform Load while refreshing.** Its rings spin, and their numbers give way to a small spinner.
4. "Make it neat."

Then:
- **"Advanced mode and headless mode should have gpu options as reported by the context endpoint."** So
  only Standard keeps the checkbox.
- **"We also need to update the MCP guides for this as well."**
- **"We stick to our UI."** From opencadc/science-portal only the endpoints are taken.

**Then, on where the GPU load comes from:** "it should be in stats, platform load is the nextjs". The
GPU numbers are in Skaha's stats, `/v1/session?view=stats`, which Verbinal reads already. The Science
Portal's `api/sessions/platform-load` is its Next.js server's own summary of those stats, not a source
of its own. Verbinal stays with Skaha.

## How it is now

**GPUs (plan 41):**
- The launch form has **Use a GPU** on every interactive tab.
- The batch tab's stepper runs through 0 and the options.
- `launch_session` refuses `gpus` above 1 for every session type, contributed ones included.
  `launch_headless_job` takes 0 or one of the options.
- The GPU load is read from Skaha's `/v1/session?view=stats`, the right place. It accepts two guessed
  shapes:
  - Skaha's own for CPU and RAM, `requested…` and `…Available`;
  - the Next.js summary's, `used`, `free` and `maxValues`, which never appears in Skaha's stats.
- Skaha's GPU fields are now known (step 1): `gpu.requestedGPU`, `gpu.gpuAvailable`, `gpu.maxGPU`.

**The cards.** All three models already share one load state, `Phase<Date>`: working, loaded at a time,
or failed, keeping the last values. The views share nothing:

| | Platform Load | Storage | Batch Jobs |
|---|---|---|---|
| Reload button | Yes | **None** | Yes |
| While reloading | A `ProgressView` is **inserted** beside the button: the button moves left | The readout is **replaced** by a spinner: the card's height jumps | The icon **becomes** a `ProgressView`, a different size: the header shifts |
| When | "Last updated: 04:37:18" | Nothing | A countdown, "32s", in the header |
| Before the first load | Rings show "—" | A spinner, then the readout | A spinner, then the pills |
| Loads | At sign-in, and on the button | At sign-in only | Every 45 s, and on the button |
| Header | Label, `.headline` | Label, `.headline` | Label, countdown, button, **Jobs & History…** |

On iOS all three show in the Monitor tab and the adaptive layout too.

## What is wrong

| | What | Who it reaches |
|---|---|---|
| A | Storage cannot be refreshed: its numbers are those from sign-in, however long ago. | Everyone, after an upload or a delete. |
| B | Reloading moves things. The Platform Load button jumps left. Storage's card collapses to a spinner and grows back. Batch Jobs' header shifts when the icon becomes a spinner. The card beside it moves with each one. | Everyone, every 45 s for Batch Jobs. |
| C | Each card says when it was updated, and that it is updating, in its own way, or not at all. | Everyone. |
| D | An interactive session can have one GPU, through any door, Advanced and `launch_session` included. Sessions on custom images, such as a contributed session serving an endpoint, may need more. | People on the Advanced tab, and assistants. |
| F | What assistants are told is behind: nothing in the brief says where GPUs are offered or how to ask for them, and a line says omitted sizes take Skaha's 2/8/0, which `launch_headless_job` has not done since plan 15. | Every assistant. |
| E | Plan 41 guessed Skaha's GPU fields. It happens to read `gpu.requestedGPU`/`gpu.gpuAvailable` by prefix and suffix, but also accepts shapes Skaha never sends, and ignores `maxGPU`. | Everyone, from next week: a guess that matches is still a guess. |

## Steps

One commit per step. After each step: `xcodegen generate`; the gates (macOS tests, package tests, iOS
build); and the string catalogue back to `HEAD` plus the step's own strings, in English and French.
**Tests first in every step**: each test named here is written and seen to fail before the code that
makes it pass, or, for a fix, fails with the old behaviour put back.

### Step 1 — Skaha's GPU fields, by their names (E)

**The endpoints, from opencadc/science-portal branch `2026.3`.** Only what its server reads from Skaha
and sends to it (commits `a401c48c`, `2d301700`); none of its interface.
- **Stats.** `/v1/session?view=stats` carries `gpu: {requestedGPU, gpuAvailable, maxGPU}`. A sample:
  `{requestedGPU: 15, gpuAvailable: 112, maxGPU: 7}`.
  - The block is absent, or `null`, when the cluster does not report GPUs. It counts as reported when
    its numbers are numbers.
  - `requestedGPU` is in use, and `gpuAvailable` is the cluster's total, as `cpuCoresAvailable` is for
    CPU, so free is the one less the other.
  - `maxGPU` is the most for one session, the context's largest option.
- **Context.** `gpus.options` offers GPUs when any count is above 0. That is `GPUOffer.offersAny`
  already.
- **A launch.** A requested GPU is posted as `gpus=1`, as Verbinal's interactive form does.

**The reader:**
- `GPUStats.read` reads `gpu.requestedGPU` and `gpu.gpuAvailable` by name, numbers or numeric strings,
  and `gpu.maxGPU` when it is there.
- The guesses go: the `requested…`/`…Available` match by prefix and suffix, the `gpus` key, and the
  Next.js summary's `used`/`free`/`maxValues`.
- The nonsense checks stay: total above 0, 0 ≤ in use ≤ total.
- `gpuNote` stays for a block it cannot read, naming its fields.
- `get_platform_load`'s `gpu` adds `perSession` (`maxGPU`) when Skaha gives it.

**Tests first:**
- the sample above, read: 15 in use, 97 free, 112 in all, 7 per session;
- the block absent, `null`, or with `gpuAvailable` not a number: no GPU load;
- `{"gpus": {"requestedGPUs": …}}` and the Next.js `gpu: {used, free}` are no longer read, and are named
  in `gpuNote`;
- numeric strings read as numbers.

Plan 41's tests that used the guessed shapes take the real one. Plan 41's closing section says so.

**On the live app** (step 5), on staging-src: the GPU ring lights with staging's numbers.

### Step 2 — GPUs by tab: one on Standard, the context's options on Advanced and Headless (D)

The person: "advanced mode and headless mode should have gpu options as reported by the context
endpoint".

**The form:**
- **Standard** keeps **Use a GPU**: one GPU or none.
- **Advanced** gets the batch tab's GPU stepper. Under Fixed, it runs through 0 and the context's
  options (`GPUOffer.step`), and is greyed at 0 while none is offered. It has no checkbox.
- **Headless** is as plan 41 left it: the same stepper.

**The model:**
- Standard and Advanced share `SessionLaunchModel`, and one `gpus`. The launch now says which tab it is
  from: `launch(from: .standard | .advanced)`. Standard sends one GPU at most; Advanced sends the count,
  if `GPUOffer.allows` it. Today `useCustomImage` marks Advanced only on its own launch, so a Standard
  launch after a visit to Advanced could take Advanced's count.
- Switching tabs keeps the count, and each tab shows it in its own control. A Standard tab showing
  Advanced's 4 shows **Use a GPU** ticked, and sends 1. The test says so.
- Saved defaults (Settings ▸ Portal) stay one GPU or none, being Standard's.

**A relaunch** sends the recorded count when the offer still allows it. When it no longer does, it
sends the largest count offered below the recorded one, or none, and the status says which: "Relaunched
with 2 GPUs: this platform offers 1, 2, 4". With nothing offered: "Relaunched without a GPU". Plan 41's
cap of one at a relaunch goes, because a record may now come from Advanced.

**The tools:**
- **`launch_session`** is the API's launch, any image and type, as on Advanced. It takes 0, or one of
  the options, and refuses another count naming the range ("gpus 8 is not offered: 0, or one of
  1–7."), or any GPU where none is offered. Plan 41's cap of one goes.
- **`show_launch_form`** checks `gpus` by its tab: `standard`, the default, takes 0 or 1; `advanced`,
  or an image not in the catalogue (which shows Advanced), takes the options. As before, the resources
  fill the interactive form.
- **`launch_headless_job`** is unchanged: the options.

**Tests first** (`SessionLaunchGPUTests`, `LaunchFormGPULayoutTests`):
- `testAdvancedSendsTheCountChosen`: 4 with options 1–7, posted `gpus=4`.
- `testStandardSendsOneAfterAdvancedChoseFour`: same model, Advanced at 4, launched from Standard:
  `gpus=1`.
- `testAdvancedStepsThroughTheOptions`, with a gap.
- `testARelaunchKeepsAnOfferedCount`; `testARelaunchTakesTheLargestOfferedBelow`, with the status;
  `testARelaunchWithoutAnOfferSaysSo`.
- `testLaunchSessionTakesTheOptions`: 4 sent; 8 refused naming 1–7; 1 refused with no offer.
- `testShowLaunchFormChecksByTab`: standard 2 refused, advanced 2 taken.
- On screen: Advanced, Fixed, shows the GPU stepper, enabled with an offer and greyed without, and no
  checkbox. Standard shows the checkbox and no stepper. Both fit the 620-point sheet.

### Step 3 — The MCP guides say the same

What an assistant is told about GPUs, everywhere it is told it:
- **`describe_app`'s brief** gets a short **GPUs** paragraph:
  - where the offer is: the context, which the form and tools follow;
  - `get_platform_load`'s `gpu` (used, free, total, `perSession`), or `gpu: null` with `gpuNote`;
  - the rule: Standard one, while Advanced, `launch_session` and `launch_headless_job` take 0 or one of
    the options;
  - GPUs are scarce: check `gpu.free` before asking, and use them only for GPU work.
  Its stale line goes: an omitted size "inherits Skaha's 2/8/0", though `launch_headless_job` has
  forced 1/1/0 since plan 15.
- **Tool descriptions:**
  - `launch_session`'s `gpus`: "0, or one of the options the platform offers".
  - `show_launch_form`'s `gpus`, by tab.
  - `get_platform_load`, with `perSession`.
  - `launch_headless_job` names `get_platform_load`'s `gpu.free`.
- **The built-in workflows** that launch batch jobs (`canfar-batch-reprocessing`,
  `canfar-survey-to-candidates`): one line at their launch step. For GPU work, check
  `get_platform_load`'s `gpu`, and ask for a count the platform offers.
- **`docs/agent-ui-parity.md`:** the Advanced tab's GPU stepper, and the three cards' reload buttons
  (step 4), each with its tool.
- **The manual,** chapter 12 (the AI assistant), English and French: what an assistant can ask for in
  GPUs.

**Tests first:**
- `DescribeAppToolTests.testTheBriefSaysHowGPUsAreAsked`: the brief names `get_platform_load`, `gpu`,
  `perSession`, and the rule per tab and tool. It no longer says "inherits Skaha's 2/8/0".
- `ToolDescriptionTests`: each GPU-taking tool's schema describes `gpus` with the rule its `plan`
  enforces, so the description and the check cannot drift. The test calls `plan` with the counts the
  description allows and refuses.
- The workflows still parse (`WorkflowStore` loads every built-in), with the new lines.

### Step 4 — One card, three times (A, B, C)

`PortalCardShell`, a new view in `Views/Components/`, is what the three cards share:

**The header:**
- The card's icon and title (`.headline`).
- Then an optional accessory, such as Batch Jobs' **Jobs & History…**.
- Then the **reload button**, the same on each card. It has a fixed 18-point slot holding both the
  arrow and a small spinner, one of them shown, so nothing moves when it turns. Its ids are
  `portal.load.refresh`, `portal.storage.refresh` and `portal.batchJobs.refresh`. Its label is
  "Refresh <card>", with the value "Refreshing" while it works. It is disabled while it works.

**The body:** the card's own content. On a refresh it **stays**, showing the last values. Step 5 shows
that it is refreshing without changing anything's size.

**The footer:** one line, always there, so the card's height is the same before, during and after a
load:
- "Updated 16:04:05"; Batch Jobs adds "· next in 32 s", its countdown moved out of the header;
- before the first load, a placeholder of the same height;
- a failure as now, with `ProblemView`, compact, under the body. A failure is news, and may move
  things.

**The three cards:**
- **Platform Load** loses its inserted spinner.
- **Storage** gets a reload button, `StorageModel.reload()`, which fixes A. It keeps its readout during
  a refresh instead of a spinner.
- **Batch Jobs** moves its countdown to the footer and keeps **Jobs & History…** in the header.
- The cards' padding and spacing come from the shell: 10 points between parts, as now.

**Tests** (`PortalCardsLayoutTests`, real windows, AX):
- `testEachCardHasTheSameReloadButton`: the three ids, labels and help texts.
- `testNothingMovesWhileACardReloads`: each card loaded, then reloading. The network is held 2 s by
  the test's mock. The frames of the reload button, the header's other controls, the body and the card
  itself are the same, within half a point, while it reloads and after.
- `testACardIsAsTallBeforeItsFirstLoad`: the placeholder's height equals the loaded card's.
- `testStorageReloads`: its button calls the quota again, and "Updated" moves on.
- `testTheFooterSaysWhen`: "Updated …" on all three, and "· next in … s" on Batch Jobs.
- The row's three cards keep one height together (`PortalCardStyle`), loaded and reloading. Checked
  at the narrowest wide arrangement (1,000-point window) and in the one-column arrangement.

### Step 5 — Refreshing, seen (point 3)

**Platform Load:**
- Each ring's arc becomes a quarter arc **spinning** round the track, and the percentage gives way to
  a **small spinner**.
- The "N of M … free" lines stay, dimmed, so nothing below moves.
- When the new numbers come, the arc eases from where it spun to its share.
- **Before the first load**, the rings are the same: spinning, with spinners.
- **With Reduce Motion**, no spinning: the arc is still, dimmed, and the spinner alone says so.

**Storage and Batch Jobs:** while refreshing, the figures stay and dim to the same degree. The header's
spinner says the rest. No placeholder replaces them.

**One rule for "refreshing":** a single shared modifier, `.refreshing(_:)`, for the dimming, so the
three dim alike.

**Tests:**
- `LoadDonutView` reads, while refreshing, "Refreshing" in its AX value, and has no percentage. After
  the load it has its percentage again.
- `testTheRingsSpinOnlyWithoutReduceMotion`: a pure function, `LoadDonutView.spins(refreshing:reduceMotion:)`.
- On screen, mid-refresh (network held), window captures to look at: the three cards, light and dark,
  at 323 and 1,000 points. The frame checks of step 4 run here too, with the spinning rings.

### Step 6 — Seen on the live app; the manual and the handout

**On the live app,** with the person:
- on staging-src, through Settings ▸ Endpoints:
  - the GPU ring with staging's numbers, and `get_platform_load`'s `gpu` with `perSession`;
  - Advanced's GPU stepper through 1–7;
  - `describe_app`'s GPU paragraph;
- the three cards refreshing, by button and by Batch Jobs' poll;
- `list_ui_targets` finds the three reload buttons;
- `point_at_ui portal.storage.refresh`.

**The manual,** English and French: the Portal's cards, with the reload button on each and
"Updated …"; Platform Load while refreshing.

**The handout:** handout 37 gains section T, the cards. Section O changes:
- Advanced's stepper (O5);
- `launch_session` with `gpus: 4` taken and `show_launch_form` by tab (O6);
- a relaunch of a 4-GPU launch where 4 is no longer offered (O8).

## For the person

- **Every card** has the same reload button in the same place, and says when it was last updated.
  Storage can now be refreshed too.
- **Reloading moves nothing.** The numbers stay, dimmed, while new ones come.
- **Platform Load's rings spin** while they refresh, with a small spinner where the percentage was.
- **GPUs:** Standard keeps **Use a GPU**. Advanced, like Headless, has a GPU count of its own,
  through what the platform offers. An assistant can ask for the same counts, and its guides say how.

## What it costs

- **One request more:** Storage's quota, when the person clicks its reload button.
- **The spinning** is one rotation animation per ring, only while a load is under way, and none with
  Reduce Motion.

## Not doing

- **Nothing of the Science Portal's interface.** Verbinal keeps its own: the rings, the cards, the
  checkbox. From opencadc/science-portal only the endpoints are taken: what Skaha sends and takes.
- **No new polling.** Platform Load and Storage refresh at sign-in and on their buttons, as before.
- **The Science Portal's `platform-load`** is not read. It is the Next.js server's summary of Skaha's
  stats, which Verbinal reads itself.

## Decided (2026-10-16)

The person's answers:
1. **`launch_session` takes the options** for any image and type, as Advanced does ("ok").
2. **Release:** "current branch 1_4_1". Plan 42 goes in 1.4.1, with plan 41.

## Where it ended (2026-10-16)

| Step | Commit | What |
|---|---|---|
| Plan | `b62a9099` | This plan, and the person's answers. |
| 1 | `4b578319` | Skaha's GPU block read by its names: `gpu.requestedGPU`, `gpuAvailable`, `maxGPU`. Plan 41's guessed shapes are gone, and `get_platform_load`'s `gpu` has `perSession`. |
| 2 | `7df5518b` | GPUs by tab. Standard keeps **Use a GPU**. Advanced has the counts the context offers, on the Mac and iOS, as Headless does, and `launch_session` takes them too. `show_launch_form` judges by its tab. A relaunch keeps an offered count. Fixed on the way: after **Launch (Custom Image)**, the Standard tab launched Advanced's image. |
| 3 | `403de96f` | The MCP guides. `describe_app`'s brief has a **GPUs** section, and its line saying an omitted batch size takes Skaha's 2/8/0 is fixed. `show_launch_form`'s words cover GPUs. The two batch workflows note where GPUs are read. The parity doc and the manual's assistant chapter are updated. |
| 4 | `cda2ebab` | `PortalCardShell` for Platform Load, Storage and Batch Jobs. One reload button in a fixed slot; the body kept while reloading; "Updated …" at the foot, with Batch Jobs' countdown. Storage can be refreshed. Each card is its full height before its first load. |
| 5 | `deb0e06a` | Refreshing, seen. The rings spin a quarter arc with a small spinner inside, still with Reduce Motion, and the other cards' figures dim alike. |
| 6 | (this commit) | The manual, English and French: the cards and refreshing. Handout 37 section O changed (O5, O6) and gained O8 and O9, and section T is new (first named P, a letter already taken: renamed at the live check). |

**Where it differs from the plan, and why:**
- **Step 2: iOS.** The iOS launch tab shows one Resources section for both tabs. It now shows the checkbox on Standard and the stepper on Advanced, and launches with its tab. It had the same Advanced-image bug.
- **Step 4: the footer before the first load** says "Loading…", or "—" when idle, not a blank line. A blank line has no accessibility element, and an assistant could not tell the card is loading.
- **Step 4: Platform Load's rings without numbers** have two caption lines, as with numbers. One line had made the card 13 points shorter before its first load.
- **Step 4: the instances line** still appears with the first stats that carry instance counts. That is a once-only change, never on a refresh, and the platform seldom sends them.

**Verified:**
- The full gates after every step, ending at 2,276 tests, the package tests and the iOS build. The accessibility tests ran with the screen unlocked.
- Each step's tests failed before its change, or with the old behaviour put back:
  - step 1: the old reader;
  - step 2: five lines, including the image bug;
  - step 3: the guides as they were;
  - step 4: today's cards, where Platform Load moved 8 points, Storage collapsed, and Batch Jobs' button shifted;
  - step 5: the rings not told they were refreshing.
- Window captures, looked at:
  - the three cards, loaded and refreshing, light and dark, at 323 and 1,000 points;
  - the Advanced tab's stepper, enabled and greyed.

**Still to verify,** on the live app, which was `131a0f27` (plan 41's end) at the time:
- handout 37 sections O and T with a build from this commit;
- on staging-src, the GPU ring with staging's numbers and `perSession`, and Advanced's stepper through 1–7;
- the manual's pictures of the Portal (`portal.png`) and of the Advanced tab still show the old cards and form. They are retaken with the other pictures.

## The live check (2026-10-16, build 327db45d)

An assistant over MCP, on production. Production's context now offers 1–7 GPUs; its platform load
does not report them yet.

**As planned:**
- The GPU ring: grey, **Not reported**; `get_platform_load` has `gpu: null` and its `gpuNote`.
- **Use a GPU** enabled on Standard, now that production offers GPUs. The person's notebook2 was
  launched with it and runs with one GPU.
- Advanced takes 7, and refuses 99 and 8, naming 1–7. Standard refuses 2, naming both tabs' rules.
  `launch_session` refuses 8. `describe_app` has its **GPUs** section. `man` gives the tools' new
  words: the client had cached the old ones.
- The three reload buttons are listed with their ids, and `point_at_ui portal.storage.refresh` rings
  Storage's.

**Found, and fixed in this commit** (each test failed first):
- **The footers' time was a twelve-hour clock with no AM or PM.** At 19:18 they said "07:18:36". They
  now give the time in 24 hours, as the session cards and the session log do. Platform Load had had it
  since before plan 42; plan 42 gave it to all three cards.
- **`list_recent_launches` missed notebook2,** which the Recent Launches card showed. The tool had its
  own copy of Recent Launches, read once when the tools were made, and an assistant's launches were
  saved to a third copy. Two copies over one file drop each other's launches when they write. There
  is now one, AppState's, and a guardrail says each store is made once.
- **`show_launch_form` on the Headless tab** sized the session form behind it, and left the batch
  form Flexible. It now sizes the tab it shows.
- **The GPU stepper** stood at its row's far end on Advanced and Headless. It now stands under the
  cores' and RAM's. Its help said "for this job" on Advanced too: now "0, or one of the counts the
  platform offers".
- **The row's lines:** Batch Jobs' title and button stood a point lower than the others', beside its
  taller button, and the three footers stood at three heights. The header now has one height, and the
  footer sits at the card's foot.
- **Recent Launches** now says a launch's GPUs ("CPU: 1 · RAM: 4 GB · GPU: 1"), as its session's card
  does.
- **Handout 37 had two sections P.** Plan 42's is now T.

**The person's ask, at the live check:** on a reload, Storage's bar runs back to the start, and fills
to the usage when the answer comes. With Reduce Motion it stays where it is. VoiceOver reads
"Refreshing" meanwhile, not 0%.

**Still for the person:** staging-src (O3–O8 there), the refreshing cards by eye (T2–T5), and the
manual's pictures.
