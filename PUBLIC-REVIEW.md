<!-- SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools> -->
<!-- SPDX-License-Identifier: MIT -->

# Pre-public review pack — `lukegalea/ash_agent_tools`

**Audit date:** 2026-09-21 · **HEAD audited:** `688fad7` ("feat(eval): bundle the trigger-eval gate runner; de-flake the describe card")
**Scope:** tree sweep, full-history sweep, licensing/attribution, README honesty pass (commands spot-run on the nix Elixir 1.19.5 toolchain), flip-readiness hygiene.
**Fix policy:** all fixes are **uncommitted working-tree edits** on top of `688fad7` for Luke to review — nothing pushed, nothing committed, visibility untouched.

---

## 1. Tree sweep (current HEAD)

73 tracked files scanned for machine-specific/internal references.

### Must-fix (all fixed locally, uncommitted)

| Location | Finding | Fix applied |
|---|---|---|
| `lib/ash_agent_tools/diff.ex:1` | SPDX header leaked a machine-local path: `<https://github.com/lukegalea/ast-forks/ash_agent_tools>` (`ast-forks/` is the local checkout dir, not the repo) | Header normalized to the repo URL used everywhere else |
| `eval/trigger_eval/README.md:1` | `(DX-2 §2.4)` — internal design-doc codename a public reader cannot resolve | Dropped; SPDX header added (was also missing — see §3) |
| `eval/trigger_eval/eval_set.json` | `_meta.name` `dx2-serve-daemon-trigger-eval` and `(DX-2 design §2.4)` in the description | Renamed to `serve-daemon-trigger-eval`; codename dropped |
| `eval/trigger_eval/run_gate.sh:6` | `(DX-2 §2.4)` in header comment | Dropped |
| `lib/ash_agent_tools/mcp/plug.ex:17` | "Protocol behavior follows the DX-2 design and its librarian reconciliation" | Reworded self-contained: "written against the MCP specification and cross-checked against existing MCP server implementations" |

### Nice-to-fix (fixed locally, flagging for review)

| Location | Finding | Fix applied |
|---|---|---|
| `LICENSE` | Placeholder text: `Copyright (c) <year> <copyright holders>` | `Copyright (c) 2026 ash_agent_tools contributors` (matches every SPDX header; change the holder if Luke prefers his own name — his legal call) |
| `mix.exs:105` | Hex package "Usage rules" link pointed at `blob/main/usage-rules.md` but the branch is **`master`** → 404 for package users the moment it goes public | Changed to `blob/HEAD/usage-rules.md` (default-branch-agnostic). Alternative: rename the branch to `main` at flip time and revert this — either works, but the mismatch had to go |

### Fine-as-is

- `https://github.com/lukegalea/ash_agent_tools` URLs (≈60 occurrences) — become live at flip; correct.
- `127.0.0.1:4100`/`4199` loopback defaults — legit daemon defaults, documented as loopback-only.
- "state plane / time plane" wording — OTel terminology, not a reference to the Plane product.
- README's references to **public** upstream artifacts: Tidewave PRs #215/#237/#242, phxagents.dev, Serena, usage_rules — all public, all attributed.
- **Zero** hits for: `/home/lukegalea`, `/nix/store`, `ash_enterprise`, `sdlc.home.arpa`, `ai-sdlc`, `ScribbleVet`, `codicil`, "Lane E", `fix-14`, TODO/FIXME (none exist), any email beyond Luke's own identities, any secret-shaped string.

## 2. HISTORY sweep — verdict: **CLEAN (accept history, no rewrite)**

Full `git log -p --all` exported (17,976 lines, 24 commits, single branch `master`, no tags, no stashes, no other refs) and scanned for the entire pattern battery **plus** historical secrets:

- `/home/lukegalea`, `/nix/store`, `ash_enterprise`, `sdlc.home.arpa`, `ai-sdlc`, `ScribbleVet`, `codicil`, "Lane E", `fix-14` → **0 matches in the entire history.**
- Secrets: no `ghp_*`, `github_pat_*`, `sk-*`, `AKIA*`, `xox*`, no PEM blocks, no connection strings, no bearer tokens. The only high-entropy strings are hex-package checksums in `mix.lock` revisions — public hex.pm content, fine.
- Emails: only Luke's two identities — `lukegalea@users.noreply.github.com` (early commits) and `luke@ideaforge.org` (later commits). Both are Luke's; **only he can decide** whether `luke@ideaforge.org` is acceptable to expose. If not, that *would* force a history rewrite — flagging it explicitly as the one personal decision embedded in the git log.

**Harmless residue (report-only, recommend accepting rather than rewriting):** opaque internal codenames in commit *messages* — "DX-2 §2.4 part B" (`688fad7`), "LAWS-1" (`b1732ab`), "SEM-1" (`60e91e5`), and "capstone dogfood" in the `f90c70e` subject. These are meaningless to outsiders, contain no sensitive content, and appear in mid-history commits — scrubbing them would buy nothing and cost a rewrite. Accept.

## 3. Licensing / attribution

- **MIT LICENSE** present; `mix.exs` `licenses: ["MIT"]`, links correct (after fix). `LICENSES/MIT.txt` holds the canonical SPDX template text — correct REUSE practice, left as-is.
- **phxagents (MIT) attribution** present everywhere the laws content lives: `lib/ash_agent_tools/laws.ex:11-12`, `usage-rules/iron-laws.md:3-4`, `usage-rules.md:324`, `README.md:153`, plus the eval docs' taxonomy labels. ✓
- **REUSE:** was **non-compliant** — `eval/trigger_eval/README.md` and `eval/trigger_eval/eval_set.json` carried no copyright/license info (the main README's "`reuse lint` clean" claim was false). Fixed: SPDX header added to the eval README, both eval files covered via `REUSE.toml` annotations, README claim updated. `reuse lint` now reports **70/70 files, compliant with v3.3** (verified by run).
- **Dependency hygiene (the no-LGPL/no-proprietary question):** confirmed in `mix.exs` — hard deps are `ash ~> 3.0`, `jason`, `telemetry`, `sourceror` (all MIT/Apache-2.0). `plug`, `bandit`, `file_system` are `optional: true` with conditional compilation (Ecto's optional-Jason pattern) — the daemon story keeps the MIT/no-hard-dep claim honest. `simple_sat` is dev/test-only; `observer_cli`/`recon` dev-only + optional; `credo`/`dialyxir` dev-only. No LGPL or proprietary snippets anywhere in the tree.

## 4. README honesty pass — verified against master

Spot-run on `/nix/store/...elixir-1.19.5` (Elixir 1.19.5 / OTP 28):

| README claim | Result |
|---|---|
| `mix ash_agent.laws --code '...'` — violations-only JSON, tiers, counts | ✅ exact shape as documented (law 10 fired at tier `definite`) |
| `mix ash_agent.laws` (no args = registry dump) | ✅ 26 laws, `detectors`/`mechanical?` fields as documented |
| `mix ash_agent.describe` — compile-only boot, app never started | ✅ sub-second, JSON out (empty result is correct: this repo is a library with no host domains) |
| `mix ash_agent.validate ... '{"title": "Hi"}'` | ✅ validation report with `expected` contract, `normalized_inputs` (run under `MIX_ENV=test` against the test support domain) |
| Daemon section: `mix ash_agent.serve` → loopback MCP, `initialize` negotiation, 7 tools | ✅ live smoke test on port 4299: handshake + `tools/list` returned exactly `ash_describe, ash_validate, ash_search, ash_context, ash_forbidden, ash_daemon_status, ash_reload` |
| "`reuse lint` clean" (Contributing section) | ❌ was false (two eval files uncovered) → **fixed**, now true |

One documented-commands caveat worth keeping in the README's favor: `eval/trigger_eval/run_gate.sh` requires `opencode` + `jq` on PATH — stated in the script header and eval README, consistent.

## 5. Repo hygiene — flip checklist

- **Description:** `Read-only Ash introspection for AI agents: describe resources/actions, validate inputs without executing, explain forbidden policies, judge Phoenix iron laws. Ships as plain modules + Mix tasks + an optional MCP daemon.`
- **Topics:** `elixir` `ash-framework` `ash` `phoenix` `ai-agents` `mcp` `llm-tools` `introspection` `developer-tools` `liveview`
- **Issues:** enable. **Discussions:** start disabled (zero maintenance budget until there's a community); enable if/when issues fill with questions.
- **Branch:** current default is `master`. The mix.exs link now uses `blob/HEAD/` so either name works, but renaming to `main` before/at flip matches GitHub convention and the repo's own docs muscle memory — recommended, optional.
- **Minimal settings list:** default branch `main` (if renamed) · require PRs off (solo maintainer) · **secret scanning + push protection ON** (free, and this repo's whole pitch to itself is scar-avoidance) · dependabot off (deps are pins reviewed by hand) · wiki off · squash-merge default if PRs ever happen.
- **Wiki/projects:** off. **Releases:** cut a `v0.1.0` tag + GitHub Release after flip so `mix.exs` `source_url` resolves to something with a tag.

## Verdict

# GO-WITH-FIXES

Nothing damning exists in the tree or the 24-commit history — no secrets, no machine paths, no private hostnames, no third-party email leakage. The fixes are all doc-level and **already applied as uncommitted working-tree edits** (9 files, listed below). Luke reviews, commits, then flips. The only open personal decision: whether `luke@ideaforge.org` in the author field is acceptable public-facing (if not, a history rewrite becomes necessary — everything else is clean).

**Files fixed locally (uncommitted):** `LICENSE`, `README.md`, `REUSE.toml`, `mix.exs`, `lib/ash_agent_tools/diff.ex`, `lib/ash_agent_tools/mcp/plug.ex`, `eval/trigger_eval/README.md`, `eval/trigger_eval/eval_set.json`, `eval/trigger_eval/run_gate.sh`.

**Post-fix verification:** full test suite **42 doctests, 270 tests, 0 failures (2 excluded)** — green; `mix compile --warnings-as-errors` clean; `reuse lint` compliant (70/70).

## Flip command (when happy)

```sh
gh repo edit lukegalea/ash_agent_tools --visibility public
# if gh >= 2.57 prompts about consequences, add:
#   --accept-visibility-change-consequences
```
