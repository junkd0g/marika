#!/usr/bin/env python3
"""Exercise the sandboxed prototype's bundled Codex and chat persistence with a local Responses fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "build/store-prototype/Marika.app"
identifier = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
assert identifier == "app.marika.testing.store", "Use the debug store-prototype bundle."
entitlements = subprocess.check_output(["codesign", "-d", "--xml", "--entitlements", "-", app], stderr=subprocess.DEVNULL)
assert plistlib.loads(entitlements).get("com.apple.security.app-sandbox")
sentinel = "Marika sandbox fixture completed."
received = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path.split("?")[0].rstrip("/") != "/v1/responses":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not body:
            self.send_error(400)
            return
        received.set()
        message = dict(id="msg_1", type="message", role="assistant", status="completed",
                       content=[dict(type="output_text", text=sentinel, annotations=[])])
        events = [
            dict(type="response.created", response=dict(id="resp_1", status="in_progress", output=[])),
            dict(type="response.output_item.added", output_index=0, item=dict(message, content=[], status="in_progress")),
            dict(type="response.output_text.delta", item_id="msg_1", output_index=0, content_index=0, delta=sentinel),
            dict(type="response.output_item.done", output_index=0, item=message),
            dict(type="response.completed", response=dict(id="resp_1", status="completed", output=[message])),
        ]
        data = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


with ThreadingHTTPServer(("127.0.0.1", 0), Provider) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    parent = Path.home() / "Library/Containers" / identifier / "Data/Library/Application Support/MarikaChecks"
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=parent) as root:
        root = Path(root)
        project = root / "Sample"
        project.mkdir()
        (project / "README.md").write_text("# Sample project\n")
        data = root / "data"
        codex = data / "codex"
        codex.mkdir(parents=True)
        (codex / "config.toml").write_text(
            'model = "gpt-5"\nmodel_provider = "fixture"\n[model_providers.fixture]\n'
            f'name = "Fixture"\nbase_url = "http://127.0.0.1:{server.server_port}/v1"\n'
            'wire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\n')
        pid, sid = (str(uuid.uuid4()) for _ in range(2))
        date = "2026-11-20T12:00:00Z"
        (data / "workspace.json").write_text(json.dumps(dict(projects=[dict(id=pid, path=str(project), name="Sample", conversationSessionID=sid)],
            sessions=[dict(id=sid, projectID=pid, agent="codex", title="Sample chat", mode="ask", createdAt=date, updatedAt=date)])))
        driver = root / "steps.json"
        driver.write_text(json.dumps([dict(op="send", text="Check the sample workspace."), dict(op="waitFor", what="idle", timeout=65), dict(op="quit")]))
        env = dict(MARIKA_DATA=str(data), MARIKA_DRIVER=str(driver), PATH="/usr/bin:/bin")
        result = subprocess.run([app / "Contents/MacOS/Marika"], env=env, capture_output=True, timeout=100)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace")[-2500:])
        transcripts = list((data / "transcripts").glob("*.json"))
        assert received.is_set() and any(sentinel in path.read_text() for path in transcripts), "Bundled agent did not finish the fixture turn."
    server.shutdown()
print("Sandboxed bundled Codex completed a chat turn against the local fixture and Marika saved its reply.")
