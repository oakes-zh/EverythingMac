# EverythingMac v0.2.7 — Debug Index Loader + Bounded Search

This build is focused on the million-item debugging workflow.

## Startup behavior

`swift run EverythingMac` no longer scans or rebuilds the filesystem automatically.
The window opens in **Index Session** mode with three explicit actions:

- **Load Existing Index** — loads `~/Library/Application Support/EverythingMac` by default.
- **Choose Index Folder…** — point the app at another existing EverythingMac index root.
- **Build New Index** — explicitly start a filesystem scan/rebuild.

Loading an existing v0.2.6 index does **not** rescan the filesystem. It does rebuild the in-memory search engine from the persisted records, and that stage has visible progress.

## Search changes

- Filename/folder-name only. File contents are never searched.
- `.glb` is recognized as an extension lookup and uses a dedicated extension index.
- Chinese two-character terms such as `模型` use a 2-gram candidate index.
- 3+ character terms use 3-gram postings.
- Normal query paths are capped at 20,000 candidates instead of walking ~1.1M records.
- Old query tasks are cancelled and stale generations are forbidden from updating the UI.
- The status bar shows route, candidate count, checked count, and whether the candidate set was capped.
- Expensive FSEvents full-engine reconciliation is disabled by default in this debug build; it was able to block searches for minutes on a million-item index.

## Existing index

Default index root:

`~/Library/Application Support/EverythingMac`

A v0.2.6 `records.plist` can be loaded directly; no rebuild is required.

## Run

```bash
swift run EverythingMac
```

Then click **Load Existing Index**. Wait until **Search ready** before testing queries.

Useful checks:

- `.glb` → route should show `extension`
- `模型` → route should show `bigram` (unless it is an exact-name hit)
- `report` → route should show `trigram`

Core tests: 9 tests, 0 failures.
