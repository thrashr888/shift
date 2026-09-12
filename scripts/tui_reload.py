"""Validated local presentation swaps; the running host and Guile child stay put."""
import ast
import copy
import hashlib
import sys
import time
import types
from pathlib import Path
from tui_identity import identity


# Host lifecycle, model/event protocol, initialization and authority stay frozen.
HELPERS = {'suggestions', 'cell_width', 'clip', 'wrap', 'composer_view', 'layout'}
METHODS = {
    'put', 'mark_phase', 'brand_line', 'paint_marks', 'border_glyphs', 'box', 'rule',
    'spans', 'metadata', 'header', 'body_rows', 'inspector', 'draw', 'tabs',
    'diff_rows', 'framed_diff', 'group_rows', 'active_group', 'telemetry', 'telemetry_notes', 'meter',
    'qdos_header', 'hit', 'button', 'contains',
    'completion', 'close_completion', 'open_palette', 'accept_completion',
    'pointer', 'mouse', 'read_key', 'key',
}


def contract(source):
    tree = ast.parse(source)
    for node in tree.body:
        terminal = isinstance(node, ast.ClassDef) and node.name == 'Terminal'
        candidates = node.body if terminal else [node]
        allowed = METHODS if terminal else HELPERS
        for function in candidates:
            if isinstance(function, ast.FunctionDef) and function.name in allowed:
                function.body = [ast.Pass()]
    return ast.dump(tree, include_attributes=False)


class PreviewScreen:
    def __init__(self, size):
        self.size = size

    def getmaxyx(self):
        return self.size

    def erase(self):
        pass

    def clearok(self, flag):
        pass

    def move(self, *args):
        pass

    def refresh(self):
        pass


class NoRequests:
    def __getattr__(self, name):
        raise ValueError('presentation validation attempted a session operation: '+name)


class Reloader:
    def __init__(self, path, watch=True):
        self.path = Path(path).resolve()
        source = self.path.read_bytes()
        self.contract = contract(source)
        self.seen = hashlib.sha256(source).digest()
        self.watch = watch
        self.requested = False
        self.next_check = 0
        self.pending = None
        self.active_module = None
        self.failed_read = None
        self.stamp = None
        self.support_paths = (Path(__file__), Path(identity.__code__.co_filename))
        self.support = tuple(hashlib.sha256(path.read_bytes()).digest() for path in self.support_paths)
        self.support_seen = self.support

    def request(self):
        self.requested = True

    def check(self, terminal, now=None):
        now = time.monotonic() if now is None else now
        explicit = self.requested
        self.requested = False
        if not explicit and (not self.watch or now < self.next_check):
            return False
        self.next_check = now + .5
        try:
            support = tuple(hashlib.sha256(path.read_bytes()).digest() for path in self.support_paths)
            if support != self.support:
                changed = support != self.support_seen
                self.support_seen = support
                if explicit or changed:
                    terminal.model.notice = 'TUI reload rejected: restart required for host support-module changes'
                    return True
                return False
            stat = self.path.stat()
            stamp = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
            if not explicit and stamp == self.stamp and self.pending is None:
                return False
            source = self.path.read_bytes()
            digest = hashlib.sha256(source).digest()
            if digest == self.seen:
                self.stamp = stamp
                self.pending = None
                if explicit:
                    terminal.model.notice = self.failed_read or 'TUI source unchanged'
                return explicit
            if not explicit and self.pending != digest:
                self.pending = digest
                return False
            self.seen = digest
            self.stamp = stamp
            self.pending = None
            if contract(source) != self.contract:
                raise ValueError('restart required: host, protocol, imports or state interface changed')
            code = compile(source, str(self.path), 'exec')
            name = '_shift_tui_' + digest.hex()[:16]
            module = types.ModuleType(name)
            module.__file__ = str(self.path)
            sys.modules[name] = module
            try:
                exec(code, module.__dict__)
                candidate = module.Terminal
                preview = candidate.__new__(candidate)
                preview.__dict__ = {
                    key: value if key in ('screen', 'child', 'reloader') else copy.deepcopy(value)
                    for key, value in terminal.__dict__.items()
                }
                preview.child = NoRequests()
                preview.screen = PreviewScreen(terminal.screen.getmaxyx())
                preview.put = lambda *args, **kwargs: None
                preview.colors = lambda: None
                preview.reloader = None
                preview.draw()
            except Exception:
                sys.modules.pop(name, None)
                raise
            old_module = self.active_module
            terminal.__class__ = candidate
            terminal.hits = []
            terminal.regions = {}
            terminal.draw_size = None
            self.active_module = name
            if old_module:
                sys.modules.pop(old_module, None)
            terminal.model.source_identity['loaded'] = identity(self.path.parent.parent)
            terminal.model.source_identity['presentation'] = digest.hex()[:12]
            self.failed_read = None
            terminal.model.notice = 'TUI presentation reloaded; live session preserved'
        except Exception as error:
            message = 'TUI reload rejected: ' + str(error)
            if message == self.failed_read and not explicit:
                return False
            self.failed_read = message
            terminal.model.notice = message
        return True
