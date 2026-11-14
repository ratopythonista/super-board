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

**Why `--no-optimize`.** The default render launches headless Chrome to bake a crossing-free layout per view.
That step does not finish on this machine (the page waits on the Google Fonts stylesheet), so every view in
`map.json` carries a hand-written `layout` instead: the page then skips its search. When you add or remove a node
in a view, add or move its `[col, row]` in the same commit.

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
