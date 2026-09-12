#!/usr/bin/env python3
"""Shift's terminal adapter. Guile owns the session, permissions and UI state."""
import codecs
import curses
import json
import locale
import os
import re
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import termios
import unicodedata
from collections import deque
from dataclasses import dataclass
from tui_reload import Reloader
from tui_identity import identity

ROOT = Path(__file__).resolve().parents[1]
MODES = ('manual','plan','accept','auto')
KEY_SEQUENCES = {
    '[A':curses.KEY_UP, '[B':curses.KEY_DOWN, '[C':curses.KEY_RIGHT, '[D':curses.KEY_LEFT,
    'OA':curses.KEY_UP, 'OB':curses.KEY_DOWN, 'OC':curses.KEY_RIGHT, 'OD':curses.KEY_LEFT,
    '[H':curses.KEY_HOME, '[F':curses.KEY_END, 'OH':curses.KEY_HOME, 'OF':curses.KEY_END,
    '[1~':curses.KEY_HOME, '[4~':curses.KEY_END, '[7~':curses.KEY_HOME, '[8~':curses.KEY_END,
    '[3~':curses.KEY_DC, '[5~':curses.KEY_PPAGE, '[6~':curses.KEY_NPAGE,
    '[Z':curses.KEY_BTAB, 'OQ':curses.KEY_F2, '[12~':curses.KEY_F2,
}
ENUMS = {
    '/mode':MODES, '/brand':('replace','subtitle','none'), '/place':('left','right','top','bottom','modal'),
    '/sidebar':('auto','on','off'), '/density':('compact','comfortable'), '/border':('thin','heavy','double','none'),
    '/motion':('on','off'), '/work':('on','off'), '/fast':('on','off'),
    '/ui':('get','undo','reload','code-reload','save user','save project'),
}
COMMANDS = {
    '/theme':'Cycle theme, or choose a name', '/mode':'Execution policy', '/name':'Personal identity',
    '/brand':'Wordmark style', '/place':'Inspector position', '/sidebar':'Inspector visibility',
    '/density':'Transcript spacing', '/border':'Frame style', '/motion':'Working animation',
    '/ui':'Live presentation settings', '/work':'Automatic work display', '/help':'Session command help',
    '/model':'Inspect or choose a model', '/context':'Context usage and limit', '/settings':'Session settings',
    '/fast':'Fast model setting', '/thinking':'Thinking setting', '/tools':'Available tools',
    '/receipt':'Last turn receipt',
    '/session':'Current session', '/undo':'Undo last turn edits', '/quit':'Exit session',
}


def suggestions(draft, themes, palette=False):
    query=draft.strip()
    if not query.startswith('/'):
        return [(name,description) for name,description in COMMANDS.items()
                if palette and query.casefold() in (name+' '+description).casefold()]
    name,separator,value=draft.partition(' ')
    if separator:
        choices=themes if name=='/theme' else ENUMS.get(name,())
        return [(name+' '+choice,COMMANDS[name]) for choice in choices if choice.startswith(value)]
    return [(name,description) for name,description in COMMANDS.items() if name.startswith(query)]

VALUE_OPTIONS = {'--agent':1, '--state-dir':1, '--session':1, '--new-session':1,
                 '--resume':1, '--mode':1, '--model':1, '--allow-run':1,
                 '--set':1, '--receipt':1, '--mcp-port':1}


def frontend_arguments(argv):
    args=[]
    index=0
    while index<len(argv):
        option=argv[index]
        if option=='--tui':
            index+=1
            continue
        if option in ('--print','-p','--mcp','--mcp-stdio','--list-sessions','--fork-session'):
            raise ValueError('--tui cannot be combined with print, MCP stdio, or session maintenance.')
        count=VALUE_OPTIONS.get(option,0)
        args.extend(argv[index:index+count+1])
        index+=count+1
    return args


def watch_enabled(args):
    watch=True;index=0
    while index<len(args):
        if args[index] in ('--watch','--no-watch'):watch=args[index]=='--watch'
        index+=VALUE_OPTIONS.get(args[index],0)+1
    return watch


ANSI_COLORS = ((0,0,0),(205,0,0),(0,205,0),(205,205,0),
               (0,0,238),(205,0,205),(0,205,205),(229,229,229))


def ansi_rgb(n):
    if n<8:return ANSI_COLORS[n]
    if n<16:return ((127,127,127),(255,0,0),(0,255,0),(255,255,0),
                    (92,92,255),(255,0,255),(0,255,255),(255,255,255))[n-8]
    if n>=232:
        return (8+(n-232)*10,)*3
    value=n-16
    levels=(0,95,135,175,215,255)
    return tuple(levels[i] for i in (value//36,value//6%6,value%6))


def terminal_color(n, count, background=False):
    rgb=tuple(int(n[i:i+2],16) for i in (1,3,5)) if isinstance(n,str) else ansi_rgb(n)
    if count>=1<<24:
        r,g,b=rgb
        return r<<16|g<<8|b
    if count>=256:
        return min(range(256),key=lambda i:sum((a-b)**2 for a,b in zip(rgb,ansi_rgb(i)))) if isinstance(n,str) else n
    if isinstance(n,int) and n<16:return n%8
    if background and max(rgb)<128:return 0
    if max(rgb)-min(rgb)<80:return 7 if sum(rgb)>=300 else 0
    return min(range(8),key=lambda i:sum((a-b)**2 for a,b in zip(rgb,ANSI_COLORS[i])))


def clean(text):
    return ''.join(c for c in str(text) if c == '\t' or ord(c) >= 32 and not 127 <= ord(c) < 160).replace('\t', '    ')


def cell_width(c):
    if unicodedata.combining(c) or unicodedata.category(c) in ('Cf', 'Mn', 'Me'):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1


def clip(text, width):
    out, used = '', 0
    for c in clean(text):
        size = cell_width(c)
        if used + size > width:
            break
        if size or out:
            out += c
        used += size
    return out


def wrap(text, width, words=False):
    if width < 1:
        return []
    if words:
        text=clean(text);result=[];start=0
        while start<len(text):
            end=start;used=0
            while end<len(text) and used+cell_width(text[end])<=width:
                used+=cell_width(text[end]);end+=1
            if end==len(text):result.append(text[start:]);break
            split=text.rfind(' ',start,end)
            if split>start:
                result.append(text[start:split]);start=split+1
            else:
                end=max(end,start+1)
                result.append(text[start:end]);start=end
        return result or ['']
    lines, line, used = [], '', 0
    for c in clean(text):
        size = cell_width(c)
        if used + size > width:
            lines.append(line)
            line, used = '', 0
        if size or line:
            line += c
        used += size
    return lines + [line]


def composer_view(draft, cursor, width):
    before = sum(cell_width(ch) for ch in draft[:cursor])
    start, skipped = 0, 0
    while start < cursor and before-skipped >= width:
        skipped += cell_width(draft[start])
        start += 1
    while start < cursor and cell_width(draft[start]) == 0:
        start += 1
    return clip(draft[start:], width), before-skipped


@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int


def layout(cols, rows, config):
    # A compact prompt survives even in a tiny terminal.
    if rows < 18 or cols < 40:
        return Rect(0, 0, cols, max(0, rows-3)), None, 'compact'
    place, policy = config.get('placement', 'right'), config.get('sidebar', 'auto')
    horizontal=place in ('top','bottom')
    qdos=config.get('theme')=='qdos'
    top=5 if horizontal or qdos else 7
    if config.get('theme')=='apex' and not horizontal:top=4+max(1,min(3,len(config.get('wordmark',[]))))
    body = Rect(0, top, cols, rows-top-5)
    session = Rect(body.x, body.y, body.w, body.h)
    fits = cols >= (72 if qdos else 96) and body.h >= (8 if qdos else 10) if not horizontal else cols >= 72 and body.h >= 12
    visible = policy == 'on' or policy == 'auto' and fits and place != 'modal'
    if not visible:
        return session, None, 'hidden'
    if not fits or place == 'modal':
        width, height = min(60, cols-4), min(24, body.h-2)
        x = 0 if place == 'left' else cols-width if place == 'right' else (cols-width)//2
        return session, Rect(x, body.y+(body.h-height)//2, width, height), 'overlay'
    if place in ('left', 'right'):
        width = min(30,cols//2) if qdos else cols//3
        panel = Rect(0 if place == 'left' else cols-width, body.y, width, body.h)
        session.x = width if place == 'left' else 0
        session.w -= width
    else:
        height = 3
        panel = Rect(0, body.y if place == 'top' else body.y+body.h-height, cols, height)
        session.y += height if place == 'top' else 0
        session.h -= height
    return session, panel, 'docked'


class Scrollback(deque):
    def __init__(self):
        super().__init__(maxlen=3000)
        self.origin=0
    def append(self,value):
        if len(self)==self.maxlen:self.origin+=1
        super().append(value)
    def __deepcopy__(self,memo):
        result=type(self)()
        result.extend(self)
        result.origin=self.origin
        memo[id(self)]=result
        return result


class Model:
    def __init__(self):
        self.config = dict(theme='acid', identity=os.environ.get('USER', 'shift'), branding='subtitle',
                           wordmark=['shift ///'], sidebar='auto', placement='right', density='comfortable', border='thin',
                           ascii=False, metrics=True, motion=True, background='#170626', foreground='#f4edff', accent='#b6ff00',
                           secondary='#45f6ff', muted='#ae7deb', panel='#1e0c32',
                           positive='#64fff2', negative='#ff6588',
                           added_background='#074e4a', removed_background='#45152f',
                           sections=['files','context','checks','session'])
        self.revision = 0
        self.lines = Scrollback()
        self.partial = ''
        self.ready = False
        self.activity = 'starting'
        self.approval = False
        self.approval_prompt = ''
        self.pending_draft = None
        self.session = {}
        self.usage = {}
        self.receipt = {}
        self.tools = deque(maxlen=20)
        self.groups = {}
        self.current_turn = None
        self.streaming_role = None
        self.line_roles={}
        self.themes=['acid','apex','afterhours','paddock','blueprint']
        self.approval_preview=''
        self.command_request=0
        self.command_pending=None
        self.panel_tab = 'work'
        self.panel_scroll = {'diff':0,'session':0}
        self.show_diff = True
        self.notice = 'Starting Guile session…'
        self.scroll = 0
        self.work = True
        self.draft = ''
        self.cursor = 0
        self.history = []
        self.history_index = 0
        self.history_draft = ('',0)
        self.source_identity={'process':{'label':'source unavailable'},'loaded':{'label':'source unavailable'},'presentation':'unavailable'}

    def control(self, state):
        self.ready=state=='ready'
        if state=='needs_approval' and not self.approval:
            self.pending_draft=(self.draft,self.cursor)
            self.draft='';self.cursor=0;self.scroll=0
            self.notice='Type a reply, then Enter · Esc declines · Ctrl+C cancels'
        self.approval=state=='needs_approval'
        if self.ready and self.pending_draft is not None:
            self.draft,self.cursor=self.pending_draft;self.pending_draft=None
        if state!='working' or self.activity!='cancelling':
            self.activity=state
        if self.ready:
            self.approval_prompt=''
            self.approval_preview=''
            self.notice='Ready · /ui get · /help'
        elif state=='working' and self.activity!='cancelling':
            self.notice='Working · Ctrl+C cancels · UI commands remain available'

    def status(self):
        if self.approval:return 'APPROVAL'
        if self.ready:return 'READY'
        return self.activity.upper()

    def output(self, text):
        # Bound unbroken output as well as the number of retained lines.
        self.partial += text
        while '\n' in self.partial:
            line, self.partial = self.partial.split('\n', 1)
            self.line_roles[self.lines.origin+len(self.lines)]=self.streaming_role
            self.lines.append(clean(line.rstrip('\r'))[:8192])
            self.line_roles.pop(self.lines.origin-1,None)
        if len(self.partial) > 8192:
            self.lines.append(clean(self.partial[:8192]))
            self.partial = self.partial[-8192:]

    def flush_transcript(self):
        if self.partial:
            self.output('\n')
        self.streaming_role=None

    def group(self, turn):
        if turn not in self.groups:
            self.flush_transcript()
            self.groups={key:group for key,group in self.groups.items() if group['source']>=self.lines.origin}
            self.groups[turn]={'source':self.lines.origin+len(self.lines),'tools':[],'diff':'','files':[],'truncated':False,
                               'visible':self.session.get('show_work',True)}
            self.lines.append('')
        return self.groups[turn]

    def event(self, event):
        kind, value = event.get('type'), event.get('value')
        if kind == 'ui':
            self.config, self.revision = value['config'], value['revision']
            self.themes=value.get('themes',self.themes)
            self.notice = f'UI revision {self.revision} · /ui undo restores the previous view'
        elif kind == 'ui-error':
            self.notice = value
            self.lines.append('UI: ' + clean(value))
        elif kind == 'approval':
            self.approval_prompt = value
        elif kind == 'approval-preview':
            self.approval_preview=value
            self.panel_scroll['approval']=0
        elif kind == 'approval-end':
            self.approval_preview=''
            self.approval_prompt=''
        elif kind == 'session-command-result':
            if value.get('request_id')==self.command_pending:
                self.command_pending=None
                self.notice=clean(value.get('message','Mode changed') if value.get('ok') else value.get('error','Mode change rejected'))
        elif kind == 'history':
            for message in value:
                if message.get('role') in ('user','assistant') and isinstance(message.get('content'),str):
                    self.event({'type':'transcript','value':{'role':message['role'],'text':message['content']}})
        elif kind == 'input-history':
            self.history=list(value)
            self.history_index=len(self.history)
        elif kind == 'session':
            self.session = value
        elif kind == 'turn-start':
            self.current_turn=value['turn']
            self.usage={**self.usage,'prompt':None,'prompt_tokens':None,'prompt_source':'unavailable',
                        'prompt_reason':'provider-not-measured','round':0,'round_source':'not-started'}
            self.receipt={}
        elif kind == 'transcript':
            role=value.get('role','assistant')
            text=value.get('text','')
            if text:
                if self.streaming_role!=role or not value.get('stream'):
                    self.flush_transcript()
                    self.output(role+'> ')
                self.streaming_role=role
                self.output(text)
            if value.get('end') or not value.get('stream'):
                self.flush_transcript()
        elif kind == 'usage':
            self.usage = value
        elif kind == 'receipt':
            self.receipt = value
        elif kind == 'tool':
            self.tools.append(value)
            self.group(value.get('turn',self.current_turn))['tools'].append(dict(value))
        elif kind == 'tool-result':
            group=self.groups.get(value.get('turn',self.current_turn))
            if group:
                for tool in group['tools']:
                    if tool.get('id')==value.get('id'):
                        tool.update(result=value)
                        break
        elif kind == 'diff':
            if not value.get('text') and value.get('turn',self.current_turn) not in self.groups:
                return
            group=self.group(value.get('turn',self.current_turn))
            group['diff']=value.get('text','')
            group['files']=value.get('files',[])
            group['truncated']=value.get('truncated',False)


class Child:
    def __init__(self, args, cwd=None):
        self.watch=watch_enabled(args)
        control_r, control_w = os.pipe()
        event_r, event_w = os.pipe()
        command_r, command_w = os.pipe()
        env = {**os.environ, 'SHIFT_CONTROL_FD':str(control_w), 'SHIFT_UI_EVENT_FD':str(event_w),
               'SHIFT_UI_COMMAND_FD':str(command_r), 'PYTHONUNBUFFERED':'1'}
        self.process = subprocess.Popen([str(ROOT/'bin/shift'), '--no-mcp', '--watch', *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env, cwd=cwd, pass_fds=(control_w,event_w,command_r), start_new_session=True)
        for fd in (control_w,event_w,command_r): os.close(fd)
        self.command_w = command_w
        self.selector = selectors.DefaultSelector()
        self.decoders = {}
        self.buffers = {'control':'', 'event':''}
        for fd, kind in ((self.process.stdout.fileno(),'output'),(control_r,'control'),(event_r,'event')):
            os.set_blocking(fd,False)
            self.selector.register(fd,selectors.EVENT_READ,kind)
            self.decoders[kind] = codecs.getincrementaldecoder('utf-8')('replace')
        self.read_fds = (control_r,event_r)

    def poll(self, model):
        changed = False
        for key, _ in self.selector.select(0):
            chunk = os.read(key.fd,65536)
            if not chunk:
                self.selector.unregister(key.fd)
                continue
            changed = True
            kind = key.data
            text = self.decoders[kind].decode(chunk)
            if kind == 'output':
                model.output(text)
            else:
                self.buffers[kind] += text
                while '\n' in self.buffers[kind]:
                    line,self.buffers[kind] = self.buffers[kind].split('\n',1)
                    event=json.loads(line)
                    if kind == 'event': model.event(event)
                    else:model.control(event.get('state'))
        return changed

    def send(self, line):
        self.process.stdin.write((line+'\n').encode())
        self.process.stdin.flush()

    def ui(self, action):
        os.write(self.command_w,(json.dumps(action)+'\n').encode())

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired: pass
            # Tool children must not outlive the terminal's session owner.
            try: os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            self.process.wait()
        self.selector.close()
        for fd in (*self.read_fds,self.command_w):
            os.close(fd)
        self.process.stdin.close()
        self.process.stdout.close()


class Terminal:
    def __init__(self, screen, child):
        self.screen, self.child = screen,child
        self.model=Model()
        self.palette=None
        self.saved_colors={}
        self.menu=False
        self.anchor=None
        self.init_interactions()
        screen.keypad(True)
        screen.timeout(50)
        curses.raw()
        try: curses.curs_set(1)
        except curses.error: pass
        self.mouse_enabled=False
        if os.environ.get('TERM','').startswith(('xterm','screen','tmux','rxvt')) or curses.tigetstr('kmous'):
            mask=sum(getattr(curses,name,0) for name in ('BUTTON1_PRESSED','BUTTON1_RELEASED','BUTTON1_CLICKED',
                                                       'BUTTON4_PRESSED','BUTTON5_PRESSED'))
            curses.mouseinterval(0)
            curses.mousemask(mask)
            sys.stdout.write('\x1b[?1000;1006;1007s\x1b[?1007l\x1b[?1000h\x1b[?1006h')
            sys.stdout.flush()
            self.mouse_enabled=True

    def init_interactions(self):
        self.reloader=None
        self.hits=[]
        self.regions={}
        self.draw_size=None
        self.draw_revision=None
        self.completion_index=0
        self.completion_query=None
        self.completion_dismissed=None
        self.completion_choices=[]
        self.completion_confirmed=None
        self.palette_draft=None
        self.last_press=None
        self.mouse_enabled=False
        self.acs=False
        self.unicode=True
        self.scroll_limit=0
        self.panel_limits={}
        self.key_sequences=dict(KEY_SEQUENCES)

    def stop_mouse(self):
        if self.mouse_enabled:
            curses.mousemask(0)
            sys.stdout.write('\x1b[?1000l\x1b[?1006l\x1b[?1000;1006;1007r')
            sys.stdout.flush()
            self.mouse_enabled=False

    def hit(self,y,x,width,action):
        rows,cols=self.screen.getmaxyx()
        if 0<=y<rows and 0<=x<cols and width>0:
            self.hits.append((Rect(x,y,min(width,cols-x),1),action))

    def button(self,y,x,text,width,action,color=3,bold=True):
        text=clip(text,width)
        self.put(y,x,text,width,color,bold)
        if sum(cell_width(ch) for ch in text)==len(text):self.hit(y,x,len(text),action)

    def cycle_theme(self):
        themes=self.model.themes
        if not themes:
            self.model.notice='No theme packs available';return
        current=self.model.config['theme']
        theme=themes[(themes.index(current)+1)%len(themes)] if current in themes else themes[0]
        self.child.ui({'action':'patch','patch':{'theme':theme}})

    def request_mode(self,mode=None):
        m=self.model
        if m.approval or not m.ready:
            m.notice='Finish approval before changing mode.' if m.approval else 'Turn running; change mode when ready.'
            return False
        if m.command_pending is not None:
            m.notice='Mode change pending';return
        if mode is None:
            current=m.session.get('mode','manual')
            mode=MODES[(MODES.index(current)+1)%len(MODES)] if current in MODES else MODES[0]
        if mode not in MODES:raise ValueError('use /mode manual|plan|accept|auto')
        m.command_request+=1;m.command_pending=m.command_request
        self.child.ui({'action':'session-command','command':'/mode '+mode,'request_id':m.command_request})
        m.notice='Changing mode to '+mode+' (pending)'
        return True

    def completion(self):
        m=self.model
        active=(self.menu or m.draft.startswith('/')) and self.completion_dismissed!=m.draft
        name,separator,_=m.draft.partition(' ')
        if separator and name not in ENUMS and name!='/theme' and not self.menu:active=False
        query=(self.menu,m.draft,tuple(m.themes))
        if query!=self.completion_query:
            self.completion_index=0
            self.completion_query=query
        self.completion_choices=suggestions(m.draft,m.themes,self.menu) if active else []
        self.completion_index=min(self.completion_index,max(0,len(self.completion_choices)-1))
        return active

    def close_completion(self,restore=False):
        m=self.model
        if restore and self.palette_draft is not None:m.draft,m.cursor=self.palette_draft
        self.palette_draft=None
        self.menu=False
        self.completion_dismissed=m.draft

    def open_palette(self):
        if self.menu:
            self.close_completion(restore=True);return
        self.palette_draft=(self.model.draft,self.model.cursor)
        self.model.draft='';self.model.cursor=0
        self.menu=True;self.completion_dismissed=None;self.completion_confirmed=None

    def accept_completion(self,index=None):
        if not self.completion_choices:return
        index=self.completion_index if index is None else index
        if index>=len(self.completion_choices):return
        m=self.model
        text=self.completion_choices[index][0]
        self.menu=False
        m.draft=text;m.cursor=len(text)
        self.completion_confirmed=text
        self.completion_dismissed=text
        m.notice='Completed command; Enter submits, Space adds arguments, Esc restores draft'

    def contains(self,r,x,y):
        return r is not None and r.x<=x<r.x+r.w and r.y<=y<r.y+r.h

    def pointer(self,x,y,event):
        if self.draw_size!=self.screen.getmaxyx():
            return
        if event in ('up','down'):
            delta=-3 if event=='up' else 3
            if self.contains(self.regions.get('completion'),x,y):
                self.completion_index=max(0,min(len(self.completion_choices)-1,self.completion_index+delta))
            elif self.contains(self.regions.get('approval'),x,y):
                self.model.panel_scroll['approval']=max(0,min(self.panel_limits.get('approval',0),self.model.panel_scroll.get('approval',0)+delta))
            elif self.contains(self.regions.get('panel'),x,y):
                tab=self.model.panel_tab
                self.model.panel_scroll[tab]=max(0,min(self.panel_limits.get(tab,0),self.model.panel_scroll.get(tab,0)+delta))
            elif self.contains(self.regions.get('transcript'),x,y):
                self.model.scroll=max(0,min(self.scroll_limit,self.model.scroll-delta));self.anchor=None
            return
        if event=='release':return
        if event=='click' and self.last_press and self.last_press[:2]==(x,y) and time.monotonic()-self.last_press[2]<.35:
            return
        if event=='press':self.last_press=(x,y,time.monotonic())
        for region,action in reversed(self.hits):
            if self.contains(region,x,y):
                kind,value=action
                if kind=='mode':self.request_mode()
                elif kind=='sidebar':self.key('\x02')
                elif kind=='commands':self.open_palette()
                elif kind=='theme':self.cycle_theme()
                elif kind=='tab':self.model.panel_tab=value
                elif kind=='complete':self.accept_completion(value)
                return

    def mouse(self):
        try:_,x,y,_,state=curses.getmouse()
        except curses.error:return
        for name,event in (('BUTTON4_PRESSED','up'),('BUTTON5_PRESSED','down'),('BUTTON1_PRESSED','press'),
                           ('BUTTON1_CLICKED','click'),('BUTTON1_RELEASED','release')):
            if state&getattr(curses,name,0):
                self.pointer(x,y,event);break

    def read_key(self):
        try:key=self.screen.get_wch()
        except curses.error:return None
        if key!='\x1b':return key
        # Older macOS terminfo understands X10 mouse packets, not SGR 1006.
        sequence=''
        self.screen.timeout(30)
        try:
            for _ in range(40):
                try:code=self.screen.getch()
                except curses.error:break
                if code<0:break
                if code>255:
                    curses.ungetch(code);break
                ch=chr(code)
                sequence+=ch
                if sequence in self.key_sequences:return self.key_sequences[sequence]
                if sequence.startswith('[M'):
                    if len(sequence)<5:continue
                    button,x,y=(ord(ch)-32 for ch in sequence[2:5])
                    event='up' if button&~28==64 else 'down' if button&~28==65 else 'release' if button&3==3 else 'press' if button&3==0 else None
                    if event:self.pointer(x-1,y-1,event)
                    return curses.KEY_REFRESH
                if re.fullmatch(r'\[<\d+;\d+;\d+[Mm]',sequence):
                    button,x,y=map(int,re.findall(r'\d+',sequence))
                    button&=~28
                    event='up' if button==64 else 'down' if button==65 else 'release' if sequence.endswith('m') else 'press' if button==0 else None
                    if event:self.pointer(x-1,y-1,event)
                    return curses.KEY_REFRESH
                if not sequence.startswith('[<') and not any(key.startswith(sequence) for key in self.key_sequences) and sequence!='[M':break
        finally:self.screen.timeout(50)
        if sequence.startswith('[<'):return None
        for ch in reversed(sequence):curses.ungetch(ord(ch))
        return key

    def colors(self):
        c=self.model.config
        keys=('foreground','background','accent','secondary','muted','panel',
              'positive','negative','added_background','removed_background')
        signature=tuple(c.get(k) for k in keys)
        if signature==self.palette:return
        self.restore_colors()
        self.palette=signature
        if not curses.has_colors():return
        allocated={}
        available=[i for i in range(min(256,curses.COLORS)-1,15,-1) if i not in signature]
        def color(n,background=False):
            if isinstance(n,str) and 256<=curses.COLORS<1<<24 and curses.can_change_color():
                if n not in allocated:
                    target=tuple(int(n[i:i+2],16) for i in (1,3,5))
                    index=min(available,key=lambda i:sum((a-b)**2 for a,b in zip(target,ansi_rgb(i))))
                    available.remove(index)
                    self.saved_colors[index]=curses.color_content(index)
                    rgb=tuple(round(int(n[i:i+2],16)*1000/255) for i in (1,3,5))
                    try:
                        curses.init_color(index,*rgb)
                    except curses.error:
                        self.model.notice='RGB palette unavailable; using nearest ANSI colors'
                        return terminal_color(n,curses.COLORS,background)
                    allocated[n]=index
                return allocated[n]
            return terminal_color(n,curses.COLORS,background)
        resolved={key:color(c[key],key in ('background','panel','added_background','removed_background')) for key in keys}
        for i,key in enumerate(('foreground','accent','secondary','muted'),1):
            curses.init_pair(i,resolved[key],resolved['background'])
        for i,key in enumerate(('foreground','secondary','accent','muted'),5):
            curses.init_pair(i,resolved[key],resolved['panel'])
        for i,foreground,background in ((9,'background','accent'),(10,'positive','added_background'),
                                        (11,'negative','removed_background'),(12,'background','secondary')):
            if c['theme']=='qdos' and i in (9,12):foreground,background='accent','removed_background'
            curses.init_pair(i,resolved[foreground],resolved[background])
        self.screen.bkgd(' ',curses.color_pair(1))

    def restore_colors(self):
        for index,rgb in self.saved_colors.items():
            curses.init_color(index,*rgb)
        self.saved_colors.clear()

    def put(self,y,x,text,width,color=1,bold=False,dim=False):
        rows,cols=self.screen.getmaxyx()
        if y<0 or y>=rows or x<0 or x>=cols:return
        text=clip(text,min(width,cols-x))
        lines='─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬'
        if self.model.config.get('theme')=='qdos' and text.strip() and set(text)<=set(lines+'+-=| '):color=1
        style=(curses.color_pair(color) if curses.has_colors() else 0)|(curses.A_BOLD if bold else 0)|(curses.A_DIM if dim else 0)
        try:
            # Rules use ncurses' cell/ACS path, not repeated UTF-8 strings.
            # Prose and diff hyphens stay on the ordinary text path.
            for part in re.split('(['+lines+'█░])',text):
                if part in ('█','░'):
                    glyph=part if self.unicode and not self.model.config.get('ascii') else '#' if part=='█' else '.'
                    self.screen.addch(y,x,glyph,style);x+=1
                elif part and part in lines:
                    index=lines.index(part)%11
                    names=('HLINE','VLINE','ULCORNER','URCORNER','LLCORNER','LRCORNER','LTEE','RTEE','TTEE','BTEE','PLUS')
                    fallback=('-','|','+','+','+','+','+','+','+','+','+')[index]
                    if self.model.config.get('ascii'):glyph=fallback
                    elif self.unicode:glyph=part
                    elif self.acs:glyph=getattr(curses,'ACS_'+names[index],fallback)
                    else:glyph=part if self.unicode else fallback
                    self.screen.addch(y,x,glyph,style);x+=1
                elif part:
                    self.screen.addstr(y,x,part,style)
                    x+=sum(cell_width(ch) for ch in part)
        except curses.error:pass # writing the bottom-right cell may report ERR

    def mark_phase(self, now=None):
        m=self.model
        if m.activity!='working' or m.ready or m.approval or not m.config.get('motion',True):
            return None
        return int((time.monotonic() if now is None else now)*4)%3

    def brand_line(self,y,x,line,width):
        self.put(y,x,line,width,2,True)
        visible=clip(line,width)
        mark=visible.rfind('///')
        if mark>=0 and self.model.config['branding']!='none':
            self.marks.append((y,x+sum(cell_width(ch) for ch in visible[:mark]),1))

    def paint_marks(self,phase):
        for y,x,height in self.marks:
            for i in range(3):
                active=phase is None or i==phase
                for row in range(height):
                    self.put(y+row,x+i*height+height-row-1,'/' if height==1 else '█',1,2,active,not active)
        self.last_phase=phase

    def border_glyphs(self):
        c=self.model.config
        border=c.get('border','thin')
        glyphs=('+','+','+','+','=' if border in ('heavy','double') else '-','|') if c.get('ascii') else (
            ('╔','╗','╚','╝','═','║') if border=='double' else ('┌','┐','└','┘','─','│'))
        if border=='none':glyphs=(' ',)*6
        return glyphs

    def box(self,r,title):
        if r.w<2 or r.h<2:return
        tl,tr,bl,br,horizontal,vertical=self.border_glyphs()
        for y in range(r.y,r.y+r.h):self.put(y,r.x,' '*r.w,r.w,5)
        self.put(r.y,r.x,tl+horizontal*(r.w-2)+tr,r.w,6)
        self.put(r.y+r.h-1,r.x,bl+horizontal*(r.w-2)+br,r.w,6)
        for y in range(r.y+1,r.y+r.h-1):
            self.put(y,r.x,vertical,1,6);self.put(y,r.x+r.w-1,vertical,1,6)
        if title:self.put(r.y,r.x+2,' '+title+' ',r.w-4,6,True)

    def spans(self,y,x,parts,width):
        for text,tone,bold in parts:
            visible=clip(text,width)
            self.put(y,x,visible,width,tone,bold)
            used=sum(cell_width(ch) for ch in visible)
            x+=used;width-=used
            if width<=0:break

    def rule(self,width):
        return ('-' if self.model.config.get('ascii') else '─')*max(0,width)

    def tabs(self):
        sections=self.model.config['sections']
        return ['work']+(['diff'] if 'files' in sections else [])+(['session'] if 'session' in sections else [])

    def telemetry(self):
        m=self.model
        return [('CONTEXT',m.usage.get('prompt'),m.usage.get('limit'),2),
                ('ROUND',m.usage.get('round'),m.usage.get('max_rounds'),3),
                ('MODEL MEM',m.usage.get('memory_bytes'),None,4)]

    def telemetry_notes(self):
        u=self.model.usage
        reasons={
            'demo-no-metadata':'demo has no loaded model',
            'provider-metadata-unsupported':'provider does not report it',
            'remote-metadata-disabled':'local metadata only',
            'metadata-unreachable':'metadata endpoint unavailable',
            'metadata-invalid':'invalid provider metadata',
            'model-not-loaded':'model not loaded',
            'loaded-context-unavailable':'runtime context not reported',
            'loaded-memory-unavailable':'allocation not reported',
        }
        notes=[]
        if u.get('limit') is None:
            notes.append('CTX: /context limit N')
        if u.get('memory_bytes') is None:
            notes.append('MEM: '+reasons.get(u.get('memory_reason'),'not measured yet'))
        return notes

    def meter(self,metric,width):
        label,value,limit,tone=metric
        known=isinstance(value,(int,float)) and isinstance(limit,(int,float)) and limit>0
        def number(n):
            if not isinstance(n,(int,float)):return 'unknown'
            if n>=10000:return f'{n/1000:.0f}k'
            if n>=1000:return f'{n/1000:.1f}k'
            return str(n)
        if label=='MODEL MEM':
            text=f'{value/(1024**3):.1f} GiB' if isinstance(value,(int,float)) else 'N/A'
            return [(label+' ',3,True),(text,1,False)]
        text=number(value)+(' / '+(number(limit) if limit is not None else '?') if label!='RAM' and (value is not None or limit is not None) else '')
        if label=='CONTEXT' and self.model.usage.get('prompt_source')=='estimated' and isinstance(value,(int,float)):text='~'+text
        if value is None and limit is None:text='starting' if not self.model.ready else 'not measured'
        parts=[(label+' ',3,True),(text+'  ',1,False)]
        segments=min(20,width-len(label)-len(text)-3)
        if segments>=4 and known:
            filled=min(segments,max(0,int(segments*value/limit+.5))) if known else 0
            full,empty=('#','.') if self.model.config.get('ascii') or not self.unicode else ('█','░')
            parts.extend([(full*filled,tone,True),(empty*(segments-filled),4,False)])
        return parts

    def metadata(self,y,x,width):
        m=self.model
        badge=' '+m.session.get('mode','manual').upper()+' '
        state=m.status()
        details=str(m.session.get('name','default'))+' | '+str(m.session.get('model','starting'))
        room=max(0,width-len(badge)-len(state)-4)
        self.put(y,x,details,room,1)
        self.button(y,x+room+2,badge,len(badge),('mode',None),9)
        self.put(y,x+room+len(badge)+3,state,len(state),3 if state=='WORKING' else 4,True)

    def header(self,cols,panel,mode):
        m=self.model;c=m.config
        if c['theme']=='qdos':
            self.qdos_header(cols,panel,mode);return
        build='loaded '+m.source_identity['loaded']['label']
        if cols>=60:self.put(0,max(0,cols-len(build)-2),build,min(len(build),cols-2),4)
        horizontal=c['placement'] in ('top','bottom')
        strip_y=2+max(1,min(3,len(c.get('wordmark',[])))) if c['theme']=='apex' else 5
        brand=c['identity'] if c['branding']=='replace' else 'shift'
        title=brand+' ///' if c['branding']!='none' else c['identity']
        wordmark=c.get('wordmark',['shift ///'])
        ascii_mode=c.get('ascii') or not self.unicode
        logo=wordmark if c['branding']=='subtitle' and (not ascii_mode or all(line.isascii() for line in wordmark)) else [title]
        logo_width=max(sum(cell_width(ch) for ch in line) for line in logo)
        scaled_mark=None
        if len(logo)>1 and not ascii_mode:
            for index,line in enumerate(logo):
                if line.endswith('///'):
                    offset=sum(cell_width(ch) for ch in line[:-3])
                    if all(sum(cell_width(ch) for ch in other.rstrip())<=offset for j,other in enumerate(logo) if j!=index):
                        scaled_mark=(index,offset,len(logo))
                        logo_width=max(logo_width,offset+3*len(logo))
                        break
        large=cols>=logo_width+40 and c['density']!='compact'
        if large:
            for y,line in enumerate(logo[:3]):
                if scaled_mark:
                    self.put(y+1,2,line[:-3] if y==scaled_mark[0] else line,logo_width,2,True)
                else:self.brand_line(y+1,2,line,logo_width)
            if scaled_mark:self.marks.append((1,2+scaled_mark[1],scaled_mark[2]))
        else:
            self.brand_line(1,2,title,cols-4)
            logo_width=min(len(title),cols-4)
        if horizontal:
            if large:self.metadata(2,logo_width+6,cols-logo_width-8)
            else:self.metadata(3,2,cols-4)
        else:
            if cols>=100 and c.get('metrics') and 'context' in c['sections']:
                self.spans(1 if strip_y==3 else 2,max(logo_width+7,cols//2),self.meter(self.telemetry()[0],cols//2-4),cols//2-4)
            limit=panel.x-2 if panel and mode=='docked' and c['placement']=='right' else cols-2
            start=panel.w+2 if panel and mode=='docked' and c['placement']=='left' else 2
            self.metadata(strip_y,start,limit-start)
            self.put(strip_y+1,0,self.rule(cols),cols,3)
            if panel and mode=='docked':
                x=panel.x+2
                for tab in self.tabs():
                    text=' '+tab.upper()+' '
                    self.button(strip_y,x,text,len(text),('tab',tab),12 if m.panel_tab==tab else 4,m.panel_tab==tab)
                    x+=len(text)+2
        if c['branding']=='subtitle':
            x=logo_width+6 if large else 2
            self.put(1 if large else 2,x,c['identity'],cols-x-2,4)
            if large and cols>=100 and not ascii_mode and (horizontal or strip_y>3):
                check_x=cols-24 if horizontal else logo_width+6
                room=check_x-x-2 if horizontal else cols//2-check_x-2
                if (horizontal and len(c['identity'])<=room) or (not horizontal and room>=16):
                    self.put(1 if horizontal else 2,check_x,'▀▄'*8,16,3)
        self.put(4 if horizontal else strip_y-1,0,self.rule(cols),cols,3)

    def qdos_header(self,cols,panel,mode):
        m=self.model;c=m.config
        brand=c['identity'] if c['branding'] in ('replace','none') else 'shift'
        title=clip(brand,16)+(' ///' if c['branding']!='none' else '')
        self.brand_line(0,0,title,min(22,cols))
        x=min(22,len(title)+1)
        for text,action in [('Commands',('commands',None)),('Mode',('mode',None)),
                            ('Sidebar',('sidebar',None)),('Theme',('theme',None))]:
            if x+len(text)+2>cols:break
            self.button(0,x,text,len(text),action,1)
            x+=len(text)+2
        build='loaded '+m.source_identity['loaded']['label']
        room=cols-len(build)-2 if cols>=60 else cols
        self.put(1,0,'Select commands or sidebar; Shift-Tab cycles mode',room,4)
        if cols>=60:self.put(1,room+2,build,len(build),4)
        self.put(2,0,('=' if c.get('ascii') else '═')*cols,cols,1)
        if panel and mode=='docked' and c['placement'] in ('left','right'):
            x=panel.x
            for tab in self.tabs():
                text=tab.upper()+' '
                self.button(3,x,text,len(text),('tab',tab),12 if tab==m.panel_tab else 3)
                x+=len(text)
            start=panel.w+1 if c['placement']=='left' else 0
            width=cols-panel.w-2
        else:start=0;width=cols
        self.metadata(3,start,width)
        self.put(4,0,('=' if c.get('ascii') else '═')*cols,cols,1)

    def active_group(self):
        return self.model.groups.get(self.model.current_turn,{})

    def diff_rows(self,group,width,full=False):
        lines=group.get('diff','').splitlines()
        if not full:
            lines=[line for line in lines if line.startswith(('+','-')) and not line.startswith(('+++','---'))]
        result=[]
        for line in lines:
            tone=10 if line.startswith('+') and not line.startswith('+++') else 11 if line.startswith('-') and not line.startswith('---') else 4
            for segment in wrap(line,width):
                padding=max(0,width-sum(cell_width(ch) for ch in segment))
                result.append([(segment+' '*padding,tone,False)])
        if group.get('truncated'):
            result.extend([[(line.ljust(width),4,False)] for line in wrap('Diff truncated; full patch is in the session ledger',width)])
        return result

    def framed_diff(self,group,width,full=False,limit=None):
        if width<8:return self.diff_rows(group,width,full)
        content=self.diff_rows(group,width-4,full)
        if not content:return []
        if limit is not None:content=content[:limit]
        tl,tr,bl,br,horizontal,vertical=self.border_glyphs()
        empty=[(vertical+' '*(width-2)+vertical,3,False)]
        return [[(tl+horizontal*(width-2)+tr,3,False)],empty]+[
            [(vertical+' ',3,False)]+parts+[(' '+vertical,3,False)] for parts in content
        ]+[empty,[(bl+horizontal*(width-2)+br,3,False)]]

    def group_rows(self,group,width,inline_diff):
        m=self.model
        arrow=lambda opened:('v' if opened else '>') if m.config.get('ascii') or not self.unicode else ('▼' if opened else '▶')
        rows=[[(self.rule(width),4,False)],
              [(arrow(m.work)+' WORK  ',3,True),(str(len(group['tools']))+' steps',4,False)]]
        if m.work:
            rows.append([('',1,False)])
            for tool in group['tools']:
                name=tool.get('name','tool')
                label={'read':'READ','write':'EDIT','edit':'EDIT','apply_patch':'EDIT','run':'RUN'}.get(name,name.upper())
                summary=str(tool.get('summary',''))
                changes=group.get('files',[]) or m.receipt.get('changed',[])
                change=next((item for item in changes if item.get('path')==summary),None) if label=='EDIT' else None
                stats=[(' +'+str(change['added']),2,True),(' -'+str(change['removed']),11,True)] if change else []
                stats_width=sum(len(part[0]) for part in stats)
                result=tool.get('result')
                status=('done' if result.get('ok') else 'failed') if result else ('approval' if m.approval else 'unreported' if m.ready else m.activity)
                at=str(tool.get('at',''))
                tail=at if result and at and width>=65 else status
                subject=clip(summary,max(1,width-18-len(tail)-stats_width))
                padding=max(1,width-12-len(tail)-stats_width-sum(cell_width(ch) for ch in subject))
                rows.append([('  '+label.ljust(7),3,True),(subject,1,False)]+stats+
                             [(' '*padding+tail,4 if not result or result.get('ok') else 11,False)])
                if result and not result.get('ok'):
                    rows.extend([[(line,11,False)] for line in wrap('    '+str(result.get('summary','Tool failed')),width)])
        if inline_diff and group.get('diff'):
            count=len([line for line in group['diff'].splitlines() if line.startswith(('+','-')) and not line.startswith(('+++','---'))])
            rows.extend([[('',1,False)],[(arrow(m.show_diff)+' OUTPUT DIFF  ',3,True),(str(count)+' changed lines',4,False)]])
            if m.show_diff:rows.extend(self.framed_diff(group,width))
        rows.extend([[(self.rule(width),4,False)],[('',1,False)]])
        return [parts for parts in rows if any(part[0] for part in parts)] if m.config['density']=='compact' else rows

    def body_rows(self,width,compact,inline_diff):
        m=self.model
        result=[];positions=[];fenced=False;role=None
        groups={group['source']:group for group in m.groups.values()}
        sources=list(m.lines)+([m.partial] if m.partial else [])
        def add(parts,source,offset):
            result.append(parts);positions.append((source,offset))
        for source,line in enumerate(sources,m.lines.origin):
            if source in groups:
                if groups[source]['visible']:
                    for offset,parts in enumerate(self.group_rows(groups[source],width,inline_diff)):
                        add(parts,source,offset)
                continue
            if m.approval and m.approval_prompt and line.strip()==m.approval_prompt.strip():continue
            if m.config['density']=='compact' and not line.strip():continue
            if not m.work and line.startswith(('tool>','      ')):continue
            label=None;tone=1;offset=0
            for prefix,title,color in (('you> ','USER',3),('user> ','USER',3),
                                      ('assistant> ','SHIFT',2),('thinking> ','THINKING',4)):
                if line.startswith(prefix):
                    label=title;tone=color;offset=len(prefix);line=line[offset:];fenced=False;break
            role=m.line_roles.get(source,role) if not label else label.lower()
            if label and not compact:
                if m.config['density']!='compact' and (not result or any(part[0] for part in result[-1])):
                    add([('',1,False)],source,-2)
                add([(label,tone,True)],source,-1);tone=1
            elif label:
                line=label+': '+line;offset=0
            elif line.startswith('tool> '):
                line='WORK  '+line[6:];tone=3
            elif line.startswith('      '):tone=4
            preformatted=fenced or line.startswith(('    ','\t'))
            if role in ('assistant','shift') and line.startswith('```'):
                fenced=not fenced
                add([(('CODE '+line[3:]) if fenced else '',4,True)],source,offset)
                continue
            bold=False
            if role in ('assistant','shift') and not preformatted:
                heading=re.match(r'^#{1,6}\s+(.+)',line)
                if heading:line=heading[1];bold=True
                # Only strip complete inline markers; code fences remain literal.
                line=re.sub(r'\*\*([^*\n]+)\*\*',r'\1',line)
                line=re.sub(r'`([^`\n]+)`',r'\1',line)
            for segment in wrap(line,width,words=role is not None and not preformatted):
                add([(segment,tone,bold)],source,offset);offset+=len(segment)+(1 if line[offset+len(segment):].startswith(' ') else 0)
        return result,positions

    def inspector(self,panel,mode):
        m=self.model;c=m.config
        if c['placement'] in ('top','bottom') and mode=='docked':
            self.put(panel.y,0,self.rule(panel.w),panel.w,3)
            if c.get('metrics') and 'context' in c['sections']:
                width=panel.w//3
                for i,metric in enumerate(self.telemetry()):
                    self.spans(panel.y+1,i*width+2,self.meter(metric,width-4),width-4)
                    if i:self.put(panel.y+1,i*width,'|' if c.get('ascii') else '│',1,3)
            else:
                self.put(panel.y+1,2,'Session '+str(m.session.get('name','default'))+' | '+m.status(),panel.w-4,4)
            return
        if mode=='overlay':self.box(panel,'OUTPUT · Tab changes view')
        else:
            x=panel.x if c['placement']=='right' else panel.x+panel.w-1
            double=c['theme']=='qdos' and c.get('border')=='double'
            vertical='║' if double else '│'
            self.put(panel.y-1,x,'+' if c.get('ascii') else '╦' if double else '┬',1,3)
            for y in range(panel.y,panel.y+panel.h):self.put(y,x,'|' if c.get('ascii') else vertical,1,3)
        width=panel.w-4;group=self.active_group()
        rows=[]
        def title(text):
            rows.append([(text,3,True)])
        def line(text,tone=1):
            rows.append([(text,tone,False)])
        if m.panel_tab=='session':
            title('SESSION');line(str(m.session.get('name','default')));line(str(m.session.get('model','starting')))
            line('Mode: '+m.session.get('mode','manual'));line('Turn: '+str(m.session.get('turn','unknown')))
            line('');title('LATEST RECEIPT')
            if m.receipt:
                line('Status: '+str(m.receipt.get('status','unknown')))
                line('Duration: '+str(m.receipt.get('duration_ms','unknown'))+' ms')
                for run in m.receipt.get('runs',[]):
                    line(' '.join(run.get('command',[])))
                    line('exit '+str(run.get('exit_code','unknown')),2 if run.get('success') else 11)
            else:line('No completed turn',4)
            if c.get('metrics') and 'context' in c['sections']:
                line('');title('TELEMETRY · EXACT VALUES')
                for label,key in (('Prompt','prompt'),('Limit','limit'),('Round','round'),('Max rounds','max_rounds')):
                    value=m.usage.get(key)
                    detail=format(value,',') if isinstance(value,(int,float)) else 'not measured'
                    if key=='prompt' and value is not None:detail+=' ('+m.usage.get('prompt_source','reported')+')'
                    if key=='round' and m.usage.get('round_source')=='not-started':detail+=' (not started)'
                    line(label+': '+detail)
                memory=m.usage.get('memory_bytes')
                line('Allocated: '+(format(memory,',')+' bytes' if isinstance(memory,(int,float)) else 'N/A'))
                if m.usage.get('memory_label'):line(str(m.usage['memory_label']))
                if m.usage.get('context_source'):line('Context: '+str(m.usage['context_source']))
                for note in self.telemetry_notes():
                    for part in wrap(note,width,words=True):line(part,4)
            line('');title('SHIFT SOURCE')
            line('Loaded: '+m.source_identity['loaded']['label'])
            line('Process: '+m.source_identity['process']['label'])
            line('TUI: '+m.source_identity['presentation'])
            for part in wrap(m.source_identity['loaded'].get('commit') or 'Commit unavailable',max(1,width)):
                line(part)
        elif m.panel_tab=='diff':
            title('OUTPUT DIFF');line('')
            rows.extend((self.framed_diff(group,width,full=True) or [[('No committed changes',4,False)]])
                        if m.show_diff else [[('Diff folded (^O opens)',4,False)]])
        else:
            sections={}
            if c['theme']=='qdos' and 'session' in c['sections']:
                title('SESSION')
                line(str(m.session.get('name','default')))
                line(str(m.session.get('model','starting')))
                line(m.session.get('mode','manual').upper()+' | '+m.status())
                line(self.rule(width),4)
                sections['session']=rows;rows=[]
            if 'files' in c['sections']:
                title('OUTPUT DIFF');line('')
                diff=self.diff_rows(group,max(1,width-4) if width>=8 else width)
                preview=max(2,min(8,panel.h//3))
                rows.extend((self.framed_diff(group,width,limit=preview) or [[('No committed changes',4,False)]])
                            if m.show_diff else [[('Diff folded (^O opens)',4,False)]])
                if m.show_diff and len(diff)>preview:line('Tab: full diff ('+str(len(diff))+' lines)',4)
                line('');line(self.rule(width),4);title('FILES')
                files=list(dict.fromkeys([str(t.get('summary','')) for t in group.get('tools',[]) if t.get('name') in ('read','write','edit')]+
                                         [v.get('path','') for v in group.get('files',[]) or m.receipt.get('changed',[])]))
                for path in files[:4]:line(path)
                if len(files)>4:line('+'+str(len(files)-4)+' more files',4)
                if not files:line('No files touched',4)
                line('');line(self.rule(width),4)
                sections['files']=rows;rows=[]
            if c.get('metrics') and 'context' in c['sections']:
                title('TELEMETRY');line('')
                for metric in self.telemetry():
                    rows.append(self.meter(metric,width))
                    if panel.h>=26:line('')
                for note in self.telemetry_notes():
                    for part in wrap(note,width,words=True):line(part,4)
                sections['context']=rows;rows=[]
            if 'checks' in c['sections'] and m.receipt.get('runs'):
                title('RUNS')
                for run in m.receipt['runs']:
                    line('exit '+str(run.get('exit_code','unknown'))+'  '+' '.join(run.get('command',[])),2 if run.get('success') else 11)
                sections['checks']=rows
            rows=[parts for section in c['sections'] for parts in sections.get(section,[])]
        height=max(0,panel.h-2)
        self.panel_limits[m.panel_tab]=max(0,len(rows)-height)
        start=0
        start=min(m.panel_scroll.get(m.panel_tab,0),max(0,len(rows)-height))
        m.panel_scroll[m.panel_tab]=start
        for i,parts in enumerate(rows[start:start+height]):
            self.spans(panel.y+1+i,panel.x+2,parts,width)
        if len(rows)>height:
            self.put(panel.y+panel.h-1,panel.x+2,f'wheel {start+1}-{min(len(rows),start+height)}/{len(rows)} | Tab',width,4)

    def draw(self):
        self.colors()
        m=self.model;c=m.config;rows,cols=self.screen.getmaxyx()
        if self.draw_size!=(rows,cols) or self.draw_revision!=m.revision:
            self.screen.clearok(True)
        self.screen.erase()
        self.draw_revision=m.revision
        self.marks=[]
        self.hits=[];self.regions={};self.draw_size=(rows,cols)
        session,panel,mode=layout(cols,rows,{**c,'sidebar':'off'} if m.approval else c)
        self.regions['transcript']=session
        if panel and (mode=='overlay' or c['placement'] not in ('top','bottom')):self.regions['panel']=panel
        if m.panel_tab not in self.tabs():m.panel_tab='work'
        if mode!='compact':self.header(cols,panel,mode)
        inline_diff=c['placement'] in ('top','bottom') or panel is None or mode=='overlay'
        lines,positions=self.body_rows(max(1,session.w-4),mode=='compact',inline_diff)
        height=session.h
        self.scroll_limit=max(0,len(lines)-height)
        m.scroll=min(m.scroll,self.scroll_limit)
        end=max(0,len(lines)-m.scroll)
        start=max(0,end-height)
        if m.scroll and self.anchor and positions:
            candidates=[i for i,pos in enumerate(positions) if pos[0]==self.anchor[0] and pos[1]<=self.anchor[1]]
            if candidates:start=candidates[-1]
            elif self.anchor[0]<positions[0][0]:start=0
            end=min(len(lines),start+height)
            m.scroll=max(0,len(lines)-end)
        self.anchor=positions[start] if m.scroll and start<len(positions) else None
        transcript_start=start
        sticky=None
        if start<len(positions) and positions[start][1]>=0 and mode!='compact':
            source=positions[start][0]
            previous=next((lines[j] for j in range(start-1,-1,-1) if positions[j][0]==source and positions[j][1]==-1),None)
            role=m.line_roles.get(source)
            sticky=previous or ([(role.upper(),3 if role=='user' else 2,True)] if role else None)
        if sticky:self.spans(session.y,session.x+2,sticky,session.w-4)
        for i,parts in enumerate(lines[start:min(end,start+height-(1 if sticky else 0))]):
            self.spans(session.y+i+(1 if sticky else 0),session.x+2,parts,session.w-4)
        if not lines and session.h:
            for i,text in enumerate(('What would you like to work on?','Type a task below to start.','Ctrl+P shows commands.')):
                if i+1<session.h:self.put(session.y+1+i,session.x+2,text,session.w-4,1 if i==0 else 4,i==0)
        if panel:self.inspector(panel,mode)
        if m.approval and m.approval_preview:
            preview=[part for line in m.approval_preview.splitlines() for part in wrap(line,max(1,session.w-6))]
            height=min(session.h,len(preview)+2)
            r=Rect(session.x+1,session.y+session.h-height,max(2,session.w-2),height)
            self.regions['approval']=r
            self.box(r,'PENDING TOOL: PgUp/PgDn')
            self.panel_limits['approval']=max(0,len(preview)-height+2)
            start=min(self.model.panel_scroll.get('approval',0),max(0,len(preview)-height+2))
            self.model.panel_scroll['approval']=start
            for i,line in enumerate(preview[start:start+max(0,height-2)]):self.put(r.y+1+i,r.x+2,line,r.w-4,5)
        if self.completion():
            height=min(9,rows-6)
            if height>=3:
                r=Rect(1,max(0,rows-5-height),max(2,cols-2),height)
                self.regions['completion']=r
                self.box(r,'COMMANDS: Tab selects; Enter submits')
                self.marks=[]
                count=height-2
                start=max(0,self.completion_index-count+1)
                if not self.completion_choices:self.put(r.y+1,r.x+1,'No matching commands',r.w-2,8)
                for i,(name,description) in enumerate(self.completion_choices[start:start+count],start):
                    text=name+('  '+description if cols>=60 else '')
                    self.button(r.y+1+i-start,r.x+1,text,r.w-2,('complete',i),12 if i==self.completion_index else 5)
        # Host-owned approval and input area is drawn last, outside all overlays.
        compact=mode=='compact'
        input_y=rows-2 if compact else rows-3
        input_x=0 if compact else 3
        if not compact:self.box(Rect(1,rows-4,cols-2,3),'APPROVAL' if m.approval else '')
        notice=m.approval_prompt if m.approval else m.notice
        if compact and not m.approval:
            notice=m.status()+' | '+notice
        self.put(rows-3 if compact else rows-5,0 if compact else 2,clean(notice),cols if compact else cols-4,2 if m.approval else 4)
        prefix='approve> ' if m.approval and cols>=20 else '> '
        hints=not m.approval and not compact and cols>=110
        hint_width=39 if hints else 0
        available=max(1,cols-input_x-len(prefix)-(1 if compact else 3)-hint_width)
        visible,cursor=composer_view(m.draft,m.cursor,available)
        self.put(input_y,input_x,prefix+visible,cols-input_x,1 if compact else 5)
        if hints:
            self.spans(input_y,cols-hint_width,[('^P ',3,True),('commands  ',5,False),
                ('^C ',3,True),('cancel  ',5,False),('F2 ',3,True),('theme',5,False)],hint_width-3)
            self.hit(input_y,cols-hint_width,12,('commands',None))
            self.hit(input_y,cols-hint_width+24,8,('theme',None))
        tab_hint='Tab pane  ' if panel and (mode=='overlay' or c['placement'] not in ('top','bottom')) else ''
        if tab_hint and m.panel_tab!='work':tab_hint+='PgUp/PgDn pane  '
        footer=m.notice if m.approval else '^B sidebar  ^P commands  S-Tab mode  '+tab_hint+'^W work  ^O diff  ^C cancel  ^D quit'
        if cols<60:footer='Enter reply  Esc no  ^C cancel' if m.approval else '^P help  ^B panel  ^C cancel  ^D quit'
        if cols<36:
            footer='Esc no  ^C stop' if m.approval else '^C stop  ^D quit' if not m.ready else '^P help  ^D quit'
            if m.scroll and not m.approval:footer='PgDn latest  ^D quit'
        elif m.scroll:footer=('up '+str(m.scroll)+' | ^G latest | ^D quit') if cols<60 else 'scroll '+str(m.scroll)+' | ^G latest | '+footer
        elif transcript_start>0 and not m.approval and not compact:footer='Latest | ^G latest | ^D quit' if cols<60 else 'Latest (earlier above) | ^G latest | ^P commands | ^D quit'
        self.put(rows-1,0,footer,cols,4)
        for label,action in (('^B sidebar',('sidebar',None)),('^B panel',('sidebar',None)),('^P commands',('commands',None)),('^P help',('commands',None)),('S-Tab mode',('mode',None))):
            index=footer.find(label)
            if index>=0 and index+len(label)<=cols:self.hit(rows-1,index,len(label),action)
        self.paint_marks(self.mark_phase())
        cursor_x=min(cols-1,input_x+len(prefix)+cursor)
        try:self.screen.move(max(0,input_y),max(0,cursor_x))
        except curses.error:pass
        self.screen.refresh()

    def local(self,line):
        fields=line.split(maxsplit=1);name=fields[0];value=fields[1] if len(fields)>1 else ''
        keys={'/theme':'theme','/name':'identity','/brand':'branding','/place':'placement','/sidebar':'sidebar','/density':'density','/border':'border'}
        if name=='/theme' and not value:self.cycle_theme();return True
        if name=='/mode' and value:
            self.request_mode(value);return True
        if name in keys:
            self.child.ui({'action':'patch','patch':{keys[name]:value}});return True
        if name=='/motion':
            if value not in ('on','off'):raise ValueError('use /motion on|off')
            self.child.ui({'action':'patch','patch':{'motion':value=='on'}});return True
        if name=='/ui':
            if value=='code-reload':
                if self.reloader:self.reloader.request()
                else:self.model.notice='TUI code reload unavailable; restart required'
                return True
            if value.startswith('{'):action=json.loads(value)
            elif value.startswith('save '):action={'action':'save','scope':value[5:]}
            else:action={'action':value or 'get'}
            if action.get('action')=='session-command':raise ValueError('use /mode for explicit mode changes')
            self.child.ui(action)
            if action.get('action','get')=='get':self.model.lines.append('ui> '+json.dumps({**self.model.config,'source':self.model.source_identity}))
            return True
        return False

    def key(self,key):
        m=self.model
        active=self.completion()
        if key=='\x04':return False
        if key==curses.KEY_MOUSE:self.mouse();return True
        if key==curses.KEY_BTAB:self.request_mode();return True
        if key=='\x07':m.scroll=0;self.anchor=None;m.notice='Latest transcript';return True
        if active and key in (curses.KEY_UP,curses.KEY_DOWN):
            self.completion_index=max(0,min(len(self.completion_choices)-1,self.completion_index+(-1 if key==curses.KEY_UP else 1)))
            return True
        if active and key=='\t':
            self.accept_completion();return True
        if key=='\x1b' and (active or self.palette_draft is not None):
            self.close_completion(restore=True);return True
        if active and key in ('\n','\r',curses.KEY_ENTER):
            exact=m.draft.split(' ',1)[0] in COMMANDS or any(m.draft==choice[0] for choice in self.completion_choices)
            if self.menu or not exact:
                if self.completion_choices:self.accept_completion()
                else:m.notice='No matching commands; Esc dismisses suggestions'
                return True
        if key=='\x03':
            if not m.ready:
                self.child.process.send_signal(signal.SIGINT)
                m.activity='cancelling';m.notice='Cancelling · waiting for the session to stop'
            else:m.draft='';m.cursor=0
        elif key=='\x02':
            _,panel,mode=layout(*reversed(self.screen.getmaxyx()),m.config)
            visible=panel is not None or mode=='compact' and m.config['sidebar']=='on'
            self.child.ui({'action':'patch','patch':{'sidebar':'off' if visible else 'on'}})
        elif key=='\x10':self.open_palette()
        elif key==curses.KEY_F2:self.cycle_theme()
        elif key=='\x17':m.work=not m.work
        elif key=='\x0f':m.show_diff=not m.show_diff
        elif key=='\t' and not m.approval:
            _,panel,mode=layout(*reversed(self.screen.getmaxyx()),m.config)
            if panel and (mode=='overlay' or m.config['placement'] not in ('top','bottom')):
                tabs=self.tabs()
                m.panel_tab=tabs[(tabs.index(m.panel_tab)+1)%len(tabs)] if m.panel_tab in tabs else tabs[0]
        elif key=='\x1b':
            if m.approval:self.child.send('n');m.approval=False;m.activity='working';m.draft,m.cursor=m.pending_draft or ('',0);m.pending_draft=None;self.menu=False
            elif self.menu:self.menu=False
            else:
                _,_,mode=layout(*reversed(self.screen.getmaxyx()),m.config)
                if mode=='overlay':self.child.ui({'action':'patch','patch':{'sidebar':'off'}})
        elif key in ('\n','\r',curses.KEY_ENTER):
            line=m.draft
            if line.startswith('/mode ') and (m.approval or not m.ready):
                self.request_mode(line[6:]);return True
            try:handled=self.local(line) if line.strip() else False
            except (ValueError,KeyError) as e:m.notice='UI command rejected: '+str(e);return True
            if handled:
                m.history.append(line);m.history_index=len(m.history);m.history_draft=('',0);m.draft='';m.cursor=0
                if self.palette_draft is not None:
                    m.draft,m.cursor=self.palette_draft;self.palette_draft=None
                self.completion_dismissed=m.draft
            elif m.approval and line.lstrip().startswith('/'):
                m.notice='Finish approval before using session commands.'
            elif m.approval:
                self.child.send(line);m.approval=False;m.activity='working';m.draft,m.cursor=m.pending_draft or ('',0);m.pending_draft=None
            elif line.strip():
                if m.ready:
                    self.child.send(line);m.control('working')
                    m.history.append(line);m.history_index=len(m.history);m.history_draft=('',0);m.draft='';m.cursor=0;m.scroll=0
                else:m.notice='Turn running. Draft retained; UI commands still work.'
            if not m.draft:self.completion_dismissed=None
        elif key in (curses.KEY_BACKSPACE,'\x7f','\b'):
            if m.cursor:m.draft=m.draft[:m.cursor-1]+m.draft[m.cursor:];m.cursor-=1
        elif key==curses.KEY_DC:m.draft=m.draft[:m.cursor]+m.draft[m.cursor+1:]
        elif key==curses.KEY_LEFT:m.cursor=max(0,m.cursor-1)
        elif key==curses.KEY_RIGHT:m.cursor=min(len(m.draft),m.cursor+1)
        elif key in (curses.KEY_HOME,'\x01'):m.cursor=0
        elif key in (curses.KEY_END,'\x05'):m.cursor=len(m.draft)
        elif key=='\x15':m.draft=m.draft[m.cursor:];m.cursor=0
        elif key in (curses.KEY_PPAGE,curses.KEY_NPAGE):
            if m.approval:
                m.panel_scroll['approval']=max(0,m.panel_scroll.get('approval',0)+(-10 if key==curses.KEY_PPAGE else 10))
                return True
            _,panel,mode=layout(*reversed(self.screen.getmaxyx()),{**m.config,'sidebar':'off'} if m.approval else m.config)
            if panel and m.panel_tab in m.panel_scroll and (mode=='overlay' or m.config['placement'] not in ('top','bottom')):
                m.panel_scroll[m.panel_tab]=max(0,m.panel_scroll[m.panel_tab]+(-10 if key==curses.KEY_PPAGE else 10))
            else:
                m.scroll=max(0,min(self.scroll_limit,m.scroll+(10 if key==curses.KEY_PPAGE else -10)));self.anchor=None
        elif key in (curses.KEY_UP,curses.KEY_DOWN) and m.history and not m.approval:
            if m.history_index==len(m.history):
                m.history_draft=(m.draft,m.cursor)
            m.history_index=max(0,min(len(m.history),m.history_index+(-1 if key==curses.KEY_UP else 1)))
            if m.history_index<len(m.history):
                m.draft=m.history[m.history_index];m.cursor=len(m.draft)
            else:m.draft,m.cursor=m.history_draft
            self.completion_dismissed=m.draft
        elif isinstance(key,str) and key.isprintable() and len(m.draft)<65536:
            m.draft=m.draft[:m.cursor]+key+m.draft[m.cursor:];m.cursor+=len(key)
        return True

    def run(self):
        self.draw()
        while self.child.process.poll() is None:
            changed=self.child.poll(self.model)
            key=self.read_key()
            if key is not None:
                if not self.key(key):break
                changed=True
            if self.reloader:changed=self.reloader.check(self) or changed
            if changed:self.draw()
            elif self.marks and self.mark_phase()!=self.last_phase:
                cursor=self.screen.getyx()
                self.paint_marks(self.mark_phase())
                self.screen.move(*cursor)
                self.screen.refresh()
        self.child.poll(self.model)
        return self.child.process.poll() or 0


def main():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print('shift --tui requires a terminal; omit --tui for scripted input or use --print.',file=sys.stderr);return 2
    try:args=frontend_arguments(sys.argv[1:])
    except ValueError as error:
        print(error,file=sys.stderr);return 2
    locale.setlocale(locale.LC_ALL,'')
    saved_terminal=termios.tcgetattr(sys.stdin.fileno())
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    child=Child(args)
    model=None
    try:
        def run(screen):
            nonlocal model
            terminal=Terminal(screen,child);model=terminal.model
            # ncurses 6.0 discards X10 wheel-down (button 5). Decode escape
            # packets ourselves, including raw coordinate bytes above ASCII.
            screen.keypad(False)
            for capability,key in (('kcuu1',curses.KEY_UP),('kcud1',curses.KEY_DOWN),
                                   ('kcub1',curses.KEY_LEFT),('kcuf1',curses.KEY_RIGHT),
                                   ('khome',curses.KEY_HOME),('kend',curses.KEY_END),
                                   ('kdch1',curses.KEY_DC),('kpp',curses.KEY_PPAGE),
                                   ('knp',curses.KEY_NPAGE),('kcbt',curses.KEY_BTAB),('kf2',curses.KEY_F2)):
                sequence=curses.tigetstr(capability)
                if sequence and sequence.startswith(b'\x1b'):terminal.key_sequences[sequence[1:].decode('latin1')]=key
            terminal.acs=bool(curses.tigetstr('acsc'))
            terminal.unicode='utf' in screen.encoding.lower() and os.environ.get('TERM') not in ('vt100','vt102','ansi')
            source=identity(ROOT)
            terminal.reloader=Reloader(__file__,child.watch)
            model.source_identity={'process':source.copy(),'loaded':source.copy(),'presentation':terminal.reloader.seen.hex()[:12]}
            try:return terminal.run()
            finally:
                terminal.stop_mouse()
                terminal.restore_colors()
        return curses.wrapper(run)
    except KeyboardInterrupt:
        return 130
    finally:
        child.close()
        termios.tcsetattr(sys.stdin.fileno(),termios.TCSANOW,saved_terminal)
        if model and child.process.returncode not in (0,-signal.SIGTERM,-signal.SIGKILL):
            print('\n'.join(list(model.lines)[-12:]),file=sys.stderr)


if __name__=='__main__':sys.exit(main())
