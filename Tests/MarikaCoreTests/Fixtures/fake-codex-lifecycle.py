#!/usr/bin/env python3
"""A scriptable stand-in for `codex app-server`, for lifecycle reproductions.

Reply and error texts are copied from the real 0.166.0-alpha.6 server. FAKE_MODE is a comma list:
  hang-init            never answers initialize
  reject-init          answers initialize with an error and stays alive
  init-delay=S         delays the initialize reply
  thread-delay=S       delays the thread/start reply
  turnstart-delay=S    delays the turn/start reply
  hold-turn            starts a turn and stays in it until interrupted
  steer-reject=TEXT    answers turn/start with this error while a turn runs, leaving it running
  crash-in-command     exits 3 once a command has started
  child-run            plays the recorded main + sub-agent sequence
  child-outlives       the main turn ends while its sub-agent keeps running
  approval-then-hold   asks for one command approval, then holds the turn
  ignore-term          ignores SIGTERM and stdin EOF
  burst                writes the turn/start reply, turn/started and turn/completed in one write
  resume-fail          answers thread/resume with the real "no rollout" error
  two-approvals        two parallel approvals; `cancel` ends the turn as recorded in r10.log
  turnstart-hang       the first process never answers turn/start
  turnstart-crash      the first process exits 3 on turn/start, unanswered
  turnstart-reject     answers every turn/start with an error
  resume-archived      thread/resume reports the thread as archived until thread/unarchive
  ignore-interrupt     accepts turn/interrupt but never ends the turn
"""
import json, os, signal, sys, threading, time

log = open(os.environ["FAKE_CODEX_LOG"], "a")
with open(os.environ["FAKE_PIDS"], "a") as pids:
    pids.write("%d\n" % os.getpid())
FIRST = len(open(os.environ["FAKE_PIDS"]).read().split()) == 1

MODE = {}
for part in os.environ.get("FAKE_MODE", "").split(","):
    if part:
        key, _, value = part.partition("=")
        MODE[key] = value or True

out = threading.Lock()

def send(message):
    with out:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

def notify(method, **params):
    send({"method": method, "params": params})

def later(seconds, action):
    timer = threading.Timer(seconds, action)
    timer.daemon = True
    timer.start()

MAIN, CHILD = "thr_main", "thr_child"
TURN, CHILD_TURN = "turn_main", "turn_child"
state = {"active": None, "turns": 0}

def turn(id, status="inProgress", **extra):
    return dict({"id": id, "status": status, "items": [], "error": None, "durationMs": None}, **extra)

def command_item(id, status, output=None):
    return {"type": "commandExecution", "id": id, "command": "/bin/zsh -lc 'sleep 9'", "cwd": "/tmp/project", "processId": None,
            "source": "agent", "status": status, "commandActions": [], "aggregatedOutput": output, "exitCode": None, "durationMs": None}

def child_run():
    """The order recorded from the real server: see r7b.log and r9b.log."""
    notify("turn/started", threadId=MAIN, turn=turn(TURN))
    started = {"type": "subAgentActivity", "id": "sa1", "kind": "started", "agentThreadId": CHILD, "agentPath": "/root/helper", "model": "gpt-test"}
    notify("item/started", threadId=MAIN, turnId=TURN, item=started)
    notify("item/completed", threadId=MAIN, turnId=TURN, item=started)
    notify("thread/status/changed", threadId=CHILD, status={"type": "active", "activeFlags": []})
    state["child"] = CHILD_TURN
    notify("turn/started", threadId=CHILD, turn=turn(CHILD_TURN))
    notify("item/started", threadId=CHILD, turnId=CHILD_TURN, item=command_item("cc1", "inProgress"))

    def child_finishes():
        if state.get("child") is None:
            return
        state["child"] = None
        notify("item/completed", threadId=CHILD, turnId=CHILD_TURN, item=command_item("cc1", "completed", ""))
        notify("item/started", threadId=CHILD, turnId=CHILD_TURN, item={"type": "agentMessage", "id": "cm1", "text": "", "phase": "final_answer"})
        notify("item/completed", threadId=CHILD, turnId=CHILD_TURN, item={"type": "agentMessage", "id": "cm1", "text": "sub-ok", "phase": "final_answer"})
        notify("thread/status/changed", threadId=CHILD, status={"type": "idle"})
        notify("turn/completed", threadId=CHILD, turn=turn(CHILD_TURN, "completed", durationMs=3500))
        notify("item/started", threadId=MAIN, turnId=TURN, item={"type": "subAgentActivity", "id": "subagent-completed-1", "kind": "completed", "agentThreadId": CHILD, "agentPath": "/root/helper"})
        later(0.4, main_command)

    def main_command():
        notify("item/started", threadId=MAIN, turnId=TURN, item=command_item("c1", "inProgress"))
        later(1.0, main_finishes)

    def main_finishes():
        if state["active"] != TURN:
            return
        notify("item/completed", threadId=MAIN, turnId=TURN, item=command_item("c1", "completed", ""))
        notify("item/completed", threadId=MAIN, turnId=TURN, item={"type": "agentMessage", "id": "m1", "text": "done", "phase": "final_answer"})
        state["active"] = None
        notify("turn/completed", threadId=MAIN, turn=turn(TURN, "completed", durationMs=9000))

    later(1.2, child_finishes)

def begin_turn(rpc_id):
    state["turns"] += 1
    state["active"] = TURN
    reply = {"id": rpc_id, "result": {"turn": turn(TURN)}}
    if "burst" in MODE:
        lines = [reply, {"method": "turn/started", "params": {"threadId": MAIN, "turn": turn(TURN)}},
                 {"method": "turn/completed", "params": {"threadId": MAIN, "turn": turn(TURN, "completed", durationMs=1)}}]
        state["active"] = None
        with out:
            sys.stdout.write("".join(json.dumps(line) + "\n" for line in lines))
            sys.stdout.flush()
        return
    send(reply)
    if "child-outlives" in MODE:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        started = {"type": "subAgentActivity", "id": "sa1", "kind": "started", "agentThreadId": CHILD, "agentPath": "/root/helper"}
        notify("item/started", threadId=MAIN, turnId=TURN, item=started)
        state["child"] = CHILD_TURN
        notify("turn/started", threadId=CHILD, turn=turn(CHILD_TURN))
        state["active"] = None
        notify("turn/completed", threadId=MAIN, turn=turn(TURN, "completed", durationMs=5))
    elif "child-run" in MODE:
        child_run()
    elif "crash-in-command" in MODE:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        notify("item/started", threadId=MAIN, turnId=TURN, item=command_item("c1", "inProgress"))
        time.sleep(0.2)
        sys.stderr.write("boom\n")
        sys.stderr.flush()
        os._exit(3)
    elif "hold-turn" in MODE:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        notify("item/started", threadId=MAIN, turnId=TURN, item=command_item("c1", "inProgress"))
    elif "two-approvals" in MODE:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        for rpc_id, item in ((900, "c1"), (901, "c2")):
            notify("item/started", threadId=MAIN, turnId=TURN, item=command_item(item, "inProgress"))
            send({"id": rpc_id, "method": "item/commandExecution/requestApproval", "params": {
                "kind": "command", "threadId": MAIN, "turnId": TURN, "itemId": item, "startedAtMs": 3, "environmentId": None,
                "reason": None, "command": "/bin/zsh -lc 'sleep %d'" % rpc_id, "cwd": "/tmp/project"}})
    elif "approval-then-hold" in MODE:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        notify("item/started", threadId=MAIN, turnId=TURN, item=command_item("c1", "inProgress"))
        send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {
            "kind": "command", "threadId": MAIN, "turnId": TURN, "itemId": "c1", "startedAtMs": 3, "environmentId": None,
            "reason": None, "command": "/bin/zsh -lc 'sleep 9'", "cwd": "/tmp/project"}})
    else:
        notify("turn/started", threadId=MAIN, turn=turn(TURN))
        notify("item/completed", threadId=MAIN, turnId=TURN, item={"type": "agentMessage", "id": "m%d" % state["turns"], "text": "finished", "phase": "final_answer"})
        state["active"] = None
        notify("turn/completed", threadId=MAIN, turn=turn(TURN, "completed", durationMs=5))

def text_of(params):
    return "".join(item.get("text", "") for item in params.get("input", []))

if "ignore-term" in MODE:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

for line in sys.stdin:
    message = json.loads(line)
    log.write(line)
    log.flush()
    method = message.get("method")
    rpc = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        if "hang-init" in MODE:
            continue
        if "reject-init" in MODE:
            send({"id": rpc, "error": {"code": -32600, "message": "Not initialized"}})
            continue
        if "init-delay" in MODE:
            time.sleep(float(MODE["init-delay"]))
        send({"id": rpc, "result": {"userAgent": "fake/1.0", "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "initialized":
        pass
    elif method == "account/read":
        send({"id": rpc, "result": {"account": {"type": "chatgpt", "email": "dev@example.com", "planType": "plus", "workspaceName": None}, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        send({"id": rpc, "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1730947200}, "secondary": None, "rateLimitReachedType": None}}})
    elif method == "model/list":
        send({"id": rpc, "result": {"data": [], "nextCursor": None}})
    elif method == "config/read":
        send({"id": rpc, "result": {"config": {}, "origins": {}, "layers": None}})
    elif method == "thread/start":
        if "thread-delay" in MODE:
            time.sleep(float(MODE["thread-delay"]))
        send({"id": rpc, "result": {"thread": {"id": MAIN}, "model": "gpt-test", "modelProvider": "openai", "cwd": "/tmp/project"}})
        notify("thread/started", thread={"id": MAIN})
    elif method == "thread/unarchive":
        state["unarchived"] = True
        send({"id": rpc, "result": {"thread": {"id": params["threadId"]}}})
    elif method == "thread/resume":
        if "resume-fail" in MODE:
            send({"id": rpc, "error": {"code": -32600, "message": "no rollout found for thread id " + params.get("threadId", "")}})
        elif "resume-archived" in MODE and not state.get("unarchived"):
            tid = params.get("threadId", "")
            send({"id": rpc, "error": {"code": -32600, "message": "session %s is archived. Run `codex unarchive %s` to unarchive it first." % (tid, tid)}})
        else:
            MAIN = params["threadId"]
            send({"id": rpc, "result": {"thread": {"id": params["threadId"]}, "model": "gpt-test", "modelProvider": "openai", "cwd": "/tmp/project"}})
    elif method == "turn/start":
        if "turnstart-reject" in MODE:
            send({"id": rpc, "error": {"code": -32602, "message": "Input exceeds the maximum length of 1048576 characters."}})
            continue
        if "turnstart-delay" in MODE:
            time.sleep(float(MODE["turnstart-delay"]))
        if "turnstart-hang" in MODE and FIRST:
            continue
        if "turnstart-crash" in MODE and FIRST:
            time.sleep(0.2)
            os._exit(3)
        if state["active"] is not None:
            # The real server adds input to the running turn and returns its id.
            if "steer-reject" in MODE:
                send({"id": rpc, "error": {"code": -32600, "message": MODE["steer-reject"]}})
            else:
                send({"id": rpc, "result": {"turn": turn(state["active"])}})
            continue
        begin_turn(rpc)
    elif method == "turn/interrupt":
        thread, target = params.get("threadId"), params.get("turnId")
        if "ignore-interrupt" in MODE:
            send({"id": rpc, "result": {}})
        elif thread == CHILD:
            if target != CHILD_TURN or state.get("child") is None:
                send({"id": rpc, "error": {"code": -32600, "message": "no active turn to interrupt"}})
            else:
                state["child"] = None
                send({"id": rpc, "result": {}})
                notify("turn/completed", threadId=CHILD, turn=turn(CHILD_TURN, "interrupted", durationMs=10))
        elif state["active"] is None:
            send({"id": rpc, "error": {"code": -32600, "message": "no active turn to interrupt"}})
        elif target != state["active"]:
            send({"id": rpc, "error": {"code": -32600, "message": "expected active turn id %s but found %s" % (target, state["active"])}})
        else:
            state["active"] = None
            send({"id": rpc, "result": {}})
            notify("turn/completed", threadId=MAIN, turn=turn(TURN, "interrupted", durationMs=10))
    elif method is None and rpc == 900:
        if "two-approvals" in MODE and (message.get("result") or {}).get("decision") == "cancel":
            notify("serverRequest/resolved", threadId=MAIN, requestId=900)
            notify("item/completed", threadId=MAIN, turnId=TURN, item=command_item("c1", "declined"))
            state["active"] = None
            notify("thread/status/changed", threadId=MAIN, status={"type": "idle"})
            notify("turn/completed", threadId=MAIN, turn=turn(TURN, "interrupted", durationMs=10))
            notify("serverRequest/resolved", threadId=MAIN, requestId=901)
    elif method is not None and rpc is not None:
        send({"id": rpc, "error": {"code": -32601, "message": "unknown method " + method}})

if "ignore-term" in MODE:
    while True:
        time.sleep(1)
