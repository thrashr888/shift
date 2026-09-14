"""Coding workflow contracts through the real CLI with a deterministic provider:
dirty git checkouts, projects without git, patch conflicts, stale files, failing
and cancelled runs, interrupted mutations, and undo."""

import hashlib
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = str(ROOT / "bin/shift")


def sse(events):
    return "".join("data: " + json.dumps(event) + "\n\n" for event in events) + "data: [DONE]\n\n"


def usage_event(usage):
    return [{"choices": [], "usage": usage}] if usage else []


def tool_call(name, arguments, usage=None):
    call = {
        "index": 0,
        "id": "call_" + name,
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }
    return sse(
        [
            {"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
        ]
        + usage_event(usage)
    )


def answer(text, usage=None):
    return sse(
        [
            {"choices": [{"index": 0, "delta": {"content": text}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        ]
        + usage_event(usage)
    )


PROVIDER_ERROR = "provider-error"
RATE_LIMITED = "rate-limited"


class Provider(BaseHTTPRequestHandler):
    """Serves a planned list of responses; a plan entry may be a callable that
    runs before its response is sent, to change the world mid-turn."""

    plan = []
    last_messages = []
    judge_requests = 0
    lock = threading.Lock()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        judge_request = "safety judge" in str(body["messages"][0].get("content", ""))
        with Provider.lock:
            if judge_request:
                Provider.judge_requests += 1
                # The autopilot judge shares this fixture: a marked plan entry answers it, otherwise it allows.
                if Provider.plan and isinstance(Provider.plan[0], tuple) and Provider.plan[0][0] == "judge":
                    step = Provider.plan.pop(0)[1]
                else:
                    step = answer(json.dumps({"verdict": "allow", "rule": "ok", "reason": "fixture"}))
            else:
                Provider.last_messages = body["messages"]
                step = Provider.plan.pop(0) if Provider.plan else answer("done")
                if isinstance(step, tuple):
                    step = step[1]
        if callable(step):
            step = step()
        if step in (PROVIDER_ERROR, RATE_LIMITED):
            self.send_response(503 if step == PROVIDER_ERROR else 429)
            self.send_header("Content-Type", "application/json")
            if step == RATE_LIMITED:
                self.send_header("Retry-After", "1")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"unavailable"}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(step.encode())

    def do_GET(self):
        # The OpenAI-compatible model list the Model tab asks for; no inference.
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({"data": [{"id": "fake"}, {"id": "offline-fixture"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


class CodingWorkflow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shift-workflow-")
        self.project = Path(self.temp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        Provider.plan = []
        Provider.last_messages = []
        image = (ROOT / "test/session-agent.scm").read_text()
        for old, new in (
            ("(define agent-provider 'ollama)", "(define agent-provider 'openai)"),
            ('(define agent-model "demo")', '(define agent-model "fake")'),
            ("http://127.0.0.1:11434", f"http://127.0.0.1:{self.server.server_port}"),
            ("(define agent-tools '(read rg))",
             "(define agent-tools '(read rg skill write edit apply_patch status diff run job tool_search))"),
            ("(define agent-max-tool-rounds 1)", "(define agent-max-tool-rounds 6)"),
            ("(define agent-compaction-threshold 12)", "(define agent-compaction-threshold 80)"),
        ):
            self.assertIn(old, image)
            image = image.replace(old, new)
        self.agent = self.project / ".agent.scm"
        self.agent.write_text(image)
        # Retries are opt-in per test so a planned provider error fails fast.
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.project / ".config"), "SHIFT_PROVIDER_RETRIES": "0"}
        self.env.pop("SHIFT_BUILTINS", None)
        (self.project / "notes.txt").write_text("alpha port 8080\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def command(self, session="w"):
        return [BIN, "--agent", str(self.agent), "--no-watch", "--no-mcp", "--session", session]

    def shift(self, stdin, plan=(), session="w"):
        Provider.plan = list(plan)
        result = subprocess.run(
            self.command(session), input=stdin, text=True, capture_output=True,
            cwd=self.project, env=self.env, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout + result.stderr

    def print_mode(self, task, plan, *flags, session="p"):
        """Unattended run; returns (exit code, stdout, stderr)."""
        Provider.plan = list(plan)
        result = subprocess.run(
            [BIN, "--agent", str(self.agent), "--session", session, "--print", task, *flags],
            text=True, capture_output=True, cwd=self.project, env=self.env, timeout=60,
            stdin=subprocess.DEVNULL,
        )
        return result.returncode, result.stdout, result.stderr

    def tool_results(self):
        return [m.get("content") for m in Provider.last_messages if m.get("role") == "tool"]

    def state(self, session="w"):
        return self.project / ".shift/sessions" / session

    def checkpoint(self, session="w"):
        return json.loads((self.state(session) / "session.json").read_text())

    def ledger(self, session="w"):
        path = self.state(session) / "changes.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def git(self, *args):
        subprocess.run(
            ["git", "-C", str(self.project), "-c", "user.name=t", "-c", "user.email=t@example.com",
             "-c", "commit.gpgsign=false", *args],
            check=True, capture_output=True,
        )

    edit_notes = tool_call("edit", {"path": "notes.txt", "old_text": "8080", "new_text": "9443"})

    def test_agent_ui_patch_is_immediate_durable_and_does_not_change_permissions(self):
        self.agent.write_text(self.agent.read_text().replace('status diff run job tool_search))', 'status diff run job tool_search ui))'))
        plan = [tool_call("ui", {"action":"patch", "patch":{"identity":"thrashr888", "branding":"replace", "placement":"left"}}),
                tool_call("ui", {"action":"get"}), answer("Your interface is updated.")]
        code, out, err = self.print_mode("Make this mine", plan, "--mode", "autopilot")
        self.assertEqual(code, 0, err)
        state = json.loads(self.tool_results()[-1])
        self.assertEqual(state["config"]["identity"], "thrashr888")
        self.assertEqual(state["config"]["placement"], "left")
        saved = json.loads((self.state("p") / "ui.json").read_text())
        self.assertEqual(saved["branding"], "replace")
        self.assertEqual(self.checkpoint("p")["generation_id"], 1)
        self.assertIn('"identity":"thrashr888"', self.shift('/ui\n/quit\n', session="p"))

    def test_tui_ui_changes_while_approval_waits_preserve_draft_and_policy(self):
        from tui_test import tui, terminal_view
        from unittest.mock import patch
        Provider.plan = [tool_call("read", {"path":"notes.txt"}), answer("Read was declined.")]
        with patch.dict(os.environ, self.env):
            child = tui.Child(self.command()[1:], cwd=self.project)
        model = tui.Model()
        def wait_for(predicate):
            end = time.monotonic() + 10
            while time.monotonic() < end:
                child.poll(model)
                if predicate(): return
                time.sleep(.02)
            self.fail(str(list(model.lines)))
        try:
            wait_for(lambda:model.ready)
            model.draft, model.cursor = "keep my next prompt", 7
            child.send("Read the file"); model.ready=False
            wait_for(lambda:model.approval)
            self.assertEqual(model.pending_draft, ("keep my next prompt", 7))
            wait_for(lambda:bool(model.approval_prompt))
            wait_for(lambda:bool(model.approval_preview))
            approval_prompt=model.approval_prompt
            child.ui({'action':'session-command','command':'/mode autopilot','request_id':41})
            model.command_pending=41
            wait_for(lambda:model.command_pending is None)
            self.assertIn('busy',model.notice)
            self.assertEqual(model.session['mode'],'manual')
            self.assertTrue(model.approval)
            terminal=terminal_view(child=child);terminal.model=model
            source=Path(__file__).resolve().parents[1]/'scripts/tui.py'
            with tempfile.TemporaryDirectory(prefix='shift-live-reload-') as reload_tmp:
                candidate=Path(reload_tmp)/'tui.py'
                code=source.read_text();candidate.write_text(code)
                reloader=tui.Reloader(candidate,watch=False)
                pid=child.process.pid
                pending=model.pending_draft
                candidate.write_text(code.replace("self.box(r,'PENDING TOOL: PgUp/PgDn or Opt-Up/Dn')","self.box(r,'LIVE PENDING TOOL')"))
                reloader.request()
                self.assertTrue(reloader.check(terminal))
                self.assertIn('reloaded',model.notice)
                self.assertEqual(child.process.pid,pid)
                self.assertEqual(model.pending_draft,pending)
                self.assertEqual(model.approval_prompt,approval_prompt)
                self.assertEqual(len(Provider.plan),1)
            self.assertIsNone(terminal.mark_phase(0))
            for key in '/name racer\n':terminal.key(key)
            wait_for(lambda:model.config["identity"]=="racer")
            self.assertTrue(model.approval)
            self.assertEqual(model.approval_prompt,approval_prompt)
            self.assertEqual(model.pending_draft,("keep my next prompt",7))
            self.assertEqual(len(Provider.plan),1)
            for key in '/theme blueprint\n':terminal.key(key)
            wait_for(lambda:model.config["theme"]=="blueprint")
            for key in ('\t','\x17','\x0f'):terminal.key(key)
            self.assertTrue(model.approval)
            self.assertTrue(all(not group['diff'] for group in model.groups.values()))
            self.assertEqual(len(Provider.plan),1)
            for key in '/ui {"action":"patch","patch":{"accent":154}}\n':terminal.key(key)
            wait_for(lambda:model.config["accent"]==154)
            for key in '/ui {invalid}\n':terminal.key(key)
            self.assertIn('rejected',model.notice)
            self.assertTrue(model.approval)
            terminal.key('\x15')
            for key in '/mode nonsense\n':terminal.key(key)
            self.assertIn('use /mode manual|plan|autopilot',model.notice)
            self.assertTrue(model.approval)
            terminal.key('\x15')
            for key in '/mode autopilot\n':terminal.key(key)
            self.assertIn('Finish approval',model.notice)
            self.assertTrue(model.approval)
            self.assertEqual(model.session['mode'],'manual')
            self.assertEqual(len(Provider.plan),1)
            terminal.menu=False
            terminal.close_completion()
            terminal.key('\x1b')
            wait_for(lambda:model.ready)
            self.assertEqual((model.draft, model.cursor), ("keep my next prompt", 7))
            self.assertIn("tool unavailable", self.tool_results()[-1])
            self.assertEqual(model.approval_preview,'')
            self.assertNotIn('Tool requests:', '\n'.join(model.lines))
            self.assertNotIn('Approve tool?', '\n'.join(model.lines))
            terminal.key(tui.curses.KEY_BTAB)
            wait_for(lambda:model.session['mode']=='plan' and model.command_pending is None)
            self.assertEqual((model.draft,model.cursor),("keep my next prompt",7))
            self.assertEqual(len(Provider.plan),0)
        finally:
            child.close()

    def test_tui_model_tab_lists_and_selects_through_the_host_route(self):
        from tui_test import tui, terminal_view
        from unittest.mock import patch
        with patch.dict(os.environ, self.env):
            child = tui.Child(self.command()[1:] + ['--mode', 'autopilot'], cwd=self.project)
        model = tui.Model()
        terminal = terminal_view(40, 128, child); terminal.model = model
        def wait_for(predicate):
            end = time.monotonic() + 15
            while time.monotonic() < end:
                child.poll(model)
                if predicate(): return
                time.sleep(.02)
            self.fail(str(list(model.lines)) + ' ' + model.notice)
        try:
            wait_for(lambda: model.ready)
            self.assertEqual(model.session["provider"], "openai")
            for _ in range(3): terminal.key('\t')
            self.assertEqual(model.panel_tab, 'model')
            wait_for(lambda: model.command_pending is None); terminal.settle()
            wait_for(lambda: model.models["items"] == ["openai/fake", "openai/offline-fixture"] and model.command_pending is None)
            self.assertIn("2 models available", model.notice)
            terminal.draw()
            row = next(r for r, a in terminal.hits if a == ('model', 'openai/offline-fixture'))
            terminal.pointer(row.x + 3, row.y, 'press')
            wait_for(lambda: model.session.get("model") == "offline-fixture" and model.command_pending is None)
            self.assertIn("openai/offline-fixture", model.notice)
            terminal.draw()
            rendered = '\n'.join(terminal.screen.line(y) for y in range(40))
            self.assertIn('▶ openai/offline-fixture', rendered)
            self.assertIn('w | offline-fixture', rendered)
            child.ui({'action': 'session-command', 'command': '/model openai/x y', 'request_id': 99}); model.command_pending = 99
            wait_for(lambda: model.command_pending is None)
            self.assertIn("only /mode", model.notice)
            self.assertEqual(model.session.get("model"), "offline-fixture")
            Provider.plan = [answer("still here")]
            for key in 'hello\n': terminal.key(key)
            wait_for(lambda: model.ready and any('still here' in line for line in model.lines))
        finally:
            child.close()

    def test_tui_working_state_completes_errors_and_cancels(self):
        from tui_test import tui, terminal_view
        from unittest.mock import patch
        started=threading.Event();release=threading.Event()
        def delayed():
            started.set()
            release.wait(5)
            return answer("finished")
        with patch.dict(os.environ,self.env):
            child=tui.Child(self.command()[1:],cwd=self.project)
        terminal=terminal_view(child=child);model=terminal.model
        def wait_for(predicate):
            end=time.monotonic()+10
            while time.monotonic()<end:
                child.poll(model)
                if predicate():return
                time.sleep(.02)
            self.fail(str(list(model.lines)))
        try:
            wait_for(lambda:model.ready)
            for outcome in ('complete','error','cancel'):
                with self.subTest(outcome=outcome):
                    started.clear();release.clear()
                    Provider.plan=[PROVIDER_ERROR if outcome=='error' else delayed]
                    for key in 'hello\n':terminal.key(key)
                    self.assertEqual(terminal.mark_phase(0),0)
                    if outcome!='error':
                        wait_for(started.is_set)
                        self.assertEqual(model.status(),'WORKING')
                        if outcome=='cancel':
                            terminal.key('\x03')
                            self.assertIsNone(terminal.mark_phase(.25))
                        release.set()
                    wait_for(lambda:model.ready)
                    self.assertEqual(model.status(),'READY')
                    self.assertIsNone(terminal.mark_phase(.5))
                    if outcome=='cancel':
                        self.assertTrue(any('cancel' in line.lower() for line in model.lines))
        finally:
            release.set()
            child.close()

    def test_tui_structured_work_diff_and_transcript_are_real_ordered_events(self):
        from tui_test import tui, terminal_view
        from unittest.mock import patch
        class RecordingModel(tui.Model):
            def __init__(self):
                super().__init__()
                self.events=[]
            def event(self,event):
                self.events.append(event)
                super().event(event)
        intro="data: "+json.dumps({"choices":[{"index":0,"delta":{"content":"I will read, edit and check the file."}}]})+"\n\n"
        Provider.plan=[
            intro+tool_call("read",{"path":"notes.txt"}),
            self.edit_notes,
            tool_call("run",{"argv":["python3","-c","from pathlib import Path; assert '9443' in Path('notes.txt').read_text(); print('port check ok')"]}),
            answer("The source was updated and checked.",usage={"prompt_tokens":1234,"completion_tokens":12}),
        ]
        with patch.dict(os.environ,self.env):
            child=tui.Child(self.command()[1:]+['--mode','autopilot','--allow-run','python3'],cwd=self.project)
        model=RecordingModel()
        terminal=terminal_view(40,128,child);terminal.model=model
        def wait_for(predicate):
            end=time.monotonic()+15
            while time.monotonic()<end:
                child.poll(model)
                if predicate():return
                time.sleep(.02)
            self.fail(str(model.events[-12:]))
        try:
            wait_for(lambda:model.ready)
            for key in 'Update and check the port\n':terminal.key(key)
            wait_for(lambda:model.ready and model.receipt.get('status')=='ok')
            group=terminal.active_group()
            self.assertEqual([tool['name'] for tool in group['tools']],['read','edit','run'])
            self.assertEqual(len({tool['id'] for tool in group['tools']}),3)
            self.assertTrue(all(tool['result']['ok'] for tool in group['tools']))
            self.assertIn('-alpha port 8080',group['diff'])
            self.assertIn('+alpha port 9443',group['diff'])
            self.assertEqual((self.project/'notes.txt').read_text(),'alpha port 9443\n')
            self.assertEqual(model.receipt['runs'][0]['exit_code'],0)
            self.assertEqual(model.usage['prompt'],1234)
            user=[event['value']['text'] for event in model.events if event['type']=='transcript' and event['value']['role']=='user']
            self.assertEqual(user,['Update and check the port'])
            transcript='\n'.join(model.lines)+model.partial
            self.assertEqual(transcript.count('I will read, edit and check the file.'),1)
            self.assertEqual(transcript.count('The source was updated and checked.'),1)
            self.assertNotIn('tool> ',transcript)
            terminal.draw()
            rendered='\n'.join(terminal.screen.line(y) for y in range(40))
            self.assertIn('READ',rendered);self.assertIn('EDIT',rendered);self.assertIn('RUN',rendered)
            self.assertNotIn('PASS',rendered)
            run=next(event['value'] for event in model.events if event['type']=='tool-result' and event['value']['name']=='run')
            self.assertIn('port check ok',run['output']);self.assertFalse(run['truncated'])
            self.assertEqual(len(model.runs),1)
            model.panel_tab='log';terminal.draw()
            rendered='\n'.join(terminal.screen.line(y) for y in range(40))
            self.assertIn('port check ok',rendered);self.assertIn('exit 0',rendered)
            self.assertIn('python3 -c',rendered)
        finally:
            child.close()

    def test_tui_show_work_setting_hides_new_groups_without_losing_events(self):
        from tui_test import tui, terminal_view
        from unittest.mock import patch
        Provider.plan=[tool_call('read',{'path':'notes.txt'}),answer('quiet answer'),
                       tool_call('read',{'path':'notes.txt'}),answer('visible answer'),
                       tool_call('read',{'path':'notes.txt'}),answer('quiet again')]
        with patch.dict(os.environ,self.env):
            child=tui.Child(self.command()[1:]+['--mode','autopilot','--set','show-work=false'],cwd=self.project)
        terminal=terminal_view(40,128,child);model=terminal.model
        def wait_for(predicate):
            end=time.monotonic()+10
            while time.monotonic()<end:
                child.poll(model)
                if predicate():return
                time.sleep(.02)
            self.fail(str(model.session)+' '+str(list(model.lines)))
        try:
            wait_for(lambda:model.ready)
            self.assertIs(model.session.get('show_work'),False)
            for key in 'read quietly\n':terminal.key(key)
            wait_for(lambda:model.ready and model.receipt.get('turn')==1)
            first=terminal.active_group()
            self.assertFalse(first['visible'])
            self.assertEqual(first['tools'][0]['name'],'read')
            self.assertTrue(first['tools'][0]['result']['ok'])
            for key in '/work on\n':terminal.key(key)
            wait_for(lambda:model.ready and model.session.get('show_work') is True)
            for key in 'read visibly\n':terminal.key(key)
            wait_for(lambda:model.ready and model.receipt.get('turn')==2)
            second=terminal.active_group()
            self.assertTrue(second['visible'])
            self.assertFalse(first['visible'])
            for key in '/work off\n':terminal.key(key)
            wait_for(lambda:model.ready and model.session.get('show_work') is False)
            for key in 'read quietly again\n':terminal.key(key)
            wait_for(lambda:model.ready and model.receipt.get('turn')==3)
            self.assertFalse(terminal.active_group()['visible'])
            self.assertFalse(first['visible'])
            self.assertTrue(second['visible'])
            self.assertTrue(all(len(group['tools'])==1 for group in model.groups.values()))
        finally:
            child.close()

    def test_dirty_git_checkout_undo_reverts_only_shift_changes(self):
        (self.project / "theirs.txt").write_text("user work\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")
        (self.project / "theirs.txt").write_text("user work\nuser edit\n")
        out = self.shift("/mode autopilot\nchange the port\n/quit\n",
                         [self.edit_notes, tool_call("status", {}), answer("changed")])
        status = self.tool_results()[-1]
        self.assertIn("git ", status)
        self.assertIn("  notes.txt (+1 −1)", status)
        self.assertIn("dirty in git but not touched by shift: 1", status)
        self.assertIn("  theirs.txt", status)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 9443\n")
        out = self.shift("/undo\n/quit\n")
        self.assertIn("Undid turn 1: notes.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertEqual((self.project / "theirs.txt").read_text(), "user work\nuser edit\n")
        history = self.checkpoint()["history"]
        self.assertIn("The user ran /undo", history[-1]["content"])
        self.assertIn("Nothing to undo", self.shift("/undo\n/quit\n"))

    def test_non_git_project_edit_diff_status_and_undo(self):
        self.shift("/mode autopilot\nchange the port\n/quit\n",
                   [self.edit_notes, tool_call("diff", {"scope": "turn"}), tool_call("status", {}), answer("ok")])
        diff, status = self.tool_results()[-2:]
        self.assertIn("+alpha port 9443", diff)
        self.assertIn("1 file changed (+1 −1)", diff)
        self.assertIn("not a git repository", status)
        self.assertIn("changed this turn (turn 1): (+1 −1)", status)
        out = self.shift("/undo\n/quit\n")
        self.assertIn("Undid turn 1: notes.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        kinds = [entry["kind"] for entry in self.ledger()]
        self.assertEqual(kinds[-1], "undo")

    def test_patch_conflict_writes_nothing_and_the_turn_continues(self):
        bad = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-nope\n+x\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+created\n"
        self.shift("/mode autopilot\npatch it\n/quit\n", [tool_call("apply_patch", {"patch": bad}), answer("continued")])
        result = self.tool_results()[-1]
        self.assertIn("hunk 1 does not match notes.txt at line 1", result)
        self.assertIn('expected "nope", found "alpha port 8080"', result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertFalse((self.project / "new.txt").exists())
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint["next_turn"], 2)
        self.assertEqual(checkpoint["history"][-1]["content"], "continued")
        self.assertEqual([e for e in self.ledger() if e["kind"] == "change"], [])

    def test_stale_file_is_refused_before_approval(self):
        def rewrite_then_edit():
            (self.project / "notes.txt").write_text("alpha port 8080\nedited in an editor\n")
            return self.edit_notes

        out = self.shift("change the port\ny\n/quit\n",
                         [tool_call("read", {"path": "notes.txt"}), rewrite_then_edit, answer("ok")])
        self.assertEqual(out.count("Approve tool?"), 1, out)
        result = self.tool_results()[-1]
        self.assertIn("notes.txt changed on disk since turn 1", result)
        self.assertIn("read it again before editing", result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\nedited in an editor\n")

    def test_failing_run_is_reported_and_the_turn_is_checkpointed(self):
        self.shift("/mode manual\nrun tests\ny\n/quit\n",
                   [tool_call("run", {"argv": ["sh", "-c", "echo 1 test failed; exit 1"]}), answer("tests failed")])
        result = self.tool_results()[-1]
        self.assertIn("· exit 1 ·", result)
        self.assertIn("1 test failed", result)
        self.assertEqual(self.checkpoint()["next_turn"], 2)
        runs = [e for e in self.ledger() if e["kind"] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertFalse(runs[0]["outcome"]["success"])
        self.assertEqual(runs[0]["outcome"]["exit_code"], 1)
        self.assertEqual(runs[0]["outcome"]["output_sha256"], sha256("1 test failed\n"))
        self.assertTrue((self.state() / runs[0]["log"]).exists())

    def test_cancelled_run_reaps_the_child_and_keeps_history(self):
        marker = "61.73"
        Provider.plan = [tool_call("run", {"argv": ["sleep", marker]}), answer("never")]
        process = subprocess.Popen(
            self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, cwd=self.project, env=self.env,
        )
        process.stdin.write("/mode manual\nrun it\ny\n")
        process.stdin.flush()
        deadline = time.time() + 15
        while time.time() < deadline:
            if subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode == 0:
                break
            time.sleep(0.1)
        else:
            process.kill()
            self.fail("the sleep child never started")
        os.kill(process.pid, signal.SIGINT)
        process.stdin.write("/quit\n")
        process.stdin.flush()
        out, _ = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, out)
        self.assertIn("turn cancelled; conversation state is unchanged.", out)
        time.sleep(0.5)
        self.assertNotEqual(
            subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode, 0,
            "the child outlived the cancelled turn",
        )
        spans = [json.loads(line) for line in (self.state() / "traces.jsonl").read_text().splitlines()]
        self.assertIn(("tool.run", "CANCELLED"), [(s["name"], s["status"]) for s in spans])
        self.assertEqual(self.checkpoint()["history"], [])
        self.assertEqual([e["kind"] for e in self.ledger() if e["kind"] == "run"], [])

    def test_interrupted_mutation_is_restored_from_the_pre_image(self):
        self.shift("/mode autopilot\nchange the port\n/quit\n", [self.edit_notes, answer("ok")])
        before = "alpha port 9443\n"
        crashed = "alpha port 1\n"
        self.assertEqual((self.project / "notes.txt").read_text(), before)
        # Simulate death between the write-ahead entry and its commit: the file
        # already carries the post-image, the ledger still says started.
        (self.project / "notes.txt").write_text(crashed)
        entry = {
            "kind": "change", "seq": 2, "turn": 2, "call_id": "call_edit", "tool": "edit",
            "path": "notes.txt", "before": sha256(before), "after": sha256(crashed),
            "state": "started", "at": "2026-09-08T00:00:00Z",
        }
        with (self.state() / "changes.jsonl").open("a") as ledger:
            ledger.write(json.dumps(entry) + "\n")
        (self.state() / "interrupted-tool.json").write_text(json.dumps({
            "version": 1, "state": "execution-started", "tool": "edit",
            "arguments": {"path": "notes.txt", "old_text": "9443", "new_text": "1"},
            "generation_id": 1, "created_at": "2026-09-08T00:00:00Z",
        }) + "\n")
        out = self.shift("/recover\n/recover restore\n/quit\n")
        self.assertIn("interrupted tool record found", out)
        self.assertIn("notes.txt (turn 2, edit)", out)
        self.assertIn("matches after; /recover restore puts the pre-image back", out)
        self.assertIn("notes.txt: restored from the pre-image", out)
        self.assertIn("recovery record cleared", out)
        self.assertEqual((self.project / "notes.txt").read_text(), before)
        self.assertFalse((self.state() / "interrupted-tool.json").exists())
        self.assertIn("No interrupted tool call is pending", self.shift("/recover\n/quit\n"))

    def test_undo_refuses_when_a_changed_file_diverged(self):
        (self.project / "second.txt").write_text("alpha\n")
        patch = ("--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-alpha port 8080\n+alpha port 9443\n"
                 "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1,2 @@\n alpha\n+beta\n")
        self.shift("/mode autopilot\npatch\n/quit\n", [tool_call("apply_patch", {"patch": patch}), answer("ok")])
        self.assertEqual((self.project / "second.txt").read_text(), "alpha\nbeta\n")
        (self.project / "second.txt").write_text("alpha\nbeta\nuser addition\n")
        out = self.shift("/undo\n/quit\n")
        self.assertIn("cannot undo turn 1", out)
        self.assertIn("second.txt", out)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 9443\n")
        self.assertEqual((self.project / "second.txt").read_text(), "alpha\nbeta\nuser addition\n")
        self.assertEqual([e for e in self.ledger() if e["kind"] == "undo"], [])


    def test_print_mode_answers_once_with_a_clean_stdout(self):
        code, out, err = self.print_mode("say hi", [answer("hello there")])
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "hello there\n")
        self.assertNotIn("shift λ", out)
        self.assertIn("Session closed", err)
        self.assertEqual(self.checkpoint("p")["next_turn"], 2)

    def test_print_mode_exit_codes_and_flags(self):
        code, out, err = self.print_mode("fail", [PROVIDER_ERROR])
        self.assertEqual(code, 1)
        self.assertIn("turn failed", err)
        code, out, err = self.print_mode("bad mode", [answer("x")], "--mode", "sideways")
        self.assertEqual(code, 2)
        self.assertIn("startup options rejected", err)
        code, out, err = self.print_mode("bad set", [answer("x")], "--set", "agent-max-tool-rounds=99")
        self.assertEqual(code, 2)
        code, out, err = self.print_mode("bad json", [answer("x")], "--set", "turn-token-budget=notjson")
        self.assertEqual(code, 2)
        result = subprocess.run([BIN, "--agent", str(self.agent), "--print"], text=True,
                                capture_output=True, cwd=self.project, env=self.env)
        self.assertEqual(result.returncode, 2)

    def test_print_mode_allow_run_executes_without_a_prompt(self):
        code, out, err = self.print_mode(
            "run it", [tool_call("run", {"argv": ["sh", "-c", "echo ran"]}), answer("ok")],
            "--mode", "autopilot", "--allow-run", "sh -c", "--allow-run", "make check")
        self.assertEqual(code, 0, err)
        self.assertNotIn("Approve", out + err)
        self.assertIn("· exit 0 ·", self.tool_results()[-1])
        settings = json.loads((self.state("p") / "settings.json").read_text())
        self.assertEqual(settings["run-allow"], [["sh", "-c"], ["make", "check"]])
        self.assertEqual(settings["mode"], "autopilot")

    def test_print_mode_denies_runs_that_are_not_allowlisted(self):
        code, out, err = self.print_mode(
            "run it", [tool_call("run", {"argv": ["sh", "-c", "echo ran"]}), answer("ok")],
            "--mode", "manual")
        self.assertEqual(code, 0, err)
        self.assertIn("tool unavailable in this turn: run", self.tool_results()[-1])
        code, out, err = self.print_mode(
            "run it", [tool_call("run", {"argv": ["sh", "-c", "echo ran"]}), answer("ok")],
            "--mode", "autopilot", session="p2")
        self.assertEqual(code, 0, err)
        self.assertIn("ran", self.tool_results()[-1])

    def test_round_limit_and_token_budget_end_the_turn_with_a_reason(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("loop", [read, read, answer("never")],
                                         "--mode", "autopilot", "--set", "agent-max-tool-rounds=1")
        self.assertEqual(code, 1)
        self.assertIn("tool round limit reached", err)
        spent = tool_call("read", {"path": "notes.txt"}, usage={"prompt_tokens": 5000, "completion_tokens": 20})
        code, out, err = self.print_mode("spend", [spent, answer("never")],
                                         "--mode", "autopilot", "--set", "turn-token-budget=2048", session="b")
        self.assertEqual(code, 1)
        self.assertIn("turn token budget exceeded", err)
        journal = (self.state("b") / "events.scm-log").read_text()
        self.assertIn("turn-limit", journal)
        self.assertIn("(reason . tokens)", journal)
        self.assertEqual(self.checkpoint("b")["history"], [])

    def test_context_estimate_calibrates_later_rounds_but_not_the_next_turn(self):
        (self.project / "notes.txt").write_text("value = 1\n" * 6000)
        (self.project / ".shift").mkdir()
        (self.project / ".shift/settings.json").write_text(json.dumps({
            "context-limit": 131072, "output-reserve": 8192,
        }))
        # The initial request fits, but bytes/3 puts the read result over the
        # guard. The provider's 73k count leaves room at this same window.
        output = self.shift(
            "/mode plan\n" + "code " * 50000 + "\n/context\nnext turn\n/quit\n",
            [tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 73000, "completion_tokens": 5}),
             answer("CALIBRATED_OK", usage={"prompt_tokens": 88000, "completion_tokens": 5}),
             answer("MUST_NOT_REUSE_CALIBRATION")],
        )
        self.assertIn("CALIBRATED_OK", output)
        self.assertNotIn("MUST_NOT_REUSE_CALIBRATION", output)
        self.assertTrue(any(m["role"] == "tool" for m in Provider.last_messages),
                        "the answer must finish the original tool chain")
        self.assertEqual(len(Provider.plan), 1, "the next turn must use its own estimate")
        self.assertIn("current turn is too large to compact safely", output)
        self.assertEqual(self.checkpoint()["next_turn"], 2)

    def test_context_calibration_uses_latest_usage_without_compounding(self):
        (self.project / "notes.txt").write_text("value = 1\n" * 6000)
        (self.project / ".shift").mkdir()
        (self.project / ".shift/settings.json").write_text(json.dumps({
            "context-limit": 131072, "output-reserve": 8192,
        }))
        # Reusing the first ratio, or dividing by the calibrated second
        # estimate, would incorrectly reject the third request.
        output = self.shift(
            "/mode plan\n" + "code " * 50000 + "\n/quit\n",
            [tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 73000, "completion_tokens": 5}),
             tool_call("read", {"path": "notes.txt"},
                       usage={"prompt_tokens": 78000, "completion_tokens": 5}),
             answer("LATEST_USAGE_OK", usage={"prompt_tokens": 93000, "completion_tokens": 5})],
        )
        self.assertIn("LATEST_USAGE_OK", output)
        self.assertNotIn("Context budget exceeded", output)
        self.assertEqual(len(self.tool_results()), 2)
        self.assertEqual(self.checkpoint()["next_turn"], 2)

    def test_show_work_covers_tool_echo_and_the_receipt(self):
        plan = [tool_call("read", {"path": "notes.txt"}), answer("seen")]
        code, out, err = self.print_mode("look", plan, "--mode", "autopilot")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "seen\n")
        self.assertIn("tool> read notes.txt", err)
        self.assertIn("✓ # notes.txt · 16 bytes · sha256", err)
        code, out, err = self.print_mode("look", plan, session="manual")
        self.assertEqual(out, "seen\n", "manual mode must deny without prompting in print mode")
        self.assertNotIn("Approve", out + err)
        self.assertIn("✗ tool unavailable in this turn: read", err)
        self.assertIn("turn 1 · fake · generation 1", err)
        code, out, err = self.print_mode("look", plan, "--mode", "autopilot", "--set", "show-work=false",
                                         "--receipt", str(self.project / "quiet.json"), session="quiet")
        self.assertEqual(out, "seen\n")
        self.assertNotIn("tool>", err)
        self.assertNotIn("turn 1 ·", err, "show-work off hides the receipt text too")
        self.assertEqual(len(self.receipts("quiet")), 1, "the receipt is still recorded")
        self.assertEqual(json.loads((self.project / "quiet.json").read_text())["status"], "ok")
        out = self.shift("/mode autopilot\n/work off\n/tools\nlook\n/receipt\n/quit\n", plan, session="repl")
        self.assertIn("tools read rg skill write edit apply_patch status diff run job tool_search · show-work off", out)
        self.assertNotIn("tool>", out)
        self.assertEqual(out.count("turn 1 · fake"), 1, "/receipt still shows it on request")
        out = self.shift("/work on\nlook\n/quit\n", plan, session="repl")
        self.assertIn("tool> read notes.txt", out)
        self.assertIn("turn 2 · fake · generation 1", out)

    def test_malformed_tool_arguments_fail_the_call_not_the_turn(self):
        call = {"index": 0, "id": "call_bad", "type": "function",
                "function": {"name": "edit", "arguments": '{"path":"notes.txt","old_text":"unterminated'}}
        bad = sse([{"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]},
                   {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}])
        code, out, err = self.print_mode("edit it", [bad, answer("retrying")], "--mode", "autopilot")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "retrying\n")
        result = self.tool_results()[-1]
        self.assertIn("were not a valid JSON object", result)
        self.assertIn("nothing ran", result)
        self.assertEqual((self.project / "notes.txt").read_text(), "alpha port 8080\n")
        self.assertIn("tool-arguments-invalid", (self.state("p") / "events.scm-log").read_text())

    def receipts(self, session="p"):
        path = self.state(session) / "receipts.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def turn_span(self, session="p"):
        for line in (self.state(session) / "traces.jsonl").read_text().splitlines():
            span = json.loads(line)
            if span["name"] == "agent.turn":
                return span
        self.fail("no agent.turn span")

    def test_skills_are_indexed_loaded_and_receipted(self):
        skill = self.project / ".agents/skills/greet"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("---\nname: greet\ndescription: Greet politely\n---\nAlways start with hello.\n")
        (skill / "extra.md").write_text("supporting file\n")
        (self.project / ".agents/skills/hidden").mkdir()
        (self.project / ".agents/skills/hidden/SKILL.md").write_text(
            "---\nname: hidden\ndescription: User only\ndisable-model-invocation: true\n---\nquiet\n")
        output = self.shift(
            "/mode autopilot\nsay hi\n/skills\n/quit\n",
            plan=[tool_call("skill", {"name": "greet"}), tool_call("read", {"path": str(skill / "extra.md")}),
                  tool_call("skill", {"name": "hidden"}), answer("hello")],
        )
        system = Provider.last_messages[0]["content"]
        self.assertIn("<skills>", system)
        self.assertIn("- greet: Greet politely", system)
        self.assertNotIn("hidden", system)
        results = self.tool_results()
        self.assertIn("Always start with hello.", results[0])
        self.assertIn("supporting file", results[1])
        self.assertIn("user-only", results[2])
        self.assertIn("loaded  greet  agents  Greet politely", output)
        self.assertIn("        hidden  agents  User only", output)
        receipt = json.loads((self.state() / "receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual(receipt["skills"], ["greet"])
        # A user-queued skill rides along with the next prompt and is receipted too.
        self.shift("/skill hidden\nnext task\n/quit\n", plan=[answer("ok")])
        user = [m for m in Provider.last_messages if m.get("role") == "user"][-1]["content"]
        self.assertTrue(user.startswith('<skill name="hidden">\nSkill hidden (') and user.endswith('quiet\n</skill>\n\nnext task'), user)
        receipt = json.loads((self.state() / "receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual(receipt["skills"], ["hidden"])

    def test_background_jobs_return_at_once_and_report_back(self):
        output = self.shift(
            "/mode autopilot\nrun the suite\n/jobs\n/quit\n",
            plan=[tool_call("run", {"argv": ["sh", "-c", "echo started; sleep 0.2; echo finished"], "background": True}),
                  tool_call("read", {"path": "notes.txt"}),
                  tool_call("job", {"action": "wait", "id": "job-1", "timeout_seconds": 10}),
                  answer("done")],
        )
        results = self.tool_results()
        self.assertIn("started as job-1", results[0])
        self.assertIn("exit 0", results[2])
        self.assertIn("finished", results[2])
        # Two parallel-safe reads in one round come back in the model's order and are traced as parallel.
        self.assertIn("job-1  exit", output)
        receipt = json.loads((self.state() / "receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual([run["status"] for run in receipt["runs"]], ["exit"])
        self.assertTrue(any("Note from the harness: job job-1 finished" in m.get("content", "")
                            for m in Provider.last_messages if m.get("role") == "user")
                        or "exit 0" in results[2])

    def test_allow_run_persists_per_scope_and_skips_the_prompt(self):
        output = self.shift(
            '/allow-run "sh -c" project\n/allow-run\nrun it\n/quit\n',
            plan=[tool_call("run", {"argv": ["sh", "-c", "echo allowed"]}), answer("done")],
        )
        self.assertIn("Allowed project: sh -c", output)
        self.assertIn("project  sh -c", output)
        self.assertIn("allowed", self.tool_results()[0])
        settings = json.loads((self.project / ".shift/settings.json").read_text())
        self.assertEqual(settings["run-allow"], [["sh", "-c"]])
        session_file = self.state() / "settings.json"
        self.assertFalse(session_file.exists() and json.loads(session_file.read_text()).get("run-allow"))

    def test_mcp_tools_are_found_by_search_and_gated_by_policy(self):
        fake = ROOT / "test/fake_mcp_server.py"
        (self.project / ".shift").mkdir(exist_ok=True)
        (self.project / ".shift/mcp.scm").write_text('((server "fake" (command "python3" "%s")))\n' % fake)
        output = self.shift(
            "/mode autopilot\nping the server\n/mcp\n/quit\n",
            plan=[tool_call("fake__ping", {}), tool_call("tool_search", {"query": "pong"}),
                  tool_call("fake__ping", {}), answer("done")],
        )
        system = Provider.last_messages[0]["content"]
        self.assertIn("<mcp_servers>", system)
        self.assertIn("- fake", system)          # lazy: no description before the first connection
        self.assertNotIn("pong", system)
        results = self.tool_results()
        self.assertIn("tool unavailable", results[0])          # not searched yet
        self.assertIn("Enabled for this turn: fake__ping", results[1])
        self.assertEqual(results[2], "pong")
        self.assertIn("fake  connected  stdio  3 tools", output)
        receipt = json.loads((self.state() / "receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual(receipt["mcp_tools"], ["fake__ping"])
        # Plan mode: the read-only tool runs, the mutating one is denied.
        self.shift(
            "/mode plan\nagain\n/quit\n",
            plan=[tool_call("tool_search", {"query": "select:fake__ping,fake__write_note"}),
                  tool_call("fake__ping", {}), tool_call("fake__write_note", {"text": "x"}), answer("done")],
        )
        results = self.tool_results()[-3:]      # the resumed history carries turn one's tool messages too
        self.assertEqual(results[1], "pong")
        self.assertIn("tool unavailable", results[2])
        # Manual mode with a project allowlist entry: echo runs without a prompt.
        output = self.shift(
            '/mode manual\n/allow-mcp fake__echo project\nagain\ny\n/quit\n',   # y approves tool_search; echo is allowlisted
            plan=[tool_call("tool_search", {"query": "select:fake__echo"}), tool_call("fake__echo", {"text": "hi"}), answer("done")],
        )
        self.assertIn("Allowed project: fake__echo", output)
        self.assertEqual(self.tool_results()[-1], "echo: hi")
        self.assertEqual(json.loads((self.project / ".shift/settings.json").read_text())["mcp-allow"], ["fake__echo"])

    def judge_says(self, verdict, rule="ok", reason="fine"):
        return ("judge", answer(json.dumps({"verdict": verdict, "rule": rule, "reason": reason})))

    def test_autopilot_resolves_rules_then_asks_the_judge(self):
        # The judge shares the fake provider, so its answers sit in the plan between tool calls.
        output = self.shift(
            "/mode autopilot\n/judge on\nchange the port and clean up\n/judge\n/quit\n",
            plan=[self.edit_notes, self.judge_says("allow"),
                  tool_call("run", {"argv": ["git", "reset", "--hard"]}),
                  tool_call("run", {"argv": ["git", "push", "origin", "main"]}), self.judge_says("block", "escalation", "the request did not ask to push"),
                  tool_call("read", {"path": "notes.txt"}),
                  answer("done")],
        )
        results = self.tool_results()
        self.assertIn("notes.txt", results[0])                                  # judged allow
        self.assertIn("blocked by autopilot [discards-work]", results[1])       # fixed rule, no judge call
        self.assertIn("blocked by autopilot [escalation]", results[2])          # judge block, rule read back
        self.assertIn("the request did not ask to push", results[2])
        self.assertIn("alpha port 9443", results[3])                            # reads never wait on the judge
        self.assertIn("judge on · model openai/fake", output)
        self.assertIn("2 judged, 2 blocked", output)
        receipt = json.loads((self.state() / "receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual((receipt["judged"], receipt["blocked"]), (2, 2))
        judge_log = (self.state() / "judge.jsonl").read_text().splitlines()
        self.assertEqual([json.loads(l)["verdict"] for l in judge_log], ["allow", "block"])
        # A judge that fails to answer is a block, and three in a row pause autopilot into asking.
        Provider.plan = []
        output = self.shift(
            "again\n/quit\n",
            plan=[tool_call("run", {"argv": ["make", "a"]}), ("judge", PROVIDER_ERROR),
                  tool_call("run", {"argv": ["make", "b"]}), ("judge", PROVIDER_ERROR),
                  tool_call("run", {"argv": ["make", "c"]}), ("judge", PROVIDER_ERROR),
                  tool_call("run", {"argv": ["make", "d"]}),
                  answer("done")],
        )
        results = self.tool_results()[-4:]
        self.assertTrue(all("blocked by autopilot [judge-unavailable]" in r for r in results[:3]), results)
        self.assertIn("tool unavailable", results[3])          # paused: manual asks, and piped stdin says no
        self.assertIn("autopilot paused after repeated blocks", output)
        # With the judge off, autopilot no longer allows everything: unjudged actions ask.
        self.shift("/judge off\nagain\n/quit\n", plan=[tool_call("write", {"path": "z.txt", "content": "x\n"}), answer("done")])
        self.assertIn("tool unavailable", self.tool_results()[-1])
        self.assertFalse((self.project / "z.txt").exists())

    def test_shadow_judge_records_beside_the_human_answer(self):
        output = self.shift(
            "/judge shadow\nchange the port\ny\n/judge report\n/quit\n",
            plan=[self.edit_notes, self.judge_says("block", "escalation", "not asked for"), answer("done")],
        )
        self.assertIn("judge would block [escalation]", output)
        self.assertIn("notes.txt", self.tool_results()[0])     # the human said yes; shadow never blocks
        record = json.loads((self.state() / "judge.jsonl").read_text().splitlines()[-1])
        self.assertEqual((record["verdict"], record["human"]), ("block", "allow"))
        self.assertIn("1 decisions, 1 beside a human answer, 0 agreed (0%)", output)
        self.assertIn("Would have blocked what you allowed:", output)

    def test_sandboxed_runs_skip_the_prompt_and_host_prefixes_do_not(self):
        fakebin = self.project / "fakebin"
        fakebin.mkdir()
        (fakebin / "agentkernel").write_text("#!/bin/sh\n# exec SANDBOX --workdir DIR -- ARGV: run ARGV here and mark it\n"
                                            "while [ \"$1\" != \"--\" ]; do shift; done; shift\necho \"[sandbox] $*\"\n")
        (fakebin / "agentkernel").chmod(0o755)
        self.env["PATH"] = str(fakebin) + ":" + self.env["PATH"]
        output = self.shift(
            "/sandbox box\n/sandbox\nrun both\n/quit\n",
            plan=[tool_call("run", {"argv": ["cargo", "test"]}), tool_call("run", {"argv": ["git", "status"]}), answer("done")],
        )
        self.assertIn("runs: agentkernel sandbox box", output)
        self.assertIn("host prefixes: git, cargo tauri", output)
        results = self.tool_results()
        self.assertIn("[sandbox] cargo test", results[0])          # manual mode, no prompt: the sandbox is the boundary
        self.assertIn("tool unavailable", results[1])              # git is a host prefix, so manual asked and stdin said no
        # Autopilot: a sandboxed run never reaches the judge.
        before = Provider.judge_requests
        self.shift("/mode autopilot\nagain\n/quit\n", plan=[tool_call("run", {"argv": ["make", "check"]}), answer("done")])
        self.assertIn("[sandbox] make check", self.tool_results()[-1])
        self.assertEqual(Provider.judge_requests, before)
        self.shift("/sandbox off\n/quit\n")

    def test_parallel_reads_keep_their_order_and_trace_it(self):
        (self.project / "b.txt").write_text("bravo\n")
        Provider.plan = []
        self.shift(
            "/mode autopilot\nread both\n/quit\n",
            plan=[sse([{"choices": [{"index": 0, "delta": {"tool_calls": [
                        {"index": 0, "id": "call_a", "type": "function", "function": {"name": "read", "arguments": json.dumps({"path": "notes.txt"})}},
                        {"index": 1, "id": "call_b", "type": "function", "function": {"name": "read", "arguments": json.dumps({"path": "b.txt"})}}]}}]},
                       {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}]),
                  answer("done")],
        )
        tools = [m for m in Provider.last_messages if m.get("role") == "tool"]
        self.assertEqual([m["tool_call_id"] for m in tools], ["call_a", "call_b"])
        self.assertIn("alpha port 8080", tools[0]["content"])
        self.assertIn("bravo", tools[1]["content"])
        traces = (self.state() / "traces.jsonl").read_text()
        self.assertEqual(traces.count('"tool.parallel":true'), 2)

    def test_receipt_reports_the_turn_in_every_form(self):
        cached = {"prompt_tokens": 1200, "completion_tokens": 30, "prompt_tokens_details": {"cached_tokens": 1000}}
        plan = [tool_call("edit", {"path": "notes.txt", "old_text": "8080", "new_text": "9443"}, usage=cached),
                tool_call("run", {"argv": ["sh", "-c", "echo ran; exit 3"]}, usage={"prompt_tokens": 1500, "completion_tokens": 20}),
                answer("done", usage={"prompt_tokens": 1600, "completion_tokens": 5})]
        receipt_file = self.project / "receipt.json"
        code, out, err = self.print_mode("edit and run", plan, "--mode", "autopilot", "--allow-run", "sh -c",
                                         "--receipt", str(receipt_file))
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "done\n", "the receipt must not touch stdout")
        self.assertIn("turn 1 · fake · generation 1 · 3 rounds · 4,300 in (1,000 cached) + 55 out", err)
        self.assertIn("changed  notes.txt (+1 −1)", err)
        self.assertIn("ran      sh -c echo ran; exit 3  exit 3", err)
        self.assertIn("undo     available (/undo)", err)
        self.assertIn("resume ./bin/shift --resume p", err)
        (receipt,) = self.receipts()
        self.assertEqual(json.loads(receipt_file.read_text()), receipt)
        self.assertEqual(receipt["status"], "ok")
        self.assertEqual(receipt["tokens"], {"prompt": 4300, "cached": 1000, "uncached": 3300, "completion": 55})
        self.assertEqual(receipt["tool_calls"], {"edit": 1, "run": 1})
        self.assertEqual([c["path"] for c in receipt["changed"]], ["notes.txt"])
        self.assertEqual((receipt["changed"][0]["added"], receipt["changed"][0]["removed"]), (1, 1))
        self.assertEqual(receipt["changed"][0]["after"], sha256("alpha port 9443\n"))
        self.assertEqual(receipt["runs"][0]["command"], ["sh", "-c", "echo ran; exit 3"])
        self.assertEqual((receipt["runs"][0]["exit_code"], receipt["runs"][0]["success"]), (3, False))
        self.assertTrue(receipt["undo"])
        span = self.turn_span()
        self.assertEqual(receipt["trace_id"], span["trace_id"])
        self.assertEqual(receipt["span_id"], span["span_id"])
        self.assertEqual(span["attributes"]["receipt.files"], "notes.txt")
        self.assertEqual(span["attributes"]["receipt.runs_failed"], 1)
        self.assertEqual(span["attributes"]["receipt.tokens.cached"], 1000)
        out = self.shift("/receipt\n/quit\n", [], session="p")
        self.assertIn("turn 1 · fake · generation 1 · 3 rounds", out, "/receipt reads the last record of a resumed session")
        self.assertIn("changed  notes.txt (+1 −1)", out)

    def test_failed_and_cancelled_turns_still_get_a_receipt(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("loop", [self.edit_notes, read, read, answer("never")],
                                         "--mode", "autopilot", "--set", "agent-max-tool-rounds=2")
        self.assertEqual(code, 1)
        self.assertIn("status   failed · tool round limit reached", err)
        self.assertIn("changed  notes.txt (+1 −1)", err)
        (receipt,) = self.receipts()
        self.assertEqual(receipt["status"], "failed")
        self.assertIn("round limit", receipt["error"])
        self.assertEqual(receipt["tool_calls"], {"edit": 1, "read": 1})
        self.assertTrue(receipt["undo"], "changes a failed turn committed stay undoable")
        self.assertEqual(self.turn_span()["attributes"]["receipt.status"], "failed")
        code, out, err = self.print_mode("no turn", [answer("x")], "--receipt", str(self.project / "missing" / "r.json"),
                                         session="unwritable")
        self.assertEqual(code, 0, "a receipt that cannot be written never fails the turn")
        self.assertIn("receipt not written", err)
        self.assertEqual(len(self.receipts("unwritable")), 1)

    def llm_spans(self, session="p"):
        return [json.loads(line) for line in (self.state(session) / "traces.jsonl").read_text().splitlines()
                if '"kind":"LLM"' in line]

    def test_provider_errors_are_retried_with_backoff_and_recorded(self):
        started = time.time()
        code, out, err = self.print_mode("hi", [RATE_LIMITED, PROVIDER_ERROR, answer("ok")],
                                         "--set", "provider-retries=3")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "ok\n")
        self.assertGreaterEqual(time.time() - started, 3, "1s Retry-After then 2s backoff")
        self.assertIn("provider 429 · retrying in 1.0s (attempt 2 of 4)", err)
        self.assertIn("provider 503 · retrying in 2.0s (attempt 3 of 4)", err)
        (span,) = self.llm_spans()
        self.assertEqual(span["attributes"]["llm.retries"], 2)
        self.assertEqual(span["attributes"]["llm.retry_log"], "429@1.0s,503@2.0s")
        code, out, err = self.print_mode("hi", [PROVIDER_ERROR, answer("never")], session="none")
        self.assertEqual(code, 1, "provider-retries=0 fails on the first error")
        self.assertIn("provider request failed after retries", err)
        self.assertNotIn("retrying", err)
        code, out, err = self.print_mode("hi", [PROVIDER_ERROR, PROVIDER_ERROR, answer("never")],
                                         "--set", "provider-retries=1", session="one")
        self.assertEqual(code, 1, "the limit is honoured")
        self.assertEqual(err.count("retrying"), 1)
        (span,) = self.llm_spans("one")
        self.assertEqual(span["attributes"]["llm.retries"], 1)

    def test_limit_nudge_asks_the_model_to_finish_once_and_is_not_persisted(self):
        read = tool_call("read", {"path": "notes.txt"})
        code, out, err = self.print_mode("look", [read, read, answer("done")],
                                         "--mode", "autopilot", "--set", "agent-max-tool-rounds=5")
        self.assertEqual(code, 0, err)
        self.assertIn("shift> 3 tool rounds remain in this turn; asked the model to finish", err)
        last = Provider.last_messages[-1]
        self.assertEqual(last["role"], "user")
        self.assertIn("3 tool rounds remain", last["content"])
        self.assertNotIn("ephemeral", last, "the marker never reaches the provider")
        self.assertEqual(Provider.last_messages[-2]["role"], "tool")
        history = json.dumps(self.checkpoint("p")["history"])
        self.assertNotIn("rounds remain", history, "the nudge is not persisted")
        self.assertIn("read result", history.lower() if "read result" in history.lower() else "read result")
        self.assertIn("turn-nudge", (self.state("p") / "events.scm-log").read_text())
        spent = tool_call("read", {"path": "notes.txt"}, usage={"prompt_tokens": 900, "completion_tokens": 10})
        code, out, err = self.print_mode("spend", [spent, read, answer("done")], "--mode", "autopilot",
                                         "--set", "turn-token-budget=1024", session="budget")
        self.assertEqual(code, 0, err)
        self.assertIn("token budget is 89% spent; asked the model to finish", err)
        self.assertEqual(err.count("asked the model to finish"), 1, "nudged once per turn")

    def test_model_flag_selects_a_provider(self):
        code, out, err = self.print_mode("hi", [answer("x")], "--model", "openai/gpt-5.4-mini")
        settings = json.loads((self.state("p") / "settings.json").read_text())
        self.assertEqual(settings["agent-model"], "gpt-5.4-mini")
        self.assertEqual(settings["agent-provider"], "openai")


class RunListSource(unittest.TestCase):
    def invoke(self, project, commands):
        result = subprocess.run(
            [str(ROOT / "bin/shift"), "--agent", str(ROOT / "test/session-agent.scm"),
             "--no-watch", "--no-mcp", "--session", "check"],
            cwd=project, input=commands + "\n/quit\n", capture_output=True, text=True, timeout=20,
            env={**os.environ, "XDG_CONFIG_HOME": str(project / "config"), "GUILE_AUTO_COMPILE": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def seed(self, path, prefixes):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"run-allow": prefixes}))

    def test_scopes_union_and_list_with_their_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            output = self.invoke(project, "/run list")
            self.assertIn("Run allowlist is empty (default)", output)
            self.assertIn("/allow-run", output)
            self.seed(project / "config/shift/settings.json", [["git", "status"]])
            self.seed(project / ".shift/settings.json", [["make", "test"]])
            self.seed(project / ".shift/sessions/check/settings.json", [["cargo", "test"]])
            output = self.invoke(project, "/run list")
            rows = [line for line in output.splitlines() if line.startswith("allow ")]
            self.assertEqual(rows, ["allow git status (user)", "allow make test (project)", "allow cargo test (session)"])

    def test_terminal_changes_persist_at_their_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            self.seed(project / ".shift/settings.json", [["make", "test"]])
            output = self.invoke(project, "/run allow cargo test\n/run list")
            self.assertIn("allow make test (project)", output)
            self.assertIn("allow cargo test (session)", output)
            output = self.invoke(project, "/run deny make test\n/run list")
            self.assertIn("Removed from project: make test", output)
            rows = [line for line in output.splitlines() if line.startswith("allow ")]
            self.assertEqual(rows, ["allow cargo test (session)"])
            self.assertEqual(json.loads((project / ".shift/settings.json").read_text())["run-allow"], [])
            saved = json.loads((project / ".shift/sessions/check/settings.json").read_text())
            self.assertEqual(saved["run-allow"], [["cargo", "test"]])
            output = self.invoke(project, '/allow-run "npm test" user\n/run list')
            self.assertIn("allow npm test (user)", output)
            self.assertEqual(json.loads((project / "config/shift/settings.json").read_text())["run-allow"], [["npm", "test"]])



if __name__ == "__main__":
    unittest.main()
