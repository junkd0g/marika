# Design Import benchmark

Run `python3 scripts/benchmark-design-import.py --source all --references-only` after building
Marika in debug mode. The script captures HTML, React and Vue in Marika’s WebKit browser and
renders the other two fixtures using SwiftUI and Compose Desktop. React and Vue require Node/npm,
and Compose Desktop requires a compatible JDK and Gradle (set `MARIKA_BENCHMARK_GRADLE` to use
a specific Gradle binary).

Omit `--references-only` to run an installed, signed-in agent. Use `--source` with a fixture’s
filename to run it individually. Each import writes the captured reference, native canvas render,
pixel differences, the editable proposal and JSON measurements into the printed output folder.
The benchmark checks known fixture labels and source lines. Each comparison covers one viewport.
