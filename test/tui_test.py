"""Real Guile bridge, cell geometry, and a real terminal lifecycle; no model load."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('shift_tui',ROOT/'scripts/tui.py')
tui=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=tui
spec.loader.exec_module(tui)

class Layout(unittest.TestCase):
    def test_layouts_fit_and_keep_composer_clear(self):
        for cols in (20,40,80,110,120,160):
            for rows in (8,16,24,40,48):
                for place in ('left','right','top','bottom','modal'):
                    for policy in ('auto','on','off'):
                        session,panel,mode=tui.layout(cols,rows,{'placement':place,'sidebar':policy})
                        for r in (session,panel):
                            if r:
                                self.assertGreaterEqual(r.x,0);self.assertGreaterEqual(r.y,0)
                                self.assertLessEqual(r.x+r.w,cols)
                                self.assertLessEqual(r.y+r.h,rows-2 if mode=='compact' else rows-3)
                        if panel and mode=='docked':
                            a,b=session,panel
                            self.assertTrue(a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y)
                        if policy=='off':self.assertIsNone(panel)

    def test_scrolled_transcript_keeps_anchor_during_output_and_resize(self):
        class Screen:
            size=(24,80)
            def getmaxyx(self): return self.size
            def erase(self): pass
            def move(self,*args): pass
            def refresh(self): pass
        terminal=tui.Terminal.__new__(tui.Terminal)
        terminal.screen=Screen();terminal.model=tui.Model();terminal.menu=False;terminal.anchor=None
        terminal.colors=lambda:None;terminal.put=lambda *args:None
        for i in range(100):terminal.model.lines.append(f'line {i}: '+('x'*90))
        terminal.model.scroll=30;terminal.draw();anchor=terminal.anchor
        for i in range(20):terminal.model.lines.append(f'new output {i}')
        terminal.draw();self.assertEqual(terminal.anchor,anchor)
        terminal.screen.size=(40,120);terminal.draw()
        self.assertEqual(terminal.anchor[0],anchor[0])
        self.assertLessEqual(terminal.anchor[1],anchor[1])

    def test_cell_width_clipping_and_controls(self):
        self.assertEqual(tui.clip('A界B',3),'A界')
        self.assertEqual(tui.clip('e\u0301Z',1),'e\u0301')
        self.assertNotIn('\x1b',tui.clip('\x1b[2J',20))
        self.assertEqual(tui.wrap('界界',2),['界','界'])

class Bridge(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='shift-tui-test-')
        self.path=Path(self.temp.name)
        self.env=patch.dict(os.environ,{'XDG_CONFIG_HOME':str(self.path/'config')})
        self.env.start()
        self.args=['--agent',str(ROOT/'test/session-agent.scm'),'--state-dir',str(self.path/'state'),
                   '--session','test','--no-watch']
        self.child=tui.Child(self.args);self.model=tui.Model()
        self.wait(lambda:self.model.ready)

    def tearDown(self):
        self.child.close();self.env.stop();self.temp.cleanup()

    def wait(self,predicate,timeout=8):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            self.child.poll(self.model)
            if predicate():return
            if self.child.process.poll() is not None:
                self.fail('child exited: '+str(list(self.model.lines)))
            time.sleep(.02)
        self.fail('timed out: '+str(list(self.model.lines)))

    def test_live_preferences_resume_and_theme_save_reload(self):
        self.child.ui({'action':'patch','patch':{'identity':'thrashr888','branding':'replace'}})
        self.wait(lambda:self.model.config['branding']=='replace')
        self.model.draft='keep typing';self.model.cursor=4
        old=self.model.revision
        self.child.ui({'action':'patch','patch':{'theme':'blueprint','placement':'top'}})
        self.wait(lambda:self.model.revision>old)
        self.assertEqual((self.model.draft,self.model.cursor),('keep typing',4))
        self.assertEqual(self.model.config['placement'],'top')
        old=self.model.revision
        self.child.ui({'action':'patch','patch':{'mode':'auto'}})
        self.wait(lambda:'rejected' in self.model.notice)
        self.assertEqual(self.model.revision,old)
        pack=self.path/'state/themes/custom.scm';pack.parent.mkdir(parents=True)
        pack.write_text('((background . 22))')
        self.child.ui({'action':'patch','patch':{'theme':'custom'}})
        self.wait(lambda:self.model.config['background']==22)
        pack.write_text('((background . 24))')
        self.wait(lambda:self.model.config['background']==24)
        old=self.model.revision
        pack.write_text('(bad data)')
        self.wait(lambda:'rejected' in self.model.notice)
        self.assertEqual(self.model.revision,old)
        self.child.ui({'action':'undo'})
        self.wait(lambda:self.model.config['background']==22)
        self.child.send('hello');self.model.ready=False
        self.wait(lambda:self.model.ready)
        checkpoint=json.loads((self.path/'state/sessions/test/session.json').read_text())
        self.assertTrue(any(m.get('content')=='hello' for m in checkpoint['history']))
        self.child.close()
        # Repair the edited pack; resumed history and identity must be real.
        pack.write_text('((background . 22))')
        self.child=tui.Child(self.args);self.model=tui.Model()
        self.wait(lambda:self.model.ready)
        self.assertEqual(self.model.config['identity'],'thrashr888')
        self.assertTrue(any('hello' in s for s in self.model.lines))

class PTY(unittest.TestCase):
    def test_actual_terminal_input_resize_and_clean_exit(self):
        with tempfile.TemporaryDirectory(prefix='shift-pty-') as tmp:
            master,slave=pty.openpty()
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
            before=termios.tcgetattr(slave)
            process=subprocess.Popen([sys.executable,str(ROOT/'scripts/tui.py'),'--tui',
                '--agent',str(ROOT/'test/session-agent.scm'),'--no-watch','--session','pty',
                '--state-dir',tmp+'/state'],stdin=slave,stdout=slave,stderr=slave,
                env={**os.environ,'TERM':'xterm-256color','XDG_CONFIG_HOME':tmp+'/config'},start_new_session=True)
            data=b''
            def wait_for(predicate):
                nonlocal data
                end=time.monotonic()+10
                while time.monotonic()<end:
                    if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                    if predicate():return
                    if process.poll() is not None:break
                self.fail(data[-5000:].decode(errors='replace'))
            try:
                wait_for(lambda:b'READY' in data)
                os.write(master,b'/name racer\n')
                prefs=Path(tmp)/'state/sessions/pty/ui.json'
                wait_for(lambda:prefs.exists() and json.loads(prefs.read_text()).get('identity')=='racer')
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
                process.send_signal(signal.SIGWINCH)
                os.write(master,b'hello\n')
                checkpoint=Path(tmp)/'state/sessions/pty/session.json'
                wait_for(lambda:checkpoint.exists() and any(m.get('content')=='hello' for m in json.loads(checkpoint.read_text())['history']))
                os.write(master,b'\x04')
                wait_for(lambda:process.poll() is not None)
                self.assertEqual(process.returncode,0,data.decode(errors='replace'))
                after=termios.tcgetattr(slave)
                # macOS sets PENDIN when canonical input is restored; it is a
                # transient pending-input marker, not a changed terminal mode.
                after[3] &= ~getattr(termios,'PENDIN',0)
                before[3] &= ~getattr(termios,'PENDIN',0)
                self.assertEqual(after,before)
                self.assertIn(b'\x1b[?1049l',data+os.read(master,65536) if select.select([master],[],[],.1)[0] else data)
            finally:
                if process.poll() is None:process.kill();process.wait()
                os.close(master);os.close(slave)

if __name__=='__main__':unittest.main()
