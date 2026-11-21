#!/usr/bin/env python3
"""Check browser access defaults, bridge behavior and restart persistence in isolated data.

--prepare creates a fixture for native UI review without launching it.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="marika-browser-access-"))
data = root / "data"
project = root / "Project"
data.mkdir()
project.mkdir()
(project / "index.html").write_text("<!doctype html><title>Browser access fixture</title><h1>Browser access fixture</h1><p>Local test content.</p>")
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
date = "2026-11-20T12:00:00Z"
(data / "workspace.json").write_text(json.dumps(dict(
    projects=[dict(id=pid, name="Access fixture", path=str(project), conversationSessionID=sid,
                   layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent="codex", title="Browser access fixture", mode="ask", createdAt=date, updatedAt=date)])))


def run(name, steps):
    script, log = root / (name + ".json"), root / (name + ".log")
    script.write_text(json.dumps(steps))
    with log.open("w") as output:
        result = subprocess.run([str(repo / ".build/debug/Marika")],
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
            stdout=output, stderr=subprocess.STDOUT, timeout=75)
    text = log.read_text()
    assert result.returncode == 0 and "[driver] FAILED" not in text, text[-4000:]
    return text


steps = [dict(op="wait", seconds=1), dict(op="browserAgentAccessTest")]
if "--prepare" in sys.argv:
    driver = root / "review.json"
    driver.write_text(json.dumps(steps))
    print(json.dumps(dict(root=str(root), data=str(data), project=str(project), driver=str(driver))))
else:
    assert "Browser agent access passed" in run("checks", steps + [dict(op="quit")])
    assert "restored after restart" in run("restart", [dict(op="wait", seconds=1), dict(op="browserAgentAccessRestoreTest"), dict(op="quit")])
    workspace = json.loads((data / "workspace.json").read_text())
    assert workspace["projects"][0]["layout"]["browserAISharingConsent"] is False
    print("Browser access defaults, opt-out, bridge gating and restart checks passed. Fixture:", root)
