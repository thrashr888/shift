"""Bounded wheel reversal, including ncurses 6.0's unsupported X10 button five."""
import fcntl
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
from unittest.mock import Mock

from tui_test import ROOT, terminal_view, tui


class Wheel(unittest.TestCase):
    def test_bursts_clamp_before_redraw_and_reverse_immediately(self):
        t=terminal_view(24,80,Mock())
        t.model.control('ready');t.model.draft='draft';t.model.cursor=2
        for i in range(200):t.model.output('line '+str(i)+'\n')
        t.draw()
        for _ in range(10000):t.pointer(5,10,'up')
        self.assertEqual(t.model.scroll,t.scroll_limit)
        t.draw();before=t.screen.line(7)
        t.pointer(5,10,'down');t.draw()
        self.assertEqual(t.model.scroll,t.scroll_limit-3)
        self.assertNotEqual(before,t.screen.line(7))
        self.assertEqual((t.model.draft,t.model.cursor),('draft',2))
        for _ in range(10000):t.pointer(5,10,'down')
        self.assertEqual(t.model.scroll,0)
        t.screen.size=(40,120);t.draw()
        t.model.lines.clear();t.draw()
        self.assertEqual((t.model.scroll,t.scroll_limit),(0,0))

    def test_raw_sgr_and_x10_decode_both_directions_and_high_coordinates(self):
        t=terminal_view(40,160,Mock())
        for i in range(200):t.model.output('row '+str(i)+'\n')
        t.draw();t.screen.timeout=Mock()
        for packet in ('[<64;6;10M','[<65;6;10M','[M'+chr(96)+chr(38)+chr(42),
                       '[M'+chr(97)+chr(38)+chr(42)):
            t.screen.get_wch=Mock(return_value='\x1b')
            t.screen.getch=Mock(side_effect=[ord(ch) for ch in packet])
            previous=t.model.scroll
            t.read_key()
            self.assertNotEqual(t.model.scroll,previous)
        self.assertEqual(t.model.scroll,0)
        t.model.config.update(sidebar='off');t.draw()
        for button,expected in ((96,3),(97,0)):
            t.screen.getch=Mock(side_effect=[ord('['),ord('M'),button,152,42])
            t.read_key()
            self.assertEqual(t.model.scroll,expected)
        t.child.send.assert_not_called()

    def test_actual_pty_rapid_legacy_and_sgr_reversal(self):
        with tempfile.TemporaryDirectory(prefix='shift-wheel-') as tmp:
            state=Path(tmp)/'view.json'
            code=("import sys,json\nsys.path.insert(0,"+repr(str(ROOT/'scripts'))+")\nimport tui\n"
                  "draw=tui.Terminal.draw\n"
                  "def render(self):\n draw(self)\n"
                  " with open("+repr(str(state))+",'w') as f:json.dump({'scroll':self.model.scroll,'limit':self.scroll_limit,'draft':self.model.draft,'ready':self.model.ready},f)\n"
                  "tui.Terminal.draw=render\nsys.exit(tui.main())\n")
            master,slave=pty.openpty()
            os.set_blocking(master,False)
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
            process=subprocess.Popen([sys.executable,'-c',code,'--no-watch','--session','wheel','--state-dir',tmp+'/state',
                '--set','agent-model="demo"',' '.join('word'+str(i) for i in range(1400))],
                stdin=slave,stdout=slave,stderr=slave,start_new_session=True,
                env={**os.environ,'TERM':'xterm-256color','XDG_CONFIG_HOME':tmp+'/config'})
            output=b''
            def send(payload):
                nonlocal output
                end=time.monotonic()+15
                while payload:
                    self.assertLess(time.monotonic(),end,output[-3000:].decode(errors='replace'))
                    self.assertIsNone(process.poll(),output[-3000:].decode(errors='replace'))
                    readable,writable,_=select.select([master],[master],[],.03)
                    if readable:output+=os.read(master,65536)
                    if writable:
                        try:payload=payload[os.write(master,payload[:128]):]
                        except BlockingIOError:pass
            def wait_for(predicate):
                nonlocal output
                end=time.monotonic()+15
                while time.monotonic()<end:
                    if select.select([master],[],[],.03)[0]:output+=os.read(master,65536)
                    try:data=json.loads(state.read_text())
                    except (FileNotFoundError,json.JSONDecodeError):continue
                    if predicate(data):return data
                    if process.poll() is not None:break
                self.fail(output[-3000:].decode(errors='replace'))
            try:
                wait_for(lambda d:d['ready'] and d['limit']>50)
                for up,down in ((b'\x1b[M`&*',b'\x1b[Ma&*'),(b'\x1b[<64;6;10M',b'\x1b[<65;6;10M')):
                    send(b'\x15'+up*300+b'z')
                    top=wait_for(lambda d:d['draft']=='z' and d['scroll']==d['limit'])
                    send(down+b'x')
                    reversed_=wait_for(lambda d:d['draft']=='zx')
                    self.assertEqual(reversed_['scroll'],top['scroll']-3)
                    send(down*300+b'y')
                    bottom=wait_for(lambda d:d['draft']=='zxy')
                    self.assertEqual(bottom['scroll'],0)
                send(b'\x04')
                end=time.monotonic()+10
                while process.poll() is None and time.monotonic()<end:
                    if select.select([master],[],[],.03)[0]:output+=os.read(master,65536)
                self.assertEqual(process.poll(),0)
            finally:
                if process.poll() is None:os.killpg(process.pid,signal.SIGKILL)
                process.wait(timeout=5);os.close(master);os.close(slave)


if __name__=='__main__':unittest.main()
