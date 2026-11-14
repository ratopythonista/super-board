# flow/ — the development flow as a drill-down map

The page published at `/flow/`: the SDD flow (intake → contract → factory → merge gate → acceptance) as the pack
runs it on the OMP host with a Python project. Same page machinery as [`/skill-map/`](../visual/skill-map.html) —
`render --map` writes one self-contained HTML file.

- `map.json` — the model: nodes, edges and the nine views.
- `index.html` — the rendered page (generated; edit `map.json`, not this file).

## Regenerate

```bash
# 1. skeleton from the installed skills (59 nodes, 25 views)
python3 skills/visual/scripts/visual.py skillmap <project>/.agents/skills --deep --out /tmp/flow-skeleton.json

# 2. enrich: nodes/edges/views of this repo's compose step, merged with the skeleton, written to map.json

# 3. render (no browser bake: every view carries an explicit layout)
python3 skills/visual/scripts/visual.py render --map diagrams/flow/map.json \
  --out diagrams/flow/index.html \
  --source-base https://github.com/ratopythonista/super-board/blob/main/ --source-root . \
  --no-check --no-optimize --no-open
```

**Why `--no-optimize`.** The default render bakes a crossing-free layout per view by running
`chrome --dump-dom '<page>#check=1&optimize=1'` (`page_layouts`). That call never returns on this machine: 40 s,
empty stdout, with and without `--virtual-time-budget`, with and without `--force-prefers-reduced-motion`. The
page-side hook it depends on, `window.__mapAudit()`, also does not finish (60 s+, no result), even on a model
this small (9 views, ≤35 nodes each, no self-edges, every view fully laid out) — so this is the audit path in the
tooling, not the data. A CI bake would hit the same path, so this page does **not** try to bake in `pages.yml`
either. Every view in `map.json` carries a hand-written `layout` instead and the page skips its search; when you
add or move a node, move its `[col, row]` in the same commit.

**Never add a webfont `<link>` to this page.** One sat before every script in the template and, while that
request hung, the map's JS never ran: no `<svg>` after 20 s on the live page, 47 ms once removed. The font
stacks in `--sans`/`--mono` already fall back to system fonts.

**Why `--no-check`.** Same Chrome dependency for the overlap audit. Verify visually with
`npx playwright screenshot` or by opening the page: `#view=root`, `#view=contrato`, `#view=fabrica`,
`#view=omp`, `#view=python`, `#view=merge-gate`, `#view=aceite`, `#view=install`, `#view=ref`.

## Editing rules

- A node needs `what`, `when`, `how` and a real `source`; the details panel shows all four.
- Skills from another pack are `kind: "external"` with `origin` and `author`; sources outside this repo show as
  text, not links.
- `script`, `hook` and `board` are the small nodes: what the lane executes, what fires on its own, what the run
  reads or writes.
- Every captured node must sit in some view; leftovers go to `ref`.
