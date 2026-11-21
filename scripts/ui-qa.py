#!/usr/bin/env python3
"""Exercise QA persistence and ticket integration in an isolated native app.

--prepare prints fixture paths for a manual/native UI review instead of launching checks.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="marika-qa-"))
data = root / "data"
project = root / "Copper"
data.mkdir()
project.mkdir()
page = project / "checkout.html"
page.write_text("""<!doctype html><html><head><meta charset="utf-8"><title>Copper checkout</title>
<style>body{font:16px system-ui;background:#f5f3ef;color:#252525;padding:28px;margin:auto;max-width:560px}h1{font-size:32px}section{padding:24px;background:white;border-radius:16px;margin:22px 0}input{padding:12px;border:1px solid #bbb;border-radius:8px;width:170px}button{padding:12px 18px;border:0;background:#333;color:white;border-radius:8px;cursor:pointer}#status{margin-top:20px}small{color:#666}</style></head>
<body><small>COPPER · TEST STORE</small><h1>Checkout</h1><section><h2>Studio headphones</h2><p>Quantity: 1</p><strong id="total">Total: £100</strong></section>
<section><label for="discount">Discount code</label><p><input id="discount" placeholder="Enter code"><button id="apply" type="button">Apply</button></p><p id="status">No discount applied</p><button id="remove" type="button">Remove code</button></section>
<script>document.querySelector('#apply').onclick=()=>{document.querySelector('#status').textContent='Discount applied';document.querySelector('#total').textContent='Total: £90'};document.querySelector('#remove').onclick=()=>{document.querySelector('#discount').value='';document.querySelector('#status').textContent='No discount applied';document.querySelector('#total').textContent='Total: £100'};</script></body></html>""")
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
date = "2026-11-19T12:00:00Z"
(data / "workspace.json").write_text(json.dumps(dict(
    projects=[dict(id=pid, name="Copper", path=str(project), conversationSessionID=sid,
                   layout=dict(showsInspector=False, browserURLs=[page.as_uri()]))],
    sessions=[dict(id=sid, projectID=pid, agent="codex", title="QA project", mode="ask", createdAt=date, updatedAt=date)])))


def run(name, steps):
    script = root / (name + ".json")
    log = root / (name + ".log")
    script.write_text(json.dumps(steps))
    with log.open("w") as output:
        result = subprocess.run([str(repo / ".build/debug/Marika")],
                                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
                                stdout=output, stderr=subprocess.STDOUT, timeout=90)
    text = log.read_text()
    assert result.returncode == 0 and "[driver] FAILED" not in text, text[-5000:]
    return text


steps = [dict(op="wait", seconds=1), dict(op="qaTest")]
if "--prepare" in sys.argv:
    driver = root / "review.json"
    driver.write_text(json.dumps(steps))
    print(json.dumps(dict(root=str(root), data=str(data), project=str(project), driver=str(driver), page=page.as_uri())))
else:
    text = run("checks", steps + [dict(op="qaRegressionTest"), dict(op="quit")])
    assert "QA passed:" in text
    assert "QA regressions passed:" in text
    workspace = json.loads((data / "workspace.json").read_text())
    qa = workspace["projects"][0]["qa"]
    assert len(qa["cases"]) == 1 and not qa["cases"][0]["approved"]
    assert qa["runs"][0]["cases"][0]["steps"][0]["status"] == "Failed"
    assert qa["runs"][0]["cases"][0]["steps"][1]["status"] == "Not tested"
    ticket = workspace["spaces"][0]["tickets"][0]
    assert ticket["kind"] == "Bug" and ticket["qaSource"]["runID"] == qa["runs"][0]["id"]
    run("restart", [dict(op="wait", seconds=1), dict(op="qaRestoreTest"), dict(op="quit")])
    restored = json.loads((data / "workspace.json").read_text())
    assert restored["projects"][0]["qa"] == qa
    interrupted = json.loads(json.dumps(qa["runs"][0]))
    interrupted["id"] = str(uuid.uuid4())
    interrupted["mode"] = "WebKit replay"
    interrupted.pop("finishedAt", None)
    interrupted["cases"][0]["steps"][0]["status"] = "Passed"
    restored["projects"][0]["qa"]["runs"].append(interrupted)
    (data / "workspace.json").write_text(json.dumps(restored))
    run("interrupted", [dict(op="wait", seconds=1), dict(op="qaRestoreTest"), dict(op="quit")])
    recovered = json.loads((data / "workspace.json").read_text())["projects"][0]["qa"]["runs"][-1]
    assert recovered["finishedAt"]
    assert recovered["cases"][0]["steps"][1]["status"] == "Blocked"
    assert "interrupted" in recovered["cases"][0]["steps"][1]["actual"]
    print("QA integration, comparison, evidence and interrupted-replay restart checks passed. Fixture:", root)
