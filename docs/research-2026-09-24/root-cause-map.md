# CLIN-10 UI Epic — Adversarial Design Review & Root-Cause Map

Reviewer: Oracle (outside reviewer). READ-ONLY pass; no files modified in either repo.

## 0. Method and honesty note

The 13 screenshots at `/tmp/opencode/ui-critique/` could not be inspected directly —
this session's model cannot ingest images. Every visual claim below is therefore
**verified mechanically in the code that produces the pixels** (shadow-DOM component
CSS, token bridges, encoder emissions, host layout markup), which is stronger
evidence for root-cause attribution anyway: if the CSS says the badge is
`light-dark(#666,#aaa)` at `--a2ui-font-size-xs` (~11.1px), the screenshot
argument is over. Where a claim rests on the seed-list symptom rather than code,
it is marked `[symptom-reported]`. The parallel lane's
`/tmp/opencode/research/neobrutalism-conventions.md` **does not exist yet**
(checked twice); cross-referencing is against neobrutalism.dev conventions as
encoded in the repo's own source of truth — `assets/css/neobrutalism.css`
("every surface is white-or-blue with a 2px black border and a hard 4px offset
black shadow", DM Sans 500/700, 5px radius, press/lift hover, saturated sticker
badges carrying black ink) and `core_components.ex`.

## 1. The architecture you are actually reviewing (read this first)

Styling decisions live in **five layers**, and most of the complaints are
misattributed to the wrong one:

```
(1) @a2ui/lit basic catalog   — Google's upstream Lit components (Card, Text,
    Button, TextField…) in shadow DOM, themed ONLY by --a2ui-* custom props.
(2) ash_a2ui merged catalog   — ash_a2ui_catalog.js overrides ChoicePicker +
    Column (combobox). Does NOT touch Button/Text/Card.
(3) ash_a2ui admin catalog    — ash_admin_catalog.js: 10 semantic components
    (entityPage, dataGrid, recordPanel, formSection, actionBar, statusBanner…)
    with a --ash-admin-* → --a2ui-* token ladder. SLATE/INDIGO design language,
    hardcodes 1px borders, soft shadows, grey inputs. **DARK in clinic-demo.**
(4) clinic-demo host          — neobrutalism.css tokens + --a2ui-* bridge +
    core_components.ex (badge/button/card — genuinely neobrutalist) + root layout.
(5) ash_a2ui Elixir encoder   — v0_9_1.ex decides the component tree the wire
    carries. `badge <field>` → `Text variant: "caption"`. Form panel → bare
    Column (no Card). Surface title → not emitted at all in basic mode.
```

**The load-bearing fact:** `config/config.exs:45-58` — clinic-demo runs
`catalog: :basic`. Admin_v1 was verified working then disabled because it drops
the Board's sectioned table from the wire entirely (upstream
`admin_core_table?` fallback bug). So **every surface screenshot is the BASIC
composition**, and the entire admin catalog — including its recordPanel card
anatomy, its statusBanner, its quiet row-action buttons — is dead code in this
app today. Any review that doesn't start there will prescribe fixes in a layer
that isn't rendering.

## 2. Root-cause map

Layers: **(a)** a2ui component default (ash_a2ui JS catalog or Elixir encoder),
**(b)** `--a2ui-*` token mapping (host bridge), **(c)** host chrome HTML/CSS,
**(d)** surface declaration (`.ex`), **(e)** information design.

| # | Surface | Finding (quantified from code) | neobrutalism.dev violation | ROOT CAUSE layer | Fix shape |
|---|---------|-------------------------------|-----------------------------|------------------|-----------|
| 1 | schedule, board, intake, worklist, visits, events, evaluations | "Urgent"/"Emergency" badge renders as `Text variant:"caption"` → `.a2ui-text.caption` = `--a2ui-font-size-xs` ≈ **11.1px italic `light-dark(#666,#aaa)` grey** (Text.js:126-130). Bridge never sets `--a2ui-text-caption-color`. The single most scan-critical signal in the row is its smallest, greyest, slouched (italic `<em>`) text. | Badges are filled sticker chips: saturated bg, 2px black border, black ink, bold small caps (repo's own `<.badge>`). | **(a) encoder + (b) bridge** — the DSL *names* it a badge; the encoder emits a caption Text; no badge anatomy exists anywhere in the basic path. | Add a `badge` variant/anatomy in the merged catalog (`ash_a2ui_catalog.js` Button/Text override or new Badge element): `--a2ui-badge-*` fill/border tokens, 2px border, radius, bold. Encoder emits it for `row_layout.badge` and `panel_view` labels. Map `badge_text` keys to palette tones (emergency→red, urgent→orange, soon→yellow, routine→neutral) — the clinic vocabulary already exists in `core_components.badge_fill/1`. |
| 2 | schedule, board (rows with actions) | Row-action Buttons are the biggest objects in the row: basic `Button` declares **no font-size** → inherits page 16px (a full step larger than the app's own `text-sm` 14px buttons), plus `--a2ui-button-padding: 0.5rem 1rem` + 2px border + 4px hard shadow + **yellow fill** (`--a2ui-color-secondary`). A scheduled row shows up to **4** of these (Check in, Complete-eligible set, Mark no-show, Cancel) beside an 11px badge. Inverted hierarchy: actions scream, signal whispers. | Buttons are chunky but *scaled*: one primary/accent per context, secondaries quiet/sm. A wall of identical loud buttons violates the hierarchy the style depends on. | **(a) component + (e) info design** — Button has no size/scale token system (only padding), and the encoder renders every row action as a `default` variant with equal weight. | Merged-catalog Button override: add `--a2ui-button-font-size` (set 0.875rem), an `am`-style quiet/sm variant, and emit row actions as sm/quiet with one designated primary per row (Complete on checked-in, Check in on scheduled). Host bridge sets the font-size token. |
| 3 | intake (create panel), patients, clinicians (edit panels), prompt forms | Create/edit form is **uncarded**: basic composition `form_slot` (List gate) → `form` **Column** → h3 title + TextFields + submit + cancel, floating directly on the pale-blue page. No Card wrapper exists in the basic form path (`form_components/2`, v0_9_1.ex:1727-1764). Note: form **groups** and **query controls** DO get Card wrappers — the anatomy exists in the encoder, it just stops at the form's edge. | Every working surface is a card: white fill, 2px border, hard shadow. A form is the heaviest task surface on the page and has none. | **(a) encoder** — emission shape, not styling. (Intake also carries `nested_form :patient`, which permanently opts it out of the admin recordPanel upgrade even if admin_v1 is re-enabled — v0_9_1.ex:492-499 — so the basic path must be fixed regardless.) | Wrap the `form_slot`'s panel content in a Card (`form_panel` Card → Column body, heading as card header), mirroring the existing `group_section/2` Card shape 30 lines up in the same file. Cheap, byte-compatible with the data model. |
| 4 | ALL surfaces | **No surface title, no h1.** The basic root Column emits no heading at all; the only heading is per-table `table_heading` = **humanized resource name** (v0_9_1.ex:871-896) — the Schedule page's big heading reads "**Appointment**", Intake's reads "Appointment", Board's lanes read lane labels only. `title "Schedule"` is declared in every `.ex` and silently dropped in basic mode (only `admin entityPage` consumes it, v0_9_1.ex:437). | Page headers are display-tier statements (Archivo Black tier exists in the host and is unused by surfaces); also an a11y/IA defect — no h1, first heading mislabels the page. | **(a) encoder** | Emit a `Text variant:"h1"` surface title as the first root child in `basic_components/7` (the admin entityPage already models it). Bridge already maps `--a2ui-font-family-title`. |
| 5 | board (lanes), all sectioned tables | Lane/section headings are bare h2 Texts floating on the page background between card lists — no chip, no accent strip, no card. The operator hub does this correctly with `section_chip` (rotated color square + `font-heading`); surfaces have zero of it. | Section identity via color chips/stripes is core to the style's scannability. | **(a) encoder** (emission) + **(d)** could partially mitigate via lane labels | Section heading anatomy in the encoder (heading Row with a tone token), or accept host-side: not reachable — shadow DOM. |
| 6 | ALL surfaces | Status/feedback is a **naked bound Text** (`status_text`) floating under the title — no banner anatomy, no tone. The admin statusBanner (anatomy + a11y roles) is dark. | Alerts are bordered/filled banners (repo's own flash component: black card + icon chip). | **(a) encoder** (basic path) | Emit the feedback as a bordered banner composition (Card + tone-mapped Text), or port statusBanner's classes into a merged-catalog element. |
| 7 | ALL surfaces with primary buttons (Create, form Submit) | `.a2ui-button.primary { border: none; }` is **hardcoded in the basic catalog** (Button.js:100-105) — no token reaches it. Primary submit renders as a soft-edged blue blob with a hard shadow but **no 2px black border**, visibly breaking the idiom next to correctly-bordered default buttons. | Border-less primary is anti-idiom; the style's uniformity is "border, shadow, ink all the same black." | **(a) upstream component, un-overridden by merged catalog** | The merged catalog exists precisely because "no amount of CSS-variable theming can fix structural" issues (its own header). Add a Button override that restores the border from tokens (as it already did for ChoicePicker/Column). |
| 8 | ALL surfaces | Hover has **no designed state**: `.a2ui-button:hover` → `--a2ui-color-secondary-hover`, which nobody sets → upstream `color-mix` of the bridge yellow → **mud**; and the press/lift motion idiom is impossible via tokens (no `:hover` seam crosses shadow DOM — neobrutalism.css:231-234 says so itself). Result: every yellow button in every row darkens to a computed brown-ish on hover. | Hover = lift (shadow grows) or press (translate into shadow). Never a fill shift to mud. | **(a) merged catalog gap** — shadow-DOM components CAN implement their own `:hover` transitions internally; nothing does. | Button override implements lift/press (`4px→6px` shadow on hover, translate on active) inside shadow DOM, honoring `prefers-reduced-motion`. |
| 9 | ALL surfaces | `--a2ui-color-secondary: var(--yellow)` (bridge) is one token doing **five jobs**: default button fill, combobox-option hover, chip rest state, skeleton bars, admin hover tint (if re-enabled). Yellow is sprayed across every interactive rest/hover state inside surfaces while the app reserves it for "the one loud CTA" (core_components comment). Token-level conflation. | Yellow is the accent, not the wallpaper ("a deliberate accent, never the default" — neobrutalism.css:126-127). | **(b) token mapping** | Split: keep secondary for chips/hover tints (map to `--neutral` or main-subtle), introduce `--a2ui-button-background` for default button fill (white), keep yellow for the designated accent tier only. |
| 10 | ALL surfaces | Type scale inside surfaces is **untied to the host**: `--a2ui-font-size` left at upstream 1rem; body/meta/button/title all inherit page sizes through the boundary; labels forced 700 (bridge) but values/captions upstream-weight. The host's careful DM Sans 500/700 + display tier doesn't reach the surface hierarchy. | The style's hierarchy is blunt and deliberate (chunky everything, but *tiered*). | **(b) token mapping** (partially — tokens for size exist upstream) | Bridge sets `--a2ui-font-size` (e.g. 0.9375rem) and the per-component size tokens after Move #2 gives buttons a size token. |
| 11 | menubar (all pages) | One flat `flex-wrap` row: brand (`text-lg font-display`) + **13 identical h-9 pills** (12 surfaces + Operator, `px-4` + presence chips, `whitespace-nowrap`) + `ms-auto` yellow Acting-as pill (also `whitespace-nowrap`). Two nested wrap containers (outer bar wraps brand/nav/acting-as; inner nav wraps pills) → guaranteed ragged 2-3-line bar at ~1440px; Acting-as wraps whole to line 2 whenever the label is long ("Acting as Amara Okafor" ≈ 230px). No grouping: clinic routes, operator/system routes (processes/decisions/evaluations/events/canvas/agent), and the actor control are visually identical peers. `[wrap symptom-reported; structure confirmed in code]` | Navs are grouped (primary vs utility), dense, and single-line; the accent is scarce. | **(c) host chrome** (+ **(e)** grouping decision) | See §4 for the exact fix. |
| 12 | emergency board | The urgent-care page — the one place the palette should be loudest — is the **flattest layout in the app**: no `row_layout`, no badge, flat Card>Row of caption/value cells (emergency_board_ui.ex:42-46). Triage urgency (always `:emergency` by preset) is a plain cell value. | Emergency = red sticker energy; the page renders like a spreadsheet. | **(d) surface declaration + (e)** | Declare `row_layout` with `badge :triage_urgency` (+ tone mapping from Move #1); consider a red accent strip on rows. |
| 13 | visits, events, evaluations | Badge fields chosen without tone vocabularies: `badge :status` (visits/worklist), `badge :action_type` (events — 20+ audit values, no `badge_text`), `badge :definition_version` (evaluations — a version string, not a status). Even with Move #1's anatomy, these need tone/text maps or every badge renders the same default fill. | Badge color carries meaning (status vocabulary); meaningless color is noise. | **(d) surface declarations** | Add `badge_text` + tone mappings per surface; for events, badge only the high-signal subset (e.g. `:create/:destroy` tones) or drop the badge and keep it a meta column. |
| 14 | worklist | Single row action ("Complete") is a full-size yellow default button — same mass as the schedule's 4-button cluster, for a 1-action row. With `prompt_fields`, the *task* is the form, the button is just the door. | One quiet sm action + the row's real weight on due-at/title. | **(e)** (+ fixed by Move #2) | Falls out of the button scale system; optionally make worklist rows whole-card-clickable with the button as affordance. |
| 15 | storybook (dev tool) | `/storybook` **is routed** (router.ex:110-125, dev-only, `Clarity`-relaxed CSP pipeline) and `storybook.css` correctly mirrors app.css (same imports). But its six stories — badge, button, card, empty_state, input, palette — cover **host HEEx components only**. The layer where every complaint lives (a2ui basic-catalog compositions: badge-as-caption, row cards, uncarded form panel, button scale) has **no storybook and cannot have one** — phoenix_storybook renders HEEx function components, not shadow-DOM A2UI surfaces. The design lane's verification instrument is blind to the failure surface. The storybook's badge story passes while the surface badge is grey — both statements true simultaneously. | n/a (process) | **process gap** | Add a dev "surface gallery" route: one LiveView hosting every declared surface side-by-side with the host components (or screenshot-diff CI over the 13 routes). The NB layer and merged-catalog overrides also have zero visual tests. |
| 16 | admin catalog (dormant, but a trap) | If admin_v1 is re-enabled after the Board fix without bridge work, surfaces flip to a **restrained slate/indigo system**: the admin catalog reads `--ash-admin-*` first and the bridge maps **none** of them; its literals are soft 3-layer shadows (`--am-shadow-1/2/3`), 0.375-0.75rem radii, `#cbd5e1` border-strong, **hardcoded 1px border widths**, slate muted text, focus glow, quiet transparent buttons. Colors would partially flow via `--a2ui-*` fallbacks; structure would not. Two design languages, one app. | Everything (no hard shadows, no 2px borders, no black ink uniformity). | **(a) admin catalog defaults + (b) missing `--ash-admin-*` bridge half** | When re-enabling: bridge `--ash-admin-shadow-*` → hard offsets, `--ash-admin-radius-*` → 5px, `--ash-admin-border` → black — and accept that 1px border widths and quiet-button structure need an ash_a2ui change, not tokens. |
| 17 | pagination (all queried surfaces) | Previous/Next are full-size yellow default Buttons + a bare range Text — same mass as row actions, for the least important controls on the page. | Pagination is utility chrome: sm, quiet. | **(a) encoder + Move #2** | Row of sm quiet buttons + page text; falls out of the scale system. |

## 3. The systemic moves (fix ~80% of findings)

1. **Badge anatomy in the merged catalog + encoder** (fixes #1, feeds #12, #13).
   `ash_a2ui_catalog.js` gains a Badge element (or a `badge` Text variant) with
   `--a2ui-badge-{background,color,border}` tokens, 2px border, 5px radius, bold
   small text; `v0_9_1.ex` emits it for `row_layout.badge`; `badge_text` keys map
   to tone tokens. This is the same play the merged catalog already ran for
   ChoicePicker/Column: structural wrongness that tokens cannot reach.

2. **Button scale + variant system in the merged catalog** (fixes #2, #7, #8, #14, #17).
   Override the basic Button: honor `--a2ui-button-font-size`, add `sm`/`quiet`
   variants, restore the 2px border on `primary`, implement lift/press hover
   inside shadow DOM with a reduced-motion guard. Encoder emits row actions and
   pagination as sm/quiet, one primary per context. Kills the "MASSIVE Complete"
   class of complaint by system, not by patch.

3. **Card the form + emit the surface title** (fixes #3, #4; prerequisite regardless
   of admin_v1's fate because `nested_form` permanently pins intake to basic).
   Two small encoder changes reusing anatomy that already exists in the same file
   (group Cards, admin entityPage title).

4. **Token bridge discipline** (fixes #9, #10; de-risks #16).
   Stop overloading `--a2ui-color-secondary` with yellow; tie the surface type
   scale to the host's; pre-map the `--ash-admin-*` half of the bridge against
   the day admin_v1 returns.

5. **Menubar restructure + surface gallery** (fixes #11, #15; see §4 and finding 15).
   Grouping/density fix in host chrome, plus a dev route that actually renders
   the surfaces next to the design system so the next drift is seen in seconds,
   not in a 13-screenshot audit.

## 4. The menubar: exact fix

Current (root.html.heex:58-106 + nav_presence_live.ex:84-95,149-151):
outer `flex flex-wrap gap-x-2 gap-y-1` bar → brand → inner `flex flex-wrap gap-1.5`
nav (13 pills, `h-9 px-4 text-sm whitespace-nowrap` + presence chips) → `ms-auto`
yellow Acting-as pill (`h-9 px-4 whitespace-nowrap`).

Fix, concretely:

1. **Two clusters, one line.** Bar becomes `flex items-center gap-3` (**no wrap**):
   `brand` (compress to icon + wordmark, `text-base`) → `nav`
   (`flex min-w-0 flex-1 items-center gap-1 overflow-x-auto`) → right cluster
   (`flex flex-none items-center gap-2`: Operator pill + Acting-as pill).
2. **Density tier for nav pills.** New `pill-sm`: `h-8 px-3 text-xs`, keep the full
   border/shadow/lift-tilt-press idiom. Thirteen h-9 text-sm pills are a poster,
   not a nav; h-8/xs fits the clinic set on one line at ≥1280px and scrolls (not
   wraps) below that.
3. **Group by audience, not by route count.** Keep presence-bearing pills for the
   six *clinic* surfaces (board, day, intake, schedule, worklist, visits). Collapse
   the six operator/system routes (processes, decisions, evaluations, events,
   canvas, agent) into the existing **Operator hub pill** — they are already cards
   on `/operator`; per-route presence chips aggregate onto that one pill. Nav drops
   from 13 pills to 8 with zero lost navigation.
4. **Acting-as wrap fix.** Add `max-w-56 truncate` to the pill (label span only —
   the `aria-label` already carries the full name, root.html.heex:95-97), so a
   long actor name ellipsizes instead of wrapping the bar. It stays the single
   yellow pill — correct instinct, keep it.

## 5. Which neobrutalism.dev component should each surface element use?

The honest answer, element by element (neobrutalism.dev component → here):

| Element | Should be | Today |
|---|---|---|
| Row badge (triage/status) | **Badge** — filled sticker chip, 2px border, tone per status | 11px grey italic caption Text |
| Row action cluster | **ButtonGroup** — sm buttons, one primary, rest quiet | 2-4 full-size yellow default Buttons |
| Complete / Check in | **Button (primary/accent)** — one per row max | same mass as everything else |
| Pagination | **Button sm pair** + range text | full-size yellow Buttons |
| Create affordance | **Button accent** (yellow) — the one loud CTA | primary blue, borderless (hardcoded) |
| Form panel | **Card** with header strip (or Modal for prompts) | bare Column floating on page bg |
| Query bar | Input + Select + Button in a **Card toolbar** | ✅ already Card-wrapped — correct |
| Record row | **Card** | ✅ correct (2px/hard shadow/5px via bridge) |
| Lane/section header | Section heading w/ **color chip** (operator hub's idiom) | bare h2 Text |
| Status/feedback | **Alert/Banner** (tone-filled, iconed — host flash is the model) | naked bound Text |
| Empty state | Dashed panel + glyph (host `empty_state` is the model) | plain Text |
| Acting-as | Accent pill (yellow), right cluster | right idea, wraps |
| Nav | Grouped pills, sm density | 13 identical peers, ragged wrap |

## 6. What is genuinely working well — do not torch

- **The token sheet and bridge concept** (`neobrutalism.css`): single source of
  truth shared with storybook.css, correct import ordering after the neutral
  theme, honest comments about what tokens can't do. The *machinery* is right;
  the coverage is incomplete.
- **Record-row cards and query-control cards**: 2px black border, hard 4px shadow,
  5px radius, white fill — the bridge does its job wherever the basic catalog is
  token-driven (Card.js is fully tokenized). The claim "surfaces generally not
  carded" is wrong in general and right in the specific uncarded set (form,
  sections, status, title — findings #3-#6).
- **The NB layer** (`nb_components.js`) and the day view: a real neobrutalist
  component system (three-layer tokens, hard-shadow trio, motion with
  reduced-motion guards) — the day screenshot should be the *reference* the
  a2ui surfaces are pulled toward.
- **Host chrome**: `core_components.ex` badge/button/card/empty_state/table are
  faithful and well-documented; the operator hub's card grid + section chips is
  the best-composed page in the app. Nav pill micro-motion (lift + 1° tilt +
  press) is the idiom done right.
- **Engineering discipline in ash_a2ui**: the a11y hardening, zero-jank action
  acknowledgement, focus management in recordPanel/ConfirmDialog, and the
  config.exs comment documenting *why* admin_v1 is off (with evidence) are all
  above standard. The merged-catalog's "progressive enhancement, announce
  degradation" pattern is exactly how the badge/button overrides should land.
- **Menubar intent**: presence chips on nav pills (who else is here) is a lovely
  idea and correctly built; the yellow Acting-as-as-single-accent is right.

## 7. Fix order (cheapest systemic leverage first)

1. Encoder: form Card + surface title (#3, #4) — one file, no wire break.
2. Merged catalog: Badge + Button scale/variants (#1, #2, #7, #8) — the big one.
3. Bridge: de-conflate secondary-yellow, type scale (#9, #10).
4. Host: menubar restructure (§4) (#11).
5. Declarations: emergency board row_layout, badge tone maps (#12, #13).
6. Process: surface gallery / screenshot CI (#15); pre-map `--ash-admin-*` (#16)
   before anyone re-enables admin_v1.
