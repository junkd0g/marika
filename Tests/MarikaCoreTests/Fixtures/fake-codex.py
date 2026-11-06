#!/usr/bin/env python3
"""A stand-in for `codex app-server`, following codex-rs/app-server-protocol/schema/typescript.

Real Codex is not always installed where tests run. This plays one scripted turn and records
every message the client sends, so tests can check both directions of the protocol.
"""
import json, os, sys

log = open(os.environ["FAKE_CODEX_LOG"], "a")

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def notify(method, **params):
    send({"method": method, "params": params})

THREAD, TURN = "thr_1", "turn_1"
started = False
SCRIPT = os.environ.get("FAKE_SCRIPT", "")

def finish_quietly():
    global started
    notify("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    notify("turn/completed", threadId=THREAD, turn={"id": TURN, "status": "completed", "items": [], "error": None, "durationMs": 1})
    started = False

def begin_edit_turn():
    """One edit in the project, then one to a protected path, then one outside it."""
    notify("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    root = os.getcwd()
    for index, path in enumerate([root + "/src/a.ts", root + "/.git/config", "/etc/outside.txt"]):
        item = "f%d" % index
        changes = [{"path": path, "kind": {"type": "update", "move_path": None}, "diff": "@@ -1 +1 @@\n-old\n+new\n"}]
        notify("item/started", threadId=THREAD, turnId=TURN, startedAtMs=1, item={"type": "fileChange", "id": item, "changes": changes, "status": "inProgress"})
        send({"id": 910 + index, "method": "item/fileChange/requestApproval", "params": {
            "threadId": THREAD, "turnId": TURN, "itemId": item, "startedAtMs": 1, "reason": None, "grantRoot": None}})

def begin_mcp_turn():
    notify("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    send({"id": 920, "method": "mcpServer/elicitation/request", "params": {
        "threadId": THREAD, "turnId": TURN, "serverName": "lab", "mode": "form",
        "_meta": {"codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"], "tool_description": "Echoes.",
                  "tool_params": {"text": "hello"}, "tool_params_display": [{"name": "text", "value": "hello", "display_name": "text"}]},
        "message": 'Allow the lab MCP server to run tool "lab_echo"?', "requestedSchema": {"type": "object", "properties": {}}}})

def begin_form_turn():
    notify("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    send({"id": 930, "method": "mcpServer/elicitation/request", "params": {
        "threadId": THREAD, "turnId": TURN, "serverName": "lab", "mode": "form", "_meta": None, "message": "Which colour?",
        "requestedSchema": {"type": "object", "required": ["colour"], "properties": {
            "colour": {"type": "string", "title": "Colour", "enum": ["red", "blue"]},
            "count": {"type": "integer", "title": "Count"},
            "keep": {"type": "boolean", "title": "Keep"}}}}})

def begin_turn():
    notify("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    notify("item/started", threadId=THREAD, turnId=TURN, startedAtMs=1, item={"type": "reasoning", "id": "r1", "summary": [], "content": []})
    notify("item/reasoning/summaryTextDelta", threadId=THREAD, turnId=TURN, itemId="r1", delta="Looking at", summaryIndex=0)
    notify("item/reasoning/summaryTextDelta", threadId=THREAD, turnId=TURN, itemId="r1", delta=" the tests", summaryIndex=0)
    notify("item/completed", threadId=THREAD, turnId=TURN, completedAtMs=2, item={"type": "reasoning", "id": "r1", "summary": ["Looking at the tests"], "content": []})
    notify("turn/plan/updated", threadId=THREAD, turnId=TURN, explanation=None, plan=[{"step": "Run tests", "status": "inProgress"}, {"step": "Fix bug", "status": "pending"}])
    notify("item/started", threadId=THREAD, turnId=TURN, startedAtMs=3, item={
        "type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'npm test'", "cwd": "/tmp/project", "processId": None,
        "source": "agent", "status": "inProgress", "commandActions": [], "aggregatedOutput": None, "exitCode": None, "durationMs": None})
    send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {
        "kind": "command", "threadId": THREAD, "turnId": TURN, "itemId": "c1", "startedAtMs": 3, "environmentId": None,
        "reason": "Runs project code", "command": "/bin/zsh -lc 'npm test'", "cwd": "/tmp/project"}})

def finish_turn(decision):
    declined = decision in ("decline", "cancel")
    if declined:
        notify("item/completed", threadId=THREAD, turnId=TURN, completedAtMs=4, item={
            "type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'npm test'", "cwd": "/tmp/project", "status": "declined",
            "commandActions": [], "aggregatedOutput": None, "exitCode": None, "durationMs": None})
        notify("turn/completed", threadId=THREAD, turn={"id": TURN, "status": "interrupted", "items": [], "error": None, "durationMs": 40})
        return
    notify("item/commandExecution/outputDelta", threadId=THREAD, turnId=TURN, itemId="c1", delta="1 passing\n")
    notify("item/completed", threadId=THREAD, turnId=TURN, completedAtMs=4, item={
        "type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'npm test'", "cwd": "/tmp/project", "status": "completed",
        "commandActions": [], "aggregatedOutput": "1 passing\n", "exitCode": 0, "durationMs": 900})
    changes = [
        {"path": "/tmp/project/src/a.ts", "kind": {"type": "update", "move_path": None}, "diff": "@@ -1 +1 @@\n-old\n+new\n"},
        {"path": "/tmp/project/src/b.ts", "kind": {"type": "add"}, "diff": "created\nfile\n"},
    ]
    notify("item/started", threadId=THREAD, turnId=TURN, startedAtMs=5, item={"type": "fileChange", "id": "f1", "changes": changes, "status": "inProgress"})
    send({"id": 901, "method": "item/fileChange/requestApproval", "params": {
        "threadId": THREAD, "turnId": TURN, "itemId": "f1", "startedAtMs": 5, "reason": None, "grantRoot": None}})

def complete_edits():
    changes = [
        {"path": "/tmp/project/src/a.ts", "kind": {"type": "update", "move_path": None}, "diff": "@@ -1 +1 @@\n-old\n+new\n"},
        {"path": "/tmp/project/src/b.ts", "kind": {"type": "add"}, "diff": "created\nfile\n"},
    ]
    notify("item/completed", threadId=THREAD, turnId=TURN, completedAtMs=6, item={"type": "fileChange", "id": "f1", "changes": changes, "status": "completed"})
    notify("turn/diff/updated", threadId=THREAD, turnId=TURN, diff="diff --git a/x b/x")
    notify("item/started", threadId=THREAD, turnId=TURN, startedAtMs=7, item={"type": "agentMessage", "id": "m1", "text": "", "phase": None})
    notify("item/agentMessage/delta", threadId=THREAD, turnId=TURN, itemId="m1", delta="All ")
    notify("item/agentMessage/delta", threadId=THREAD, turnId=TURN, itemId="m1", delta="green.")
    notify("item/completed", threadId=THREAD, turnId=TURN, completedAtMs=8, item={"type": "agentMessage", "id": "m1", "text": "All green.", "phase": "final_answer"})
    notify("thread/tokenUsage/updated", threadId=THREAD, turnId=TURN, tokenUsage={
        "total": {"totalTokens": 900, "inputTokens": 800, "cachedInputTokens": 0, "cacheWriteInputTokens": 0, "outputTokens": 100, "reasoningOutputTokens": 0},
        "last": {"totalTokens": 500, "inputTokens": 400, "cachedInputTokens": 0, "cacheWriteInputTokens": 0, "outputTokens": 100, "reasoningOutputTokens": 0},
        "modelContextWindow": 1000})
    notify("account/rateLimits/updated", rateLimits={"limitId": "codex", "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1730947200}, "secondary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1731000000}, "rateLimitReachedType": None})
    notify("turn/completed", threadId=THREAD, turn={"id": TURN, "status": "completed", "items": [], "error": None, "durationMs": 1234})

for line in sys.stdin:
    message = json.loads(line)
    log.write(line); log.flush()
    method = message.get("method")
    if method == "initialize":
        send({"id": message["id"], "result": {"userAgent": "fake/1.0", "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "initialized":
        pass
    elif method == "account/read":
        send({"id": message["id"], "result": {"account": {"type": "chatgpt", "email": "dev@example.com", "planType": "plus", "workspaceName": None}, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        send({"id": message["id"], "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1730947200}, "secondary": None, "rateLimitReachedType": None}, "rateLimitsByLimitId": None}})
    elif method == "model/list":
        send({"id": message["id"], "result": {"data": [
            {"id": "m1", "model": "gpt-test", "displayName": "GPT Test", "description": "Test model", "hidden": False, "isDefault": True,
             "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": ""}, {"reasoningEffort": "high", "description": ""}], "defaultReasoningEffort": "low"},
            {"id": "m2", "model": "gpt-hidden", "displayName": "Hidden", "description": "", "hidden": True, "isDefault": False, "supportedReasoningEfforts": [], "defaultReasoningEffort": "low"},
        ], "nextCursor": None}})
    elif method == "thread/start":
        send({"id": message["id"], "result": {"thread": {"id": THREAD}, "model": "gpt-test", "modelProvider": "openai", "cwd": "/tmp/project"}})
        notify("thread/started", thread={"id": THREAD})
    elif method == "thread/resume":
        send({"id": message["id"], "result": {"thread": {"id": message["params"]["threadId"]}, "model": "gpt-test", "modelProvider": "openai", "cwd": "/tmp/project"}})
    elif method == "turn/start":
        send({"id": message["id"], "result": {"turn": {"id": TURN, "status": "inProgress", "items": []}}})
        # The real server adds input to a running turn instead of starting another.
        if not started:
            started = True
            if SCRIPT == "edit-paths":
                begin_edit_turn()
            elif SCRIPT == "mcp":
                begin_mcp_turn()
            elif SCRIPT == "form":
                begin_form_turn()
            elif SCRIPT == "quiet":
                finish_quietly()
            else:
                begin_turn()
    elif method == "config/read":
        send({"id": message["id"], "result": {"config": json.loads(os.environ.get("FAKE_CONFIG", "{}")), "origins": {}, "layers": None}})
    elif method == "turn/interrupt":
        send({"id": message["id"], "result": {}})
        notify("turn/completed", threadId=THREAD, turn={"id": TURN, "status": "interrupted", "items": [], "error": None, "durationMs": 10})
    elif method is None and message.get("id") == 900:
        finish_turn(message["result"]["decision"])
    elif method is None and message.get("id") == 901:
        complete_edits()
    elif method is not None and "id" in message:
        send({"id": message["id"], "error": {"code": -32601, "message": "unknown method " + method}})
