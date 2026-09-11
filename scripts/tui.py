#!/usr/bin/env python3
"""Shift's terminal adapter. Guile owns the session, permissions and UI state."""
import codecs
import curses
import json
import locale
import os
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

ROOT = Path(__file__).resolve().parents[1]


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


def wrap(text, width):
    if width < 1:
        return []
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


@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int


def layout(cols, rows, config):
    # A compact prompt survives even in a tiny terminal.
    if rows < 12 or cols < 40:
        return Rect(0, 0, cols, max(0, rows-2)), None, 'compact'
    body = Rect(0, 4, cols, rows-7)
    session = Rect(body.x, body.y, body.w, body.h)
    place, policy = config.get('placement', 'right'), config.get('sidebar', 'auto')
    fits = cols >= 120 and body.h >= 12 if place in ('left', 'right') else body.h >= 24
    visible = policy == 'on' or policy == 'auto' and fits and place != 'modal'
    if not visible:
        return session, None, 'hidden'
    if not fits or place == 'modal':
        width, height = min(44, cols-4), min(20, body.h-2)
        x = 0 if place == 'left' else cols-width if place == 'right' else (cols-width)//2
        return session, Rect(x, body.y+(body.h-height)//2, width, height), 'overlay'
    if place in ('left', 'right'):
        width = min(36, cols//3)
        panel = Rect(0 if place == 'left' else cols-width, body.y, width, body.h)
        session.x = width if place == 'left' else 0
        session.w -= width
    else:
        height = 9
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


class Model:
    def __init__(self):
        self.config = dict(theme='acid', identity=os.environ.get('USER', 'shift'), branding='subtitle',
                           wordmark=['shift ///'], sidebar='auto', placement='right', density='comfortable', border='thin',
                           ascii=False, metrics=True, background=53, foreground=255, accent=154,
                           secondary=51, muted=183, panel=17, sections=['session','context','files','checks'])
        self.revision = 0
        self.lines = Scrollback()
        self.partial = ''
        self.ready = False
        self.approval = False
        self.approval_prompt = ''
        self.pending_draft = None
        self.session = {}
        self.usage = {}
        self.receipt = {}
        self.tools = deque(maxlen=20)
        self.notice = 'Starting Guile session…'
        self.scroll = 0
        self.work = True
        self.draft = ''
        self.cursor = 0
        self.history = []
        self.history_index = 0

    def output(self, text):
        # Bound unbroken output as well as the number of retained lines.
        self.partial += text
        while '\n' in self.partial:
            line, self.partial = self.partial.split('\n', 1)
            self.lines.append(clean(line.rstrip('\r'))[:8192])
        if len(self.partial) > 8192:
            self.lines.append(clean(self.partial[:8192]))
            self.partial = self.partial[-8192:]

    def event(self, event):
        kind, value = event.get('type'), event.get('value')
        if kind == 'ui':
            self.config, self.revision = value['config'], value['revision']
            self.notice = f'UI revision {self.revision} · /ui undo restores the previous view'
        elif kind == 'ui-error':
            self.notice = value
            self.lines.append('UI: ' + clean(value))
        elif kind == 'approval':
            self.approval_prompt = value
        elif kind == 'history':
            for message in value:
                if message.get('role') in ('user','assistant') and isinstance(message.get('content'),str):
                    self.output(message['role']+'> '+message['content']+'\n')
        elif kind == 'session':
            self.session = value
        elif kind == 'usage':
            self.usage = value
        elif kind == 'receipt':
            self.receipt = value
        elif kind == 'tool':
            self.tools.append(value)


class Child:
    def __init__(self, args, cwd=None):
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
                    else:
                        state=event.get('state')
                        model.ready=state=='ready'
                        if state=='needs_approval' and not model.approval:
                            model.pending_draft=(model.draft,model.cursor)
                            model.draft='';model.cursor=0;model.scroll=0
                        model.approval=state=='needs_approval'
                        if model.ready and model.pending_draft is not None:
                            model.draft,model.cursor=model.pending_draft;model.pending_draft=None
                        if model.ready:
                            model.approval_prompt=''
                            model.notice='Ready · /ui get · /help'
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
        self.menu=False
        self.anchor=None
        screen.keypad(True)
        screen.timeout(50)
        curses.raw()
        try: curses.curs_set(1)
        except curses.error: pass

    def colors(self):
        c=self.model.config
        signature=tuple(c.get(k) for k in ('foreground','background','accent','secondary','muted','panel'))
        if signature==self.palette:return
        self.palette=signature
        if not curses.has_colors():return
        def color(n):
            if curses.COLORS>=256:return n
            return {53:0,255:7,154:2,51:6,183:5,17:0,230:7,235:0,160:1,22:2,240:0,187:7,18:4,229:3,153:6,19:4}.get(n,n%8)
        for i,key in enumerate(('foreground','accent','secondary','muted'),1):
            curses.init_pair(i,color(c[key]),color(c['background']))
        curses.init_pair(5,color(c['foreground']),color(c['panel']))
        self.screen.bkgd(' ',curses.color_pair(1))

    def put(self,y,x,text,width,color=1,bold=False):
        rows,cols=self.screen.getmaxyx()
        if y<0 or y>=rows or x<0 or x>=cols:return
        text=clip(text,min(width,cols-x))
        try:self.screen.addstr(y,x,text,curses.color_pair(color)|(curses.A_BOLD if bold else 0))
        except curses.error:pass # writing the bottom-right cell may report ERR

    def box(self,r,title):
        if r.w<2 or r.h<2:return
        c=self.model.config
        border=c.get('border','thin')
        glyph='-' if c.get('ascii') else {'thin':'─','heavy':'━','double':'═','none':' '}.get(border,'─')
        for y in range(r.y,r.y+r.h):self.put(y,r.x,' '*r.w,r.w,5)
        self.put(r.y,r.x,glyph*r.w,r.w,3)
        self.put(r.y+r.h-1,r.x,glyph*r.w,r.w,3)
        self.put(r.y,r.x+1,' '+title+' ',r.w-2,2,True)

    def sections(self):
        m=self.model
        tokens=m.usage.get('prompt',0);limit=m.usage.get('limit')
        changed=m.receipt.get('changed',[])
        runs=m.receipt.get('runs',[])
        return {
          'session':['SESSION',str(m.session.get('name','default')),m.session.get('model','loading'),
                     'Mode: '+m.session.get('mode','—'),'Turn: '+str(m.session.get('turn','—'))],
          'context':['CONTEXT',f'{tokens:,} / {limit or "unknown"}',
                     f'Round {m.usage.get("round",0)} / {m.usage.get("max_rounds","—")}',
                     'UI revision '+str(m.revision)],
          'files':['FILES']+[f'{v.get("path", "")} +{v.get("added",0)} -{v.get("removed",0)}' for v in changed],
          'checks':['CHECKS']+[str(v.get('argv',v.get('command','run')))+' exit '+str(v.get('exit_code','?')) for v in runs]
        }

    def draw(self):
        self.colors();self.screen.erase()
        m=self.model;c=m.config;rows,cols=self.screen.getmaxyx()
        session,panel,mode=layout(cols,rows,{**c,'sidebar':'off'} if m.approval else c)
        if mode!='compact':
            brand=c['identity'] if c['branding']=='replace' else 'shift'
            if c['branding']=='none':brand=''
            title=(brand+' ///') if brand else c['identity']
            logo=c.get('wordmark',['shift ///']) if c['branding']=='subtitle' and not c.get('ascii') else [title]
            logo_width=max(sum(cell_width(ch) for ch in line) for line in logo)
            status=f'{m.session.get("model","starting")} | {m.session.get("mode","manual")} | '+('APPROVAL' if m.approval else 'READY' if m.ready else 'WORKING')
            if cols>=logo_width+45 and c['density']!='compact':
                for y,line in enumerate(logo[:3]):self.put(y,1,line,logo_width,2,True)
                self.put(0,logo_width+4,c['identity'] if c['branding']=='subtitle' else Path.cwd().name,cols-logo_width-5,3)
                self.put(1,logo_width+4,status,cols-logo_width-5,3)
                self.put(2,logo_width+4,Path.cwd().name+' / '+str(m.session.get('name','default')),cols-logo_width-5,4)
            else:
                self.put(0,1,title,cols-2,2,True)
                self.put(1,1,c['identity'] if c['branding']=='subtitle' else Path.cwd().name,cols-2,3)
                self.put(2,1,status,cols-2,3)
            self.put(3,0,('-' if c.get('ascii') else '─')*cols,cols,4)
        lines=[];positions=[]
        for source,line in enumerate(list(m.lines)+[m.partial],m.lines.origin):
            if c['density']=='compact' and not line.strip():continue
            if not m.work and (line.startswith('tool>') or line.startswith('      ')):continue
            offset=0
            for segment in wrap(line,max(1,session.w-2)):
                lines.append(segment);positions.append((source,offset));offset+=len(segment)
        height=session.h
        end=max(0,len(lines)-m.scroll)
        start=max(0,end-height)
        if m.scroll and self.anchor and positions:
            candidates=[i for i,pos in enumerate(positions) if pos[0]==self.anchor[0] and pos[1]<=self.anchor[1]]
            if candidates:start=candidates[-1]
            elif self.anchor[0]<positions[0][0]:start=0
            end=min(len(lines),start+height)
            m.scroll=max(0,len(lines)-end)
        self.anchor=positions[start] if m.scroll and start<len(positions) else None
        for i,line in enumerate(lines[start:end]):
            color=2 if line.startswith('you>') else 3 if line.startswith('tool>') else 1
            self.put(session.y+i,session.x+1,line,session.w-2,color)
        if panel:
            self.box(panel,'INSPECTOR · '+c['placement'])
            sections=self.sections()
            chosen=[k for k in c['sections'] if c.get('metrics',True) or k!='context']
            horizontal=mode=='docked' and c['placement'] in ('top','bottom')
            if horizontal:
                col_width=max(1,(panel.w-2)//max(1,len(chosen)))
                for i,key in enumerate(chosen):
                    for j,line in enumerate(sections[key][:panel.h-2]):
                        self.put(panel.y+1+j,panel.x+1+i*col_width,line,col_width-1,3 if j==0 else 5,j==0)
            else:
                y=panel.y+1
                for key in chosen:
                    for j,line in enumerate(sections[key]):
                        if y>=panel.y+panel.h-1:break
                        self.put(y,panel.x+1,line,panel.w-2,3 if j==0 else 5,j==0);y+=1
                    y+=1
        if self.menu and not m.approval:
            r=Rect(max(0,(cols-62)//2),max(0,(rows-12)//2),min(cols,62),min(rows-3,12))
            self.box(r,'COMMANDS · Escape closes')
            for i,line in enumerate(['F2 theme     Ctrl+B inspector    Ctrl+W work',
                '/theme acid|paddock|blueprint','/name thrashr888    /brand replace|subtitle|none',
                '/place left|right|top|bottom|modal','/sidebar auto|on|off    /density compact|comfortable',
                '/ui get|undo|reload|save user|save project',
                '/ui {"action":"patch","patch":{"accent":154}}',
                'PageUp/PageDown scroll    Ctrl+C cancel    Ctrl+D quit']):
                if i<r.h-2:self.put(r.y+1+i,r.x+1,line,r.w-2,5)
        # Host-owned approval and input area is drawn last, outside all overlays.
        self.put(rows-3,0,clean(m.approval_prompt if m.approval else m.notice),cols,2 if m.approval else 4)
        prefix='approve> ' if m.approval else '> '
        available=max(1,cols-len(prefix)-1)
        before=m.draft[:m.cursor]
        offset=max(0,sum(cell_width(ch) for ch in before)-available+1)
        visible='';used=0
        for ch in m.draft:
            if used>=offset:visible+=ch
            used+=cell_width(ch)
        self.put(rows-2,0,prefix+clip(visible,available),cols,1)
        self.put(rows-1,0,'^B inspector  ^P commands  F2 theme  ^C cancel  ^D quit'+(' | scroll '+str(m.scroll) if m.scroll else ''),cols,4)
        cursor_x=min(cols-1,len(prefix)+sum(cell_width(ch) for ch in before)-offset)
        try:self.screen.move(max(0,rows-2),max(0,cursor_x))
        except curses.error:pass
        self.screen.refresh()

    def local(self,line):
        fields=line.split(maxsplit=1);name=fields[0];value=fields[1] if len(fields)>1 else ''
        keys={'/theme':'theme','/name':'identity','/brand':'branding','/place':'placement','/sidebar':'sidebar','/density':'density','/border':'border'}
        if name in keys:
            self.child.ui({'action':'patch','patch':{keys[name]:value}});return True
        if name=='/ui':
            if value.startswith('{'):action=json.loads(value)
            elif value.startswith('save '):action={'action':'save','scope':value[5:]}
            else:action={'action':value or 'get'}
            self.child.ui(action)
            if action['action']=='get':self.model.lines.append('ui> '+json.dumps(self.model.config))
            return True
        return False

    def key(self,key):
        m=self.model
        if key=='\x04':return False
        if key=='\x03':
            if not m.ready:self.child.process.send_signal(signal.SIGINT)
            else:m.draft='';m.cursor=0
        elif key=='\x02':
            _,panel,_=layout(*reversed(self.screen.getmaxyx()),m.config)
            self.child.ui({'action':'patch','patch':{'sidebar':'off' if panel else 'on'}})
        elif key=='\x10':self.menu=not self.menu
        elif key==curses.KEY_F2:
            themes=['acid','paddock','blueprint'];current=m.config['theme']
            self.child.ui({'action':'patch','patch':{'theme':themes[(themes.index(current)+1)%3] if current in themes else 'acid'}})
        elif key=='\x17':m.work=not m.work
        elif key=='\x1b':
            if self.menu:self.menu=False
            elif m.approval:self.child.send('n');m.approval=False;m.draft,m.cursor=m.pending_draft or ('',0);m.pending_draft=None
            else:
                _,_,mode=layout(*reversed(self.screen.getmaxyx()),m.config)
                if mode=='overlay':self.child.ui({'action':'patch','patch':{'sidebar':'off'}})
        elif key in ('\n','\r',curses.KEY_ENTER):
            line=m.draft
            if m.approval:
                self.child.send(line);m.approval=False;m.draft,m.cursor=m.pending_draft or ('',0);m.pending_draft=None
            elif line.strip():
                try:handled=self.local(line)
                except (ValueError,KeyError) as e:m.notice='UI command rejected: '+str(e);return True
                if handled or m.ready:
                    if not handled:
                        self.child.send(line);m.ready=False;m.lines.append('you> '+line)
                    m.history.append(line);m.history_index=len(m.history);m.draft='';m.cursor=0;m.scroll=0
                else:m.notice='Turn running. Draft retained; UI commands still work.'
        elif key in (curses.KEY_BACKSPACE,'\x7f','\b'):
            if m.cursor:m.draft=m.draft[:m.cursor-1]+m.draft[m.cursor:];m.cursor-=1
        elif key==curses.KEY_DC:m.draft=m.draft[:m.cursor]+m.draft[m.cursor+1:]
        elif key==curses.KEY_LEFT:m.cursor=max(0,m.cursor-1)
        elif key==curses.KEY_RIGHT:m.cursor=min(len(m.draft),m.cursor+1)
        elif key in (curses.KEY_HOME,'\x01'):m.cursor=0
        elif key in (curses.KEY_END,'\x05'):m.cursor=len(m.draft)
        elif key=='\x15':m.draft=m.draft[m.cursor:];m.cursor=0
        elif key==curses.KEY_PPAGE:m.scroll=min(100000,m.scroll+10);self.anchor=None
        elif key==curses.KEY_NPAGE:m.scroll=max(0,m.scroll-10);self.anchor=None
        elif key in (curses.KEY_UP,curses.KEY_DOWN) and m.history:
            m.history_index=max(0,min(len(m.history),m.history_index+(-1 if key==curses.KEY_UP else 1)))
            m.draft=m.history[m.history_index] if m.history_index<len(m.history) else '';m.cursor=len(m.draft)
        elif isinstance(key,str) and key.isprintable() and len(m.draft)<65536:
            m.draft=m.draft[:m.cursor]+key+m.draft[m.cursor:];m.cursor+=len(key)
        return True

    def run(self):
        self.draw()
        while self.child.process.poll() is None:
            changed=self.child.poll(self.model)
            try:key=self.screen.get_wch()
            except curses.error:key=None
            if key is not None:
                if not self.key(key):break
                changed=True
            if changed:self.draw()
        self.child.poll(self.model)
        return self.child.process.poll() or 0


def main():
    args=[a for a in sys.argv[1:] if a!='--tui']
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print('shift --tui requires a terminal; use the REPL or --print for pipes.',file=sys.stderr);return 2
    if any(a in args for a in ('--print','-p','--mcp','--mcp-stdio','--list-sessions','session-fork')):
        print('--tui cannot be combined with print, MCP stdio, or session maintenance.',file=sys.stderr);return 2
    locale.setlocale(locale.LC_ALL,'')
    saved_terminal=termios.tcgetattr(sys.stdin.fileno())
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    child=Child(args)
    model=None
    try:
        def run(screen):
            nonlocal model
            terminal=Terminal(screen,child);model=terminal.model
            return terminal.run()
        return curses.wrapper(run)
    except KeyboardInterrupt:
        return 130
    finally:
        child.close()
        termios.tcsetattr(sys.stdin.fileno(),termios.TCSANOW,saved_terminal)
        if model and child.process.returncode not in (0,-signal.SIGTERM,-signal.SIGKILL):
            print('\n'.join(list(model.lines)[-12:]),file=sys.stderr)


if __name__=='__main__':sys.exit(main())
