#!/usr/bin/env python3
"""Exercise native layout and hidden-composer safety without sending model requests.

Build the debug app first with `swift build`, then run `python3 scripts/ui-smoke.py`.
Screenshots and the driver log stay in the printed temporary directory.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug/Marika"
if not binary.exists():
    raise SystemExit("Build the debug app with swift build first.")

root = Path(tempfile.mkdtemp(prefix="marika-ui-smoke-"))
project = root / "project"
data = root / "data"
(project / "Sources/Views").mkdir(parents=True)
data.mkdir()
code_path = "Sources/Views/LongComponentNameForNavigationChecks.swift"
(project / code_path).write_text("import SwiftUI\nstruct Component: View { var body: some View { Text(\"Hello\") } }\n")
(project / "broken.pdf").write_text("Not a PDF document")
(project / "index.html").write_text("<!doctype html><title>Preview check</title><h1>Local preview</h1>")
project_id, session_id = str(uuid.uuid4()), str(uuid.uuid4())
draft = "This draft must not be sent from another tab.\nThe second line must stay visible."
workspace = {"projects": [{"id": project_id, "path": str(project), "name": "A long project name for responsive layout checks"}],
             "sessions": [{"id": session_id, "projectID": project_id, "agent": "codex", "title": "UI regression check",
                           "createdAt": "2026-11-05T12:00:00Z", "updatedAt": "2026-11-05T12:00:00Z", "mode": "ask"}]}
(data / "workspace.json").write_text(json.dumps(workspace))


def step(op, **values):
    return dict(op=op, **values)


steps = [step("wait", seconds=1.2), step("agentsMock", seconds=0.1), step("size", width=900, height=600),
         step("draft", text=draft), step("wait", seconds=0.3), step("uiState"),
         step("shortcut", key="4"), step("wait", seconds=0.2),
         step("projectTabClick", tab="agents"), step("wait", seconds=0.3), step("key", code=36),
         step("wait", seconds=0.3), step("state"), step("uiState"),
         step("codeOpen", path=code_path), step("wait", seconds=0.3),
         step("shot", path=str(root / "code.png")), step("projectTabClick", tab="conversation"),
         step("wait", seconds=0.4), step("uiState"), step("shot", path=str(root / "conversation.png")),
         step("browserOpen", url=(project / "index.html").as_uri()), step("browserWait"),
         step("wait", seconds=0.3), step("projectTabClick", tab="conversation"), step("wait", seconds=0.3),
         step("uiState"), step("codeOpen", path="broken.pdf"), step("wait", seconds=0.3),
         step("shot", path=str(root / "invalid-pdf.png")), step("appearance", dark=False),
         step("projectTabClick", tab="conversation"), step("wait", seconds=0.3), step("uiState"),
         step("shot", path=str(root / "light.png")), step("state"), step("quit")]
(root / "steps.json").write_text(json.dumps(steps))
with (root / "driver.log").open("w") as log:
    result = subprocess.run([str(binary)], env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(root / "steps.json")),
                            stdout=log, stderr=subprocess.STDOUT, timeout=35)
lines = (root / "driver.log").read_text().splitlines()
assert result.returncode == 0 and not any("[driver] FAILED" in line for line in lines), root / "driver.log"
states = [json.loads(line.split("[driver] state ", 1)[1]) for line in lines if "[driver] state " in line]
assert states and all(state["items"] == 0 and state["draft"] == draft for state in states), "Hidden composer submitted or lost its draft"
layouts = [json.loads(line.split("[driver] ui ", 1)[1]) for line in lines if "[driver] ui " in line]
assert [layout["tab"] for layout in layouts] == ["Conversation", "Agents", "Conversation", "Conversation", "Conversation"], "Clicking a project tab did not switch panels"
for layout in layouts:
    tabs, composer, content = layout["tabs"], layout["composer"], layout["content"]
    assert tabs["x"] >= 0 and tabs["x"] + tabs["width"] <= layout["windowWidth"] + 1, "Project tabs are clipped"
    if composer:
        assert composer["height"] >= 30, "Multiline draft is clipped after switching tabs"
        used = layout["composerUsedHeight"]
        assert composer["height"] >= min(used, 190) - 1, "Wrapped draft does not fit its visible height"
        if used <= 190:
            assert layout["composerScrollY"] < 1, "Short draft scrolled out of view after resizing"
        assert composer["x"] >= content["x"], "Composer spills into sidebar"
        assert composer["x"] + composer["width"] <= content["x"] + content["width"] + 1, "Composer spills into Changes panel"
    else:
        assert not layout["composerFocused"], "Hidden composer retains keyboard focus"
print(f"UI smoke checks passed. Screenshots and log: {root}")
