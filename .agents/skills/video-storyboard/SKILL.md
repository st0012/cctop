---
name: video-storyboard
description: Use when designing, scripting, or storyboarding a short demo, launch, explainer, or marketing video (especially for a developer tool, app, or SaaS), OR when auditing, critiquing, or improving an existing video's narrative, hook, pacing, or storyboard. Runs a verified 6-stage process — positioning, message spine, beat sheet, script, storyboard, review — embedding StoryBrand, Before-After-Bridge / PAS / AIDA, the Pixar Story Spine, and the But/Therefore rule. Invoke whenever the work is about the STORY of a video rather than its rendering, including phrasings like "storyboard this", "what's the hook", "make the video more compelling", "the video falls flat", "script a launch video", or "audit this video". After an approved render, hand off publishing to video-assets so MP4 and AVIF release assets stay in sync. Do not use this skill for the encoding/rendering pipeline itself.
---

# Video Storyboard

A repeatable process for the part of a video that decides whether it works: the **narrative**. Rendering executes the story; this skill designs it.

For cctop launch videos, this is the first half of the workflow:

1. Use this skill for story/script/storyboard/audit decisions.
2. Render through the repo video pipeline (`cd video && ./build.sh launch` for the launch cut).
3. After the user approves the rendered video, switch to `$video-assets` and publish with its confirmation gate. That workflow uploads `cctop-launch.mp4`, `cctop-launch-720p.mp4`, and a freshly generated `cctop-launch-preview.avif` together to the non-latest `media-assets` release.

For cctop product facts, audience, feature-fit judgment, and language choices,
read `PRODUCT.md` before writing positioning or scripts. Use `README.md` for
current public-facing claims and supported-tool lists.

It has two modes:

- **DESIGN** — build a video's story from scratch (product facts → approved storyboard).
- **AUDIT** — run the same lenses over a finished or draft video to find what's weak and how to fix it.

Pick the mode from the request. "Storyboard a video for X" → DESIGN. "Why does this video feel flat / make it better / review this cut" → AUDIT.

Everything here is built from frameworks that survived adversarial fact-checking. The frameworks are solid; many of the *numbers* floating around the industry are blog-grade rules of thumb. Where a guideline is directional rather than proven, it is marked `[directional]`. See `references/frameworks.md` for provenance, citations, and the specifics that were *refuted* (so you don't codify folklore).

---

## The core idea

Most product videos fail the same way: they are a **feature montage from the product's point of view** ("here's the panel, here are the tabs, here are the themes"). They list capabilities instead of telling the story of a person whose problem gets solved.

The fix is one reframe and four moves:

1. **The viewer is the hero; the product is the guide.** (StoryBrand) The story is about *them* and their struggle, not about your UI.
2. **Pick one spine** and fill it — don't free-associate beats.
3. **Connect beats by cause-and-effect** (but/therefore), never by chronology (and then).
4. **Engineer the opening for a muted, scrolling viewer** — the first frame must earn the next two seconds.

---

## Common failure modes (the floor-raisers)

These are the specific ways videos break, distilled from real reviews. They generalize — check for them in DESIGN (avoid) and AUDIT (catch). Pre-empting these is most of what makes a *first* draft good instead of a third.

1. **The hook shows one thing and says another.** The opening line promises tension ("which one needs you?") while the visuals say "all fine" (e.g. every status indicator green). The first ~1.5s of *picture* must depict the problem, not just the text — a muted scroller reads the image, not the words. *Fix: put the problem-state on screen in frame one, with motion (the thing going wrong), before or under the line.*
2. **Action without payoff.** You show the click / keypress / command, but never the **result**. The viewer feels the setup and never the relief. *Fix: every action beat needs an after-beat — show the win (the session opened, the thing unblocked, the status flipping to good).* This is the Story-Spine "until finally" / BAB "After," and it's the single most common missing beat.
3. **Wrong-altitude reveal.** You open on the product's fully-bloomed internal UI and point at an interior detail, instead of how the user *first encounters* it. *Fix: start at the real moment of discovery (the menubar glance, the CLI prompt, the notification) and expand from there.*
4. **The "and then" tail.** The back third decays into a feature montage — capability slide, and then another, and then another — with the hero gone. It's where momentum should peak before the CTA, and it sags. *Fix: tie every late beat to the hero with "therefore (so you can trust it / use it with what you have)," compress, and cut vanity beats (theme galleries, spec lists) to a flash or nothing.*
5. **Product-as-hero in the belly.** The bookends are viewer-centered but the middle becomes a spec sheet — the person disappears. *Fix: keep a problem/person present even in capability beats.*

## What this skill is — and what it can't be

This skill **raises the floor of the first draft and shortens each review loop** — it guarantees the lenses get applied and the known failure modes get pre-empted, every time, even by a cheaper or distracted agent. That is its value, not out-reasoning a strong model on a single careful pass (it won't; a good model already knows this craft).

It deliberately does **not** encode per-video creative specifics — the exact pacing of a transition, which element pulses, what a mock screen shows. Those are taste, discovered by rendering a concrete draft and reacting to it; hard-coding them would overfit the skill and make it brittle. Capture *patterns* here; leave the *particulars* to iteration on the actual cut.

---

## DESIGN mode — the 6-stage pipeline

Each stage takes one artifact and produces the next. Don't skip ahead; a weak positioning statement poisons every downstream stage. Keep each artifact short — a video is 20–40 seconds, not a feature doc.

### Stage 1 — Position  ·  *in:* product facts + audience  ·  *out:* one-paragraph positioning
Write the story's frame **before** any script, using StoryBrand: the **viewer is the hero**, the **product is the guide** that helps them win. Name three things:
- **Who** the hero is (be specific: "a dev running several AI coding agents at once", not "developers").
- **What they want** and **what's in the way** (the external problem *and* the internal feeling — frustration, loss of control, wasted time).
- **The transformation**: the before-state → the after-state the product enables.

If you catch yourself describing the product's features here, stop — you've made the product the hero. Rewrite from the viewer's chair.

### Stage 2 — Message spine  ·  *in:* positioning  ·  *out:* a chosen structure, each step filled
Choose ONE spine and write a sentence for each step:
- **Before-After-Bridge (default for 20–40s)** — *Before* (the painful current state) → *After* (the desirable future) → *Bridge* (the product as the thing that gets you there). Best for "storytelling in tight spaces."
- **PAS** — *Problem → Agitate* (make the cost of inaction felt) *→ Solution.* Use when the pain is sharp and relatable.
- **AIDA** — *Attention → Interest → Desire → Action.* Use when a hard CTA/conversion is the goal. (AIDA is a conversion spine, not a story arc — don't force it into acts.)

### Stage 3 — Beat sheet  ·  *in:* spine  ·  *out:* 4–7 ordered beats
Generate beats with the **Pixar Story Spine** as a prompt ("…every day… until one day… because of that… until finally…"), then run the **But/Therefore test** on every seam: each beat must follow from the last with a **"but"** (tension) or **"therefore"** (consequence). If the only word that fits between two beats is **"and then"**, you have a list, not a story — cut or reorder until causation holds. This single test is the fastest way to find a flat middle.

### Stage 4 — Script  ·  *in:* beat sheet  ·  *out:* on-screen-text / VO script with timecodes
Write the words and the timing. Hard requirements, because the median viewer is scrolling with the **sound off**:
- **The first frame must work muted** and lead with **motion, not setup**. No cold logo, no slow fade-up on an empty stage. Open *in* the hero's problem.
- **Answer "what is this / why do I care" by ~second 3–5.** `[directional]` Slow build is the #1 retention killer.
- **End on a clear payoff and one CTA** (where to go / what to do).
- Track the opening with **hook rate = 3-sec views ÷ impressions** once it ships. `[directional]`

### Stage 5 — Storyboard / shot list  ·  *in:* script  ·  *out:* per-beat frames
Turn each beat into a frame: what's on screen, the motion, the on-screen copy, and the duration. Two rules:
- **Tight body cuts (~2s), no dwelling.** `[directional]` Momentum sustains retention; static holds bleed it.
- **Pick the shortest length that carries the message.** Retention scales inversely with length, so a tight 22s beats a baggy 35s. `[directional]`
- **Introduce the product the way the hero first encounters it.** If they'd meet it as a menubar glance, a CLI prompt, or a notification — *start there* and expand, rather than opening on its fully-bloomed internal UI. The reveal should mirror the real moment of discovery.

### Stage 6 — Review  ·  *in:* storyboard / animatic  ·  *out:* approved board
Before building, check the board against the **Audit checklist** below. Anything that fails goes back a stage. Treat the checklist as the definition of done.

---

## AUDIT mode — score an existing video

Given a finished or draft video (a description, a storyboard, or the actual frames — Read them if available), walk the checklist and produce: a **per-lens verdict (✅ / ⚠️ / ❌ with one line of why)** and a **prioritized fix list** (highest narrative impact first). Be specific and reference the moment/timecode.

Two review disciplines (both learned from this skill underperforming a sharp human reviewer):
- **Don't soften.** A missing payoff (lens 7), a hook whose visuals contradict its words (lens 4), and a wrong-altitude reveal (lens 6) **break the beat — rate them ❌, not ⚠️.** A "warn" on a broken beat reads as "it's fine," and it won't get fixed.
- **Name the single highest-impact fix.** After the per-lens pass, don't end on a flat list of 2–3 "top" changes — pick **the one** change that most improves the video and say so. Ranking is the value; a tie is a dodge.

Run every lens — they catch different failure modes:

1. **Hero & guide (positioning).** Is the *viewer* the hero and the product the guide? Or is it a product-centric feature tour? ❌ if it mostly shows the UI doing things with no person/problem at the center.
2. **Spine.** Is there a discernible Before→After→Bridge (or PAS/AIDA) arc, or is it a montage of capabilities? Name the spine you can detect; if you can't, that's the finding.
3. **Causation (but/therefore).** Do the beats connect by cause-and-effect, or is it "feature, and then feature, and then feature"? Find the seams that are only "and then."
4. **Hook.** Does the **first frame work muted** and grab in ~2s? Is it a *felt problem* or a title card / logo / slow fade? **Do the first ~1.5s of *visuals* match the words** — if the line poses a problem, the picture must show it (don't let the text say "trouble" while the image says "all fine")? On social the first 2s decide everything.
5. **Value clarity.** Is "what is this and why care" obvious by ~sec 5? `[directional]`
6. **Discovery-true reveal.** Is the product introduced the way the hero would actually first encounter it, then expanded — or does it open on the fully-formed internal UI and point at interior details before establishing the whole? A reveal that starts at the wrong altitude is a common, easy-to-miss miss.
7. **Payoff.** Is there a clear *after* state — the moment of relief/win? A video that shows the action (the click, the keypress) but never shows the **result** has no payoff; the viewer feels the setup but not the resolution. (This is the Story-Spine "until finally" and the BAB "After.")
8. **Pacing & length.** ~2s cuts, no slow build, shortest viable length? `[directional]`
9. **CTA.** Is there a clear next step at the end?

For each ❌/⚠️, give the concrete narrative fix (what to add/cut/reorder), not a production note. End by naming **the single highest-impact change** (then any runners-up), per the discipline above.

---

## Honest caveats (read before quoting numbers)

- **Frameworks: solid. Numbers: directional.** StoryBrand (hero/guide), BAB, PAS, AIDA, the Pixar Story Spine, and the But/Therefore rule are well-established and primary-sourced. Every retention/timing figure (the "muted majority", "value by sec 3–5", "~2s cuts", length↔retention curve) is a vendor-blog rule of thumb — use as direction, re-check per platform, never present as proven.
- **Do not codify the folklore.** Verification *refuted* the exact SB7 7-step list, the exact Story-Spine prompt wording, AIDA-as-a-four-act-story, fixed "hook formula types", and specific impression multipliers. Use the framework *principles* at the altitude above; don't invent precise step lists.
- **Two known gaps:** there is no verified public playbook for how named companies (Linear, Vercel, Stripe, Apple…) structure videos, and no verified LLM storyboard-prompt framework. Don't assert specifics there.

Full provenance, citations, and the refuted list: `references/frameworks.md`.
