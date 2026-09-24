# Neobrutalism Design Conventions — Implementation Digest (CLIN-10)

**Primary spec**: https://www.neobrutalism.dev — pages fetched: `/` (Introduction), `/styling`, `/docs/installation`, `/components` (index), and the component pages `/docs/card`, `/docs/button`, `/docs/badge`, `/docs/button-group`, `/docs/alert`, `/docs/input`, `/docs/label`, `/docs/table`, `/docs/menubar`, `/docs/avatar`, `/docs/toast`, `/docs/dialog` (plus `/docs/form` layout example embedded in the Card page).
**Exactness note**: The rendered docs pages don't print class strings, so every class/token below was pulled verbatim from the library's shadcn registry (the JSON the site's own "shadcn CLI" installs: `https://www.neobrutalism.dev/r/<component>.json`) and the theme source (`src/styling/globals.css`, `src/app/styling/styling.tsx`, `src/data/colors.ts`, `src/data/fonts.ts` in the `ekmas/neobrutalism-components` repo — same code the site ships). This *is* the spec the docs render.
**External corroboration**: attempted userguiding.com, 99designs.com, webflow.com, css-tricks.com, hype4.academy, Wikipedia — all unreachable (404/403) from this environment. General trend rules below are flagged `[trend-consensus]`; everything else cites the site/repo. Neobrutalism.dev is primary throughout.

Stack: React + Tailwind v4 + Base UI, shadcn-style registry. `cn()` merge, `cva` variants.

---

## 0. Theme tokens (the vocabulary every rule below uses)

Source: `/styling` (via `globals.css` + `styling.tsx` Customize defaults) and `/docs/installation`.

```css
:root {
  --border-radius: 5px;            /* rounded-base = var(--border-radius) */
  --box-shadow-x: 4px;             /* the signature HARD shadow */
  --box-shadow-y: 4px;
  --reverse-box-shadow-x: -4px;    /* used by "reverse" press-out variant */
  --reverse-box-shadow-y: -4px;
  --heading-font-weight: 700;      /* options 700 / 800 / 900 */
  --base-font-weight: 500;         /* options 500 / 600 / 700 */
  --background: hsl(214, 95%, 93%);          /* tinted page bg (blue default) */
  --secondary-background: oklch(100% 0 0);   /* pure white surfaces */
  --foreground: oklch(0% 0 0);               /* black text */
  --main: hsl(217, 100%, 66%);               /* saturated accent (blue default) */
  --main-foreground: oklch(0% 0 0);          /* text on accent — black, not white */
  --border: oklch(0% 0 0);                   /* ALL borders are pure black */
  --ring: oklch(0% 0 0);                     /* focus rings are black */
  --overlay: oklch(0% 0 0 / 0.8);            /* modal scrim: black 80% */
  --shadow: var(--box-shadow-x) var(--box-shadow-y) 0px 0px var(--border);
  /* chart colors: #5294ff #ff4d50 #facc00 #05e17a #7a83ff */
}
@theme inline {
  --radius-base: var(--border-radius);
  --shadow-shadow: var(--shadow);
  --shadow-nav: 4px 4px 0px 0px var(--border);
  --font-weight-heading: var(--heading-font-weight);  /* class: font-heading */
  --font-weight-base: var(--base-font-weight);        /* class: font-base   */
  --spacing-boxShadowX/Y: 4px;  /* lets hover translate by the shadow offset */
  --spacing-container: 1300px;  /* site max-width container token            */
}
@layer base {
  body  { @apply text-foreground font-base; }  /* + bg-background */
  h1..h6{ @apply font-heading; }
}
```

Core invariants:
- **Borders**: always `border-2 border-border` (2px, pure black). Never 1px, never grey.
- **Shadows**: always `shadow-shadow` = `4px 4px 0px 0px black` — **zero blur**, solid black, equal X/Y offset. Never a soft/blurry shadow. (Customize allows 0/±2/±4 px; 4/4 is the shipped default; radius options 0/5/10/15 px, default 5.)
- **Radius**: `rounded-base` (5px default). Small controls and cards share the same radius. Avatars are the exception (`rounded-full`).
- **Color pairing rule**: accent surfaces use `bg-main text-main-foreground` (black text on saturated color — never white-on-color), neutral surfaces use `bg-background`/`bg-secondary-background text-foreground`. There is no grey in the palette: "neutral" means **white**, not grey.
- **Page background is tinted** with the palette's pastel (`--background`), while cards/inputs sit on `bg-background`/white (`--secondary-background`). `bg-secondary-background` is what inputs and secondary surfaces use.
- 17 monochromatic palettes (red…rose, each `main` + pastel `bg`) and 13 duotone palettes; pick ONE accent (`--main`) for the whole app — severity/status is communicated by fills + icons, not by a palette of reds/greens (see §4).

## 1. Card anatomy

Source: `/docs/card` + `r/card.json`.

- **Container**: `rounded-base flex flex-col shadow-shadow border-2 border-border bg-background text-foreground font-base` — 2px black border, 4px/4px hard black shadow, 5px radius. Vertical rhythm via a single variable: `gap-(--card-spacing) py-(--card-spacing)` with `[--card-spacing:--spacing(6)]` = **24px**; `size="sm"` → `--spacing(4)` = **16px**. The `/styling` spacing demo offers 16/20/24/32px.
- **Structure**: `CardHeader` / `CardContent` / `CardFooter`, each with horizontal padding `px-(--card-spacing)` (so inset == gap == 24px; one rhythm value controls the whole card). Header/footer only add extra top/bottom padding when you give them a border: `[.border-b]:pb-(--card-spacing)` / `[.border-t]:pt-(--card-spacing)` — i.e., to "close" a section, add `border-b-2`/`border-t-2` (2px black) and padding snaps automatically.
- **Header**: grid `gap-1.5`; `CardTitle` = `font-heading leading-none` (bold 700, sentence case — not uppercase); `CardDescription` = `text-sm font-base`. **`CardAction`** = a reserved slot pinned top-right (`col-start-2 row-span-2 self-start justify-self-end`) for the row of actions; use it instead of floating buttons.
- **Footer**: `flex items-center`; form cards stack full-width buttons (`flex-col gap-2`), toolbar cards right-align actions.
- **Image cards**: put the image above the header with `overflow-hidden pt-0` on the Card so it sits flush with the rounded border.
- **When a surface earns a card**: a card is for a *complete unit* — a form panel, a record/summary, a stat block with title+body+action. Borders+shadows are expensive visually; sibling list content belongs in one table/card, not one card per row. Dense secondary surfaces (inputs, badges, menubar text) use `bg-secondary-background` instead of another shadow.

## 2. Typography scale

Sources: `/styling` (font weights + picker), `globals.css` base layer, component registries.

- **Fonts**: default base font **DM Sans** (site default; 20 Google fonts offered: DM Sans, Archivo, **Archivo Black (weight 400 only — display only)**, Bricolage Grotesque, Chivo, Geist, IBM Plex Sans, Inter, Instrument Sans, Lexend, Manrope, Outfit, Poppins, Public Sans, Rubik, Sora, Space Grotesk, Space Mono, Syne, Work Sans). Body uses the *regular* font at **weight 500**; there is no separate display font in the default theme — `font-heading` is the same family at **weight 700**. If you want the classic heavy neobrutalist look, Archivo Black is the "display" pick, but the library itself gets its character from **weight + 2px borders, not from font swaps**.
- **Weights** (the whole typographic system): `font-heading` = 700 (700/800/900 options), `font-base` = 500 (500/600/700 options). Body text is *never* 400.
- **Sizes** (Tailwind default scale, used sparingly): body & controls `text-sm` (14px) — buttons, inputs, alerts, menu items, table text are ALL `text-sm`; descriptions/help `text-sm`; titles `text-lg` (DialogTitle, `leading-none tracking-tight`) or `text-base`; labels & badges `text-sm` / `text-xs`; shortcuts `text-xs tracking-widest`. No custom display sizes are defined — hierarchy = **weight + borders + color**, not size.
- **Casing**: **sentence case everywhere.** No `uppercase`/`tracking-wider` utility appears in ANY component in the library (badges, buttons, table headers, labels are all sentence case). Classic-trend articles often uppercase labels `[trend-consensus]`; the neobrutalism.dev spec does not. Follow the site: sentence case, emphasis via `font-heading`.
- Headings h1–h6 get `font-heading` globally from the base layer.

## 3. Button system

Source: `/docs/button` + `r/button.json` (verbatim `buttonVariants`).

Base (all variants/sizes): `inline-flex items-center justify-center whitespace-nowrap rounded-base text-sm font-base gap-2 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:opacity-50 [&_svg]:size-4` (icons always 16px).

**Variants** (4 — there is no `ghost`/`link`; `neutral` is the secondary):
| Variant | Classes | Role |
|---|---|---|
| `default` (primary) | `text-main-foreground bg-main border-2 border-border shadow-shadow hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none` | accent-filled, black text, 4px shadow |
| `neutral` (secondary) | `bg-secondary-background text-foreground border-2 border-border shadow-shadow hover:translate-… hover:shadow-none` | white body, same border/shadow |
| `noShadow` (flat/tertiary) | `text-main-foreground bg-main border-2 border-border` | no shadow; used inside tight containers (button groups, toasts) |
| `reverse` (press-out) | primary colors; starts flat, `hover:translate-x-reverseBoxShadowX hover:translate-y-reverseBoxShadowY hover:shadow-shadow` | shadow appears on hover (moves −4px,−4px) |

**Press/hover vocabulary (critical)**: there is **no `active:` scale, no color change**. The interaction is *the element collapsing into its own shadow*: `hover:` (and in practice use for `active:` too) `translate-x-boxShadowX translate-y-boxShadowY` (+4px,+4px) **and** `shadow-none` — the button visually drops 4px as if pressed into the black block behind it. Focus = `ring-2 ring-black ring-offset-2` (2px black ring with a 2px white gap). Disabled = `opacity-50 pointer-events-none`.

**Sizes** (heights 32/36/40/44px; text buttons + matching square icon sizes):
| Size | Text button | Icon button |
|---|---|---|
| `xs` | `h-8 px-2.5 text-xs gap-1.5` (svg `size-3.5`) | `size-8` |
| `sm` | `h-9 px-3` | `size-9` |
| `default` (md) | `h-10 px-4 py-2` | `size-10` |
| `lg` | `h-11 px-8` | `size-11` |

Default is `text-sm`; `xs` downgrades to `text-xs`.

**Button groups** — source `/docs/button-group` + `r/button-group.json`:
- Container: `flex w-fit items-stretch rounded-base` (+ `flex-col` for `vertical`).
- **Children are flattened**: `*:shadow-none! *:hover:translate-x-0! *:hover:translate-y-0!` — joined buttons lose their individual shadows and press-translate (they move as one block).
- **Shared border**: subsequent children get `rounded-l-none border-l-0` (horizontal) / `rounded-t-none border-t-0` (vertical); the last child re-gets its outer radius (`rounded-r-base!`). So segments merge into ONE outlined body with a single 2px black outline.
- **Focus ring stays visible**: `*:focus-visible:relative *:focus-visible:z-10` — the focused segment pops above siblings so the black ring isn't clipped.
- `ButtonGroupText` (label segment): `rounded-base border-2 border-border bg-secondary-background px-2.5 text-sm font-heading` — a grey-free "white" prefix chip; when combined, the group's radius-merge applies to it too.
- `ButtonGroupSeparator`: `border-l-2 border-border mx-px self-stretch` (2px black divider with 1px breathing room) for keeping segments visually divided when you don't want them border-merged.
- Input + button combos: `&>input:flex-1`, select-trigger last-of-type keeps right radius — use `ButtonGroup` for any "field + action" toolbar.

**Density for nav/menubar** — source `/docs/menubar` + `r/menubar.json`:
- Bar: `flex h-11 items-center space-x-1 rounded-base border-2 border-border bg-background p-1 font-base` — the bar is its own card: 44px tall, 2px border + radius, 4px inner padding, NO shadow (nav is flat; only cards/buttons carry shadows).
- Triggers: `px-3 py-1.5 text-sm font-heading border-2 border-transparent` — transparent border **reserves 2px so the hover outline never shifts layout**.
- Hover/focus/highlight/open state = **full color inversion**: `bg-main text-main-foreground hover:border-border` (accent fill, black text, border turns from transparent to black). No underlines, no grey hover.
- Dropdown popup: `min-w-[12rem] rounded-base border-2 border-border bg-background p-1` + zoom/fade animations; items `px-2 py-1.5 text-sm` with the same invert-on-highlight + border-transparent trick; separator `-mx-1 my-1 h-0.5 bg-border`; shortcut `text-xs tracking-widest ml-auto`.

## 4. Badge / label / sticker prominence

Source: `/docs/badge` + `r/badge.json`; severity discussion synthesized with toast/alert registries + `/styling` palette data.

- **Badge spec**: `inline-flex items-center justify-center rounded-base border-2 border-border px-2.5 py-0.5 text-xs font-base gap-1 [&>svg]:size-3 overflow-hidden w-fit whitespace-nowrap shrink-0` — a badge is **bordered like every other surface** (2px black) with the shared 5px radius.
- Variants: only `default` (`bg-background text-foreground`) and `neutral` (`bg-secondary-background text-foreground`). **Color is applied via className**: `bg-main text-main-foreground` for accent/emphasis (site pattern everywhere for colored chips, e.g. AvatarBadge is exactly `border-2 border-border bg-main text-main-foreground`).
- **Why a badge must NOT be grey+small when it carries urgency**: the design language has no grey tier — "neutral" is plain white and reads as *informational*. Prominence is carried by **fill + border + icon**, not by size: an urgent badge should be `bg-main text-main-foreground` (or a semantic fill, e.g. the chart-red `#ff4d50`) **at the standard spec — `text-xs` with `border-2 border-border`** — so its black outline and saturated fill make it pop against white cards. Shrinking it below `text-xs` or leaving it unbordered/white destroys the only prominence signal the style allows. Rule of thumb: **filled = needs attention; white = metadata**.
- **Severity → color mapping**: the library ships **no success/warning/danger tokens**; it intentionally uses one accent + black/white. To map severity, keep the *shape* identical (`border-2 border-border rounded-base`, `text-xs font-base`) and swap fills, using the palette chart hues as the sanctioned saturated set: info → `--main` (e.g. blue), success → green `#05e17a`, warning → yellow `#facc00`, error → red `#ff4d50`, always with **black** text (`text-main-foreground`) — never white text on color. The only built-in semantic inversion is Alert's `destructive`: `bg-black text-white`.
- **Sticker/badge placement**: badges pin to corners of avatars (`absolute right-0 bottom-0 rounded-full border-2 border-border bg-main`, sizes 12/16/20px for sm/default/lg) and sit inline in table cells / `CardAction` slots. On a card, status goes in the header's action slot; on a row, first cell or last cell — inline, not floating.

## 5. Forms

Sources: `/docs/input`, `/docs/label`, `/docs/card` (login form example), `r/input.json`, `r/label.json`, `r/dialog.json`.

- **Input**: `flex h-10 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base text-foreground placeholder:text-foreground/50` — 2px black border on **white** body (inputs are deliberately un-shadowed and white so they read as "wells" against the tinted page/card). Selection highlight: `selection:bg-main selection:text-main-foreground`.
- **Focus state** (identical to buttons): `focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2`, outline removed — 2px black ring with white gap. Disabled: `cursor-not-allowed opacity-50`.
- **Label**: `text-sm font-heading leading-none` — labels are **bold** (heading weight), sentence case, sitting tight above the field.
- **Field rhythm** (from the Card page login example): each field = `grid gap-2` (label→input, 8px); stack fields with `flex flex-col gap-6` (24px — the same 24 as card spacing); inline-label rows put the helper link at `ml-auto text-sm underline-offset-4 hover:underline`.
- **Form panel carding**: wrap in `Card` (w-full max-w-sm for auth-scale forms); header = `CardTitle` (font-heading) + `CardDescription`; fields in `CardContent`; **submit in `CardFooter`** — stacked `w-full` buttons (`flex-col gap-2`) for forms, or right-aligned for toolbars. Secondary actions in footer use `variant="neutral"`.
- **Dialog-based forms** (`r/dialog.json`): `DialogContent` = `rounded-base border-2 border-border p-6 gap-4 shadow-shadow bg-background sm:max-w-lg` (a card: border+hard shadow, 24px padding); overlay `bg-overlay` (black 80%); `DialogTitle` `text-lg font-heading leading-none tracking-tight`; `DialogFooter` = `flex flex-col-reverse gap-3 sm:flex-row sm:justify-end` — **primary action bottom-right, cancel to its left**.

## 6. Tables / lists

Source: `/docs/table` + `r/table.json`.

- **The table itself is the card**: `<table>` = `w-full caption-bottom border-2 border-border text-sm` (2px black outline; the scroll wrapper is plain `relative w-full overflow-auto` — no extra Card needed; put the table inside a Card only when you need a title/toolbar, with the table flush via negative margins or the card's border serving as the outline).
- **Every rule is 2px**: `TableHeader` rows `[&_tr]:border-b-2 border-border`; body rows `border-b-2 border-border` (`last:border-0`); footer `border-t-2`. 1px table borders are the single most common neobrutalism mistake.
- **Density**: header cells `h-12 px-4 text-left align-middle font-heading` (48px, bold); body cells `p-4 align-middle font-base` (16px all around). That's the standard rhythm; compress via `p-2/h-9` only for dense admin tables — keep the 2px borders when you do.
- **Row states**: rows are `bg-background`; selected = **full inversion** `data-[state=selected]:bg-main data-[state=selected]:text-main-foreground` (accent fill + black text, same vocabulary as menubar hover).
- **Where actions live**: row actions in the last cell as `size-8`/`size-9` icon buttons (`variant="neutral"` or `noShadow`); bulk/toolbar actions above the table right-aligned; pagination below (`mt-4 text-sm` caption/footer zone). Badges/status inline in their own cell per §4.

## 7. Spacing / layout

Sources: `/styling` (`--spacing-container: 1300px`, card-spacing demo), `globals.css`, `/docs/card`.

- **Page rhythm**: page background = the palette's pastel `--background` (e.g. `hsl(214,95%,93%)`); the site uses `--spacing-container: 1300px` as its max-width container. Content sits directly on the tinted page; white surfaces (`bg-secondary-background`) and `bg-background` cards float on it via border+shadow — that's the depth model: **no soft elevation, only "sticker" layers**.
- **Gaps**: the universal unit is **24px** (`--spacing(6)`): card internal rhythm, form field-group gaps, dialog `gap-4`→ use 16px inside dense panels (card `sm` = 16px), 8px within a field/label pair (`gap-2`), 4–6px inside badges (`px-2.5 py-0.5`).
- **Dense nav + content coexist**: nav is 44px (`h-11`), flat (border only, no shadow), page content below gets the tinted background; shadows appear only on interactive/content blocks so the eye reads nav as chrome, content as object. Menubar triggers reserve border space (`border-2 border-transparent`) to avoid layout shift on hover.
- **Scrollbars** (site signature): 20px body scrollbar, black thumb, white track with a 4px black track border — optional but on-brand.
- **Animations**: entrances are `fade-in zoom-in-95` (`data-open:` states) — snappy 200ms; marquees/orbit exist for landing pages, not app UI.

## 8. Component mapping table (app element → neobrutalism.dev component + spec essentials)

| App element | Component (`/docs/…`) | Spec essentials |
|---|---|---|
| Nav bar | **Menubar** | `h-11` bar, `border-2 rounded-base p-1`, no shadow; triggers `text-sm font-heading` w/ transparent-border placeholder; hover/open = `bg-main text-main-foreground` inversion |
| Joined actions / field+button toolbars | **Button Group** | one merged body: children `shadow-none`, `border-l-0 rounded-l-none` on followers, focus `z-10`; label segment = white `font-heading` chip; 2px black separator with `mx-px` if unmerged |
| Page container | **Card** (+ `--spacing-container:1300px`) | pastel page bg; cards = `border-2 + shadow-shadow + rounded-base`, 24px rhythm via `--card-spacing`; card earns existence only for complete units (form/record/stat) |
| Data table | **Table** | table carries its own `border-2`; ALL row rules `border-b-2`; head `h-12 font-heading`, cells `p-4 text-sm`; selected row = `bg-main` inversion; actions = `size-8/9` icon buttons in last cell |
| Record panel / detail modal | **Dialog** (or Sheet for side panels) | `rounded-base border-2 shadow-shadow p-6 gap-4 sm:max-w-lg`; overlay black/80; title `text-lg font-heading`; footer: primary right, cancel left |
| Form | **Input + Label** in a **Card** | input `h-10 border-2 bg-secondary-background`, focus `ring-2 ring-black offset-2` (no shadow); label `text-sm font-heading`; fields `gap-2`, groups `gap-6`; submit in CardFooter (`w-full` stacked or right) |
| Status badge | **Badge** + accent fill | `text-xs px-2.5 py-0.5 border-2 rounded-base` — urgent = `bg-main text-main-foreground` (or chart-hue fill), metadata = white; never grey, never unbordered |
| Avatar stack | **Avatar / AvatarGroup** | `rounded-full outline-2 outline-border` (2px black outline, not border); sizes 32/40/48; stack `flex -space-x-2` + `AvatarGroupCount` white circle; presence dot `border-2 bg-main` bottom-right |
| Feedback banner (inline) | **Alert** | `rounded-base border-2 shadow-shadow px-4 py-3 text-sm`; title `font-heading tracking-tight`; destructive = `bg-black text-white` (inversion, not red); severity colors = chart hues w/ black text |
| Feedback toast (transient) | **Toast** | bottom-right `max-w-sm`; `rounded-base border-2 bg-background` **no shadow** (stacked w/ scale/peek); title `font-heading`, desc `font-base`, type icons (success/info/warning/error/loading); action = `noShadow sm` button |
| Primary/secondary CTAs | **Button** | primary `bg-main` + 4px shadow; secondary `neutral` white + shadow; press = translate 4px + shadow-none; sizes h-8/9/10/11 |
| Icon-only actions | **Button `size="icon*"`** | square `size-8/9/10/11`, same variant rules |

---

## Quick "don't" list (violations of the spec)

1. No 1px borders, no grey borders/text-borders — everything structural is `border-2 border-border` (pure black).
2. No blurry shadows — `shadow-shadow` is `4px 4px 0px 0px` (blur 0). No `shadow-sm/md/lg`.
3. No white text on accent (`--main-foreground` is black).
4. No uppercase labels/badges — sentence case; hierarchy via `font-heading` (700).
5. No soft hover (color-shift/scale) — press = translate-into-shadow; hover-fill = full inversion (`bg-main`).
6. No unbordered badges on urgent statuses; no shrinking badges below `text-xs` to "de-emphasize" — switch variant to white/neutral instead, or fill for urgency.
7. No soft overlay scrims — `--overlay` is black at 80%.
8. Don't shadow nav/menubar/inputs/toasts — shadows are for buttons, cards, alerts, dialogs, tables-as-objects only.

## Sources

- Site pages: neobrutalism.dev `/` (Introduction), `/styling`, `/docs/installation`, `/components` index, `/docs/{card,button,badge,button-group,alert,input,label,table,menubar,avatar,toast,dialog}`.
- Verbatim component sources (what those pages install): `https://www.neobrutalism.dev/r/{button,card,badge,button-group,alert,input,label,table,menubar,avatar,toast,dialog}.json`.
- Theme/tokens: `github.com/ekmas/neobrutalism-components` → `src/styling/globals.css`, `src/app/styling/styling.tsx`, `src/data/colors.ts`, `src/data/fonts.ts`.
- `[trend-consensus]` markers = general neubrutalism-trend rules (heavy borders, hard offset shadows, saturated palettes, chunky type) that external writeups (userguiding/99designs/webflow/css-tricks/Wikipedia) state but which were unreachable to fetch in this session; all such rules above are independently confirmed by the primary source.
