# Design import benchmark

Five small source examples describe a welcome card. `index.html` is the browser-rendered visual reference. SwiftUI and Compose examples require their native runtime to verify platform-specific font/layout differences; sharing text and styles does not establish pixel equivalence.

Run `python3 scripts/benchmark-design-import.py --agent claude --source index.html` for an opt-in live import through your installed, signed-in CLI. `--source` also accepts Screen.swift, Screen.kt, App.tsx and Screen.vue. The script stores the native import review screenshot, editable document and text/geometry measurements in its printed output directory. Compare the source reference and result before judging fidelity. Unit and native fixture tests do not call a paid provider.
