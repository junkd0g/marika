#!/usr/bin/env python3
"""Check project-only navigation, saved conversations, and editor keyboard controls.

Build the debug app first. This uses isolated data and sends no model requests.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="marika-projects-ui-"))
project_a, project_b, data = root / "Projects/Studio", root / "Projects/Research", root / "data"
for path in [project_a / "Sources/App", project_a / "Sources/Preview", project_b, data]:
    path.mkdir(parents=True, exist_ok=True)
for name in ["App", "Preview"]:
    (project_a / f"Sources/{name}/View.swift").write_text(f"// {name}\nimport SwiftUI\n")
(project_a / "README.md").write_text("# Studio\n")
a, b, primary, legacy, worker, other = [str(uuid.uuid4()) for _ in range(6)]

def meta(sid, pid, title, timestamp):
    return dict(id=sid, projectID=pid, agent="codex", title=title, createdAt=timestamp, updatedAt=timestamp, mode="ask")

workspace = {
    "projects": [{"id": a, "path": str(project_a), "name": "Studio", "conversationSessionID": primary},
                 {"id": b, "path": str(project_b), "name": "Research"}],
    "sessions": [meta(primary, a, "Main project conversation", "2026-11-05T12:00:00Z"),
                 meta(legacy, a, "Legacy discussion", "2026-11-05T13:00:00Z"),
                 dict(meta(worker, a, "Task agent", "2026-11-05T14:00:00Z"), agentTask={"prompt": "Review code"}),
                 meta(other, b, "Research conversation", "2026-11-05T11:00:00Z")],
}
(data / "workspace.json").write_text(json.dumps(workspace))

def step(op, **values):
    return dict(op=op, **values)

steps = [step("wait", seconds=1), step("size", width=1100, height=740), step("appearance", dark=True), step("agentsMock", seconds=.1),
         step("workspaceState"), step("search", text="Legacy discussion"), step("wait", seconds=.2), step("workspaceState"),
         step("search", text=""), step("wait", seconds=.2), step("projectClick", name="Research"), step("wait", seconds=.2),
         step("workspaceState"), step("projectClick", name="Studio"), step("wait", seconds=.2), step("workspaceState"),
         step("draft", text="Keep this project draft."), step("shortcut", key="2"), step("wait", seconds=.3),
         step("codeOpen", path="Sources/App/View.swift"), step("wait", seconds=.2), step("codeInsert", text="// unsaved\n"),
         step("codeOpen", path="Sources/Preview/View.swift"), step("wait", seconds=.2),
         step("shortcut", key="[", exactMenu=True), step("wait", seconds=.2), step("codeState"),
         step("shortcut", key="]", exactMenu=True), step("wait", seconds=.2), step("codeState"),
         step("codeSearch", text="View", navigator=True), step("wait", seconds=.2), step("shortcut", key="\\", exactMenu=True),
         step("wait", seconds=.2), step("codeState"), step("shortcut", key="e", shift=True, exactMenu=True),
         step("wait", seconds=.3), step("codeState"), step("codeSearch", text="", navigator=True),
         step("wait", seconds=.2), step("shot", path=str(root / "editor.png")),
         step("appearance", dark=False), step("wait", seconds=.2), step("shot", path=str(root / "editor-light.png")),
         step("shortcut", key="3"), step("wait", seconds=.2), step("projectTabState"),
         step("shortcut", key="4"), step("wait", seconds=.2), step("projectTabState"),
         step("shortcut", key="1"), step("wait", seconds=.2), step("state"),
         step("projectClick", name="Research"), step("wait", seconds=.2),
         step("projectClick", name="Studio"), step("wait", seconds=.2), step("state"),
         step("open", path=str(project_a)), step("wait", seconds=.2), step("workspaceState"), step("quit")]


def run(steps, suffix):
    script = root / f"steps-{suffix}.json"
    script.write_text(json.dumps(steps))
    log_path = root / f"driver-{suffix}.log"
    with log_path.open("w") as log:
        result = subprocess.run([str(repo / ".build/debug/Marika")],
                                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
                                stdout=log, stderr=subprocess.STDOUT, timeout=45)
    lines = log_path.read_text().splitlines()
    assert result.returncode == 0 and not any("[driver] FAILED" in line for line in lines), log_path
    return lines


def records(lines, tag):
    return [json.loads(line.split(tag, 1)[1]) for line in lines if tag in line]


lines = run(steps, "navigation")
spaces = records(lines, "[driver] workspace ")
assert [entry["projectRows"] for entry in spaces] == [2, 0, 2, 2, 2], spaces
assert [entry["selectedSession"].lower() for entry in [spaces[0], spaces[2], spaces[3]]] == [primary, other, primary], spaces
assert all(entry["sessionCount"] == 4 for entry in spaces), "Switching projects created extra conversations"
files = records(lines, "[driver] code ")
assert files[0]["path"] == "Sources/App/View.swift" and files[0]["modified"], files[0]
assert files[1]["path"] == "Sources/Preview/View.swift", files[1]
assert files[2]["navigatorVisible"] is False, files[2]
assert files[3]["navigatorVisible"] is True and files[3]["navigatorQuery"] == "View", files[3]
assert "project tab Browser" in "\n".join(lines) and "project tab Agents" in "\n".join(lines)
states = records(lines, "[driver] state ")
assert len(states) == 2 and all(state["draft"] == "Keep this project draft." for state in states), states
restarted = run([step("wait", seconds=1), step("workspaceState"), step("state"), step("quit")], "restart")
assert records(restarted, "[driver] workspace ")[0]["selectedSession"].lower() == primary
assert records(restarted, "[driver] state ")[0]["draft"] == "Keep this project draft."
print(f"Project navigation, keyboard controls, file history, and draft restoration passed. Screenshots and logs: {root}")
