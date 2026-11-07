#!/bin/zsh
# Native Markdown workflow using throwaway files; no model calls or user data.
set -euo pipefail
cd "${0:a:h}/.."
MD_FIXTURE=$(mktemp -d)
trap 'rm -rf "$MD_FIXTURE"' EXIT
MD_ARTIFACTS="${MARIKA_MARKDOWN_ARTIFACTS:-$PWD/build/markdown-review}"
mkdir -p "$MD_FIXTURE/project/images" "$MD_FIXTURE/data" "$MD_ARTIFACTS"
python3 - "$MD_FIXTURE" "$MD_ARTIFACTS" <<'PY'
import json, pathlib, struct, sys, zlib
root, artifacts = map(pathlib.Path, sys.argv[1:])
project = root / 'project'
(project / 'README.md').write_text('''# Project handbook

Readable documentation, right beside your code. **Edit the source** and see changes in the preview.

## Getting started

- [x] Open your project
- [x] Read this document
- [ ] Ship something useful

> Keep your docs close to the code they explain.

| Tool | Purpose |
| --- | --- |
| Preview | Read formatted Markdown |
| Split | Write and preview together |

![Project overview](images/overview.png)

```swift
let project = "Marika"
print("Hello, \\(project)!")
```

[Getting started](#getting-started) · [Another document](notes.md)
''')
(project / 'notes.txt').write_text('Plain text stays in the source editor.\n')
(project / 'notes.md').write_text('# Another document\n\n[Back to handbook](README.md)\n')
def chunk(name, data):
    return struct.pack('>I',len(data)) + name + data + struct.pack('>I', zlib.crc32(name+data)&0xffffffff)
w,h=600,100
rows=b''.join(b'\x00'+bytes(v for x in range(w) for v in (int(30+40*x/w),int(115+60*x/w),int(210-70*x/w))) for y in range(h))
(project/'images/overview.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
steps = [
    {'op':'open','path':str(project)}, {'op':'size','width':1440,'height':1000},
    {'op':'appearance','dark':True}, {'op':'wait','seconds':0.6},
    {'op':'markdownTest','directory':str(artifacts)}, {'op':'quit'}
]
(root/'steps.json').write_text(json.dumps(steps))
PY
MARIKA_DRIVER="$MD_FIXTURE/steps.json" MARIKA_DATA="$MD_FIXTURE/data" \
    MARIKA_EDITOR_DEFAULTS_SUITE="marika.markdown-test.$RANDOM" \
    .build/debug/Marika > "$MD_ARTIFACTS/native-test.log" 2>&1
rg 'Markdown passed' "$MD_ARTIFACTS/native-test.log"
