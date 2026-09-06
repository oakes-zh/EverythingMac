# EverythingMac

A native macOS file-search prototype focused on fast local indexing and fuzzy filename search.

## Current milestone (v0.1 core)

- Recursive home-folder scan
- In-memory index
- Exact, prefix, contains, and subsequence fuzzy matching
- Ranking by match quality + basic recency
- Query filters: `ext:`, `path:`, `kind:`, `size:>`, `size:<`, `modified:today`, `modified:<7d`
- SwiftUI macOS search window
- Double-click to open; context menu to reveal in Finder
- 25 ms query debounce

## Run on macOS

```bash
cd EverythingMac
swift run EverythingMac
```

For a polished app bundle, open `Package.swift` in Xcode and run the `EverythingMac` executable target.

## Examples

```text
report
prd rpt
ext:pdf report
kind:image sunset
path:Downloads invoice
size:>100mb
modified:<7d ext:fig dashboard
```

## Next milestone

1. FSEvents incremental updates
2. SQLite persistence and fast startup
3. Incremental query cache / previous-result narrowing
4. Global hotkey and Quick Look
5. Benchmark harness for 100K / 1M / 3M synthetic records
