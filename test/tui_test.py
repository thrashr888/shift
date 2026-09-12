"""Real Guile bridge, cell geometry, and a real terminal lifecycle; no model load."""
import fcntl
import copy
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
spec=importlib.util.spec_from_file_location('shift_tui',ROOT/'scripts/tui.py')
tui=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=tui
spec.loader.exec_module(tui)


class Screen:
    def __init__(self, rows=24, cols=80):
        self.size=(rows,cols)
        self.erase()

    def getmaxyx(self):return self.size
    def erase(self):self.grid=[[' ']*self.size[1] for _ in range(self.size[0])]
    def move(self,y,x):self.cursor=(y,x)
    def getyx(self):return self.cursor
    def refresh(self):pass
    def clearok(self,flag):self.clear_requested=flag

    def put(self,y,x,text,width,*style):
        rows,cols=self.size
        if not (0<=y<rows and 0<=x<cols):return
        for ch in tui.clip(text,min(width,cols-x)):
            size=tui.cell_width(ch)
            if size:
                self.grid[y][x]=ch
                for i in range(1,size):self.grid[y][x+i]=''
                x+=size
            elif x:
                self.grid[y][x-1]+=ch

    def line(self,y):return ''.join(self.grid[y])


def terminal_view(rows=24,cols=80,child=None):
    terminal=tui.Terminal.__new__(tui.Terminal)
    terminal.screen=Screen(rows,cols);terminal.model=tui.Model()
    terminal.menu=False;terminal.anchor=None;terminal.child=child
    terminal.init_interactions()
    terminal.colors=lambda:None;terminal.put=terminal.screen.put
    return terminal


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
                                self.assertLessEqual(r.y+r.h,rows-3 if mode=='compact' else rows-5)
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
            def clearok(self,flag): pass
        terminal=tui.Terminal.__new__(tui.Terminal)
        terminal.screen=Screen();terminal.model=tui.Model();terminal.menu=False;terminal.anchor=None
        terminal.init_interactions()
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

    def test_compact_transcript_does_not_lose_last_line_to_notice(self):
        terminal=terminal_view(8,20)
        terminal.model.output('\n'.join(f'line {i}' for i in range(20)))
        terminal.draw()
        self.assertIn('line 19',terminal.screen.line(4))
        self.assertNotIn('line 19',terminal.screen.line(5))

    def test_tiny_footer_keeps_exit_and_approval_controls_readable(self):
        terminal=terminal_view(8,20)
        terminal.model.control('ready');terminal.draw()
        self.assertIn('^D quit',terminal.screen.line(7))
        terminal.model.control('working');terminal.draw()
        self.assertIn('^C stop',terminal.screen.line(7))
        self.assertIn('^D quit',terminal.screen.line(7))
        terminal.model.control('needs_approval');terminal.draw()
        self.assertIn('Esc no',terminal.screen.line(7))
        self.assertIn('^C stop',terminal.screen.line(7))

    def test_pageup_clamps_to_first_full_page(self):
        terminal=terminal_view()
        terminal.model.output('\n'.join(f'line {i}' for i in range(100)))
        for _ in range(30):
            terminal.key(tui.curses.KEY_PPAGE)
            terminal.draw()
        self.assertEqual(terminal.anchor,(0,0))
        self.assertIn('line 0',terminal.screen.line(7))
        self.assertIn('scroll',terminal.screen.line(23))
        terminal.key(tui.curses.KEY_NPAGE);terminal.draw()
        self.assertEqual(terminal.anchor,(10,0))

    def test_bottom_telemetry_docks_only_when_readable(self):
        config={'placement':'bottom','sidebar':'on'}
        self.assertEqual(tui.layout(40,40,config)[2],'overlay')
        self.assertEqual(tui.layout(71,40,config)[2],'overlay')
        session,panel,mode=tui.layout(72,40,config)
        self.assertEqual(mode,'docked')
        self.assertEqual(panel.h,3)
        self.assertEqual(session.w,72)
        self.assertEqual(tui.layout(22,40,config)[2],'compact')
        self.assertEqual(tui.layout(40,40,{**config,'sidebar':'auto'})[2],'hidden')

    def test_compact_inspector_toggle_can_turn_off_before_resize(self):
        terminal=terminal_view(8,20,child=Mock())
        terminal.model.config['sidebar']='on'
        terminal.key('\x02')
        terminal.child.ui.assert_called_once_with({'action':'patch','patch':{'sidebar':'off'}})

    def test_restored_history_navigation_preserves_unsubmitted_draft_and_cursor(self):
        terminal=terminal_view()
        m=terminal.model
        m.event({'type':'input-history','value':['first','second','/quit']})
        m.draft='keep draft';m.cursor=4
        terminal.key(tui.curses.KEY_UP)
        self.assertEqual(m.draft,'/quit')
        terminal.key(tui.curses.KEY_UP)
        self.assertEqual(m.draft,'second')
        terminal.key(tui.curses.KEY_DOWN);terminal.key(tui.curses.KEY_DOWN)
        self.assertEqual((m.draft,m.cursor),('keep draft',4))
        m.control('needs_approval')
        terminal.key(tui.curses.KEY_UP)
        self.assertEqual(m.draft,'')
    def test_wide_composer_cursor_uses_whole_character_scroll_offset(self):
        terminal=terminal_view(8,20)
        terminal.model.draft='界'*9+'a';terminal.model.cursor=10
        terminal.draw()
        self.assertEqual(terminal.screen.line(6).rstrip(),'> '+'界'*7+'a')
        self.assertEqual(terminal.screen.cursor,(6,17))
        for draft in ('abcdef','界界a','e\u0301界abc','界'*20):
            for cursor in range(len(draft)+1):
                for width in (1,2,5,17):
                    visible,x=tui.composer_view(draft,cursor,width)
                    self.assertLess(sum(tui.cell_width(ch) for ch in visible),width+1)
                    self.assertTrue(0<=x<width,(draft,cursor,width,visible,x))
                    if visible:self.assertGreater(tui.cell_width(visible[0]),0)

    def test_status_survives_a_long_model_name(self):
        terminal=terminal_view(24,40)
        terminal.model.session={'model':'long-model-name-'*10,'mode':'manual'}
        terminal.model.approval=True
        terminal.draw()
        self.assertIn('APPROVAL',terminal.screen.line(5))
        self.assertIn('MANUAL',terminal.screen.line(5))

    def test_empty_state_and_persistent_composer_frame(self):
        terminal=terminal_view()
        terminal.draw()
        self.assertIn('What would you like to work on?',terminal.screen.line(8))
        self.assertNotIn('MESSAGE',terminal.screen.line(20))
        self.assertIn('─',terminal.screen.line(20))
        self.assertEqual(terminal.screen.cursor,(21,5))
        self.assertEqual(terminal.screen.line(21)[1],'│')
        self.assertEqual(terminal.screen.line(21)[78],'│')

    def test_actual_transcript_roles_and_work_are_distinct(self):
        terminal=terminal_view(40,100)
        terminal.model.output('you> hello\nassistant> hello back\ntool> read notes.txt\n      done\n')
        terminal.draw()
        text='\n'.join(terminal.screen.line(i) for i in range(40))
        for label in ('USER','SHIFT','WORK  read notes.txt'):self.assertIn(label,text)
        self.assertNotIn('What would you like',text)
        terminal.key('\x17');terminal.draw()
        self.assertNotIn('WORK  read','\n'.join(terminal.screen.line(i) for i in range(40)))

    def test_approval_question_is_shown_once_outside_the_transcript(self):
        terminal=terminal_view()
        terminal.model.control('needs_approval')
        terminal.model.approval_prompt='Approve tool? [y/N]'
        terminal.model.output('Tool requests: read\n{"path":"notes.txt"}\nApprove tool? [y/N]')
        terminal.draw()
        text='\n'.join(terminal.screen.line(i) for i in range(24))
        self.assertEqual(text.count('Approve tool? [y/N]'),1)
        self.assertIn('notes.txt',text)
        self.assertIn('Type a reply, then Enter',text)

    def test_dark_palette_and_reduced_color_backgrounds(self):
        self.assertEqual(tui.Model().config['background'],'#170626')
        self.assertEqual(tui.terminal_color('#170626',1<<24),0x170626)
        self.assertEqual(tui.terminal_color('#170626',8,True),0)
        self.assertEqual(tui.ansi_rgb(53),(95,0,95))
        self.assertEqual(tui.terminal_color(232,1<<24),0x080808)
        self.assertEqual(tui.terminal_color(154,1<<24),0xafff00)
        for count in (8,16):
            for color in (232,233,53):
                self.assertEqual(tui.terminal_color(color,count,True),0)
            self.assertEqual(tui.terminal_color(230,count,True),7)
            self.assertEqual(tui.terminal_color(235,count),0)
            self.assertEqual(tui.terminal_color(255,count),7)
        for n in range(256):
            self.assertEqual(tui.terminal_color(n,256),n)
            self.assertTrue(0<=tui.terminal_color(n,8)<8)

    def test_monochrome_does_not_reference_uninitialized_color_pairs(self):
        terminal=terminal_view()
        terminal.screen.addstr=Mock()
        with patch.object(tui.curses,'has_colors',return_value=False), patch.object(tui.curses,'color_pair') as color_pair:
            tui.Terminal.put(terminal,0,0,'READY',20,7,True)
            color_pair.assert_not_called()
        terminal.screen.addstr.assert_called_once_with(0,0,'READY',tui.curses.A_BOLD)


class StructuredViews(unittest.TestCase):
    def active(self,placement='right',cols=128,rows=40):
        terminal=terminal_view(rows,cols,Mock())
        m=terminal.model
        m.config['placement']=placement
        for kind,value in [
            ('session',{'name':'main','model':'local fixture','mode':'accept','turn':1}),
            ('turn-start',{'turn':1}),
            ('transcript',{'role':'user','text':'Trace the run allowlist.'}),
            ('transcript',{'role':'assistant','text':'I will trace settings and add source labels.','stream':True}),
            ('transcript',{'role':'assistant','text':'','stream':True,'end':True}),
            ('tool',{'turn':1,'id':1,'name':'read','summary':'settings.scm','at':'17:14'}),
            ('tool-result',{'turn':1,'id':1,'ok':True,'summary':'Read settings'}),
            ('tool',{'turn':1,'id':2,'name':'edit','summary':'settings.scm','at':'17:15'}),
            ('diff',{'turn':1,'text':'--- a/settings.scm\n+++ b/settings.scm\n@@ -1 +1 @@\n-allow make test\n+allow make test (project)\n','truncated':False}),
            ('tool-result',{'turn':1,'id':2,'ok':True,'summary':'Edited settings'}),
            ('usage',{'prompt':24000,'limit':131072,'round':2,'max_rounds':40}),
            ('transcript',{'role':'assistant','text':'Source labels added.'}),
        ]:m.event({'type':kind,'value':value})
        m.control('ready')
        terminal.draw()
        return terminal

    def text(self,terminal):
        return '\n'.join(terminal.screen.line(y) for y in range(terminal.screen.size[0]))

    def test_sticky_role_header_uses_transcript_labels(self):
        terminal=self.active()
        m=terminal.model
        m.event({'type':'transcript','value':{'role':'assistant','text':'\n'.join('Paragraph '+str(i)+' '+'word '*30 for i in range(40))}})
        m.scroll=8;terminal.draw()
        session,_,_=tui.layout(128,40,m.config)
        top=terminal.screen.line(session.y)
        self.assertIn('SHIFT',top);self.assertNotIn('ASSISTANT',self.text(terminal))

    def test_failed_tool_summary_wraps_with_hanging_indent(self):
        terminal=self.active(placement='bottom',cols=80,rows=30)
        m=terminal.model
        m.event({'type':'tool','value':{'turn':1,'id':3,'name':'read','summary':'notes.txt','at':'17:16'}})
        m.event({'type':'tool-result','value':{'turn':1,'id':3,'ok':False,
                 'summary':'tool unavailable in this turn: read. The active image, execution mode, or approval denied it. Continue without it.'}})
        terminal.draw()
        rows=[terminal.screen.line(y) for y in range(30) if 'Continue without it' in terminal.screen.line(y) or 'tool unavailable' in terminal.screen.line(y)]
        self.assertEqual(len(rows),2,rows)
        self.assertTrue(all(row.startswith('      ') for row in rows),rows)
        self.assertNotIn(' it. Continue',rows[0])

    def test_multiline_command_result_becomes_one_notice_line(self):
        m=tui.Model();m.command_pending=3
        m.event({'type':'session-command-result','value':{'request_id':3,'ok':True,
                 'message':'Mode: auto\nAuto is conservative: read-only tools run.'}})
        self.assertEqual(m.notice,'Mode: auto · Auto is conservative: read-only tools run.')
        self.assertIsNone(m.command_pending)

    def test_footer_hints_fit_eighty_columns_in_qdos(self):
        terminal=self.active(placement='left',cols=80,rows=25)
        terminal.model.config['theme']='qdos';terminal.draw()
        footer=terminal.screen.line(24).rstrip()
        self.assertTrue(footer.endswith('^D quit'),footer)
        self.assertIn('^P commands',footer);self.assertIn('^C cancel',footer)
        for i in range(60):terminal.model.lines.append('line '+str(i))
        terminal.model.scroll=3;terminal.draw()
        footer=terminal.screen.line(24).rstrip()
        self.assertTrue(footer.startswith('scroll 3 | ^G latest'),footer)
        self.assertTrue(footer.endswith('^D quit'),footer)

    def test_header_drops_model_before_clipping_it_mid_word(self):
        terminal=self.active(placement='bottom',cols=80,rows=25)
        m=terminal.model
        m.config.update(theme='acid',wordmark=[' ▄▄ █   ▀  █▀  █ ','▀▄  █▀▄ █ ▀█▀ ▀█▀ ///','▄▄▀ █ █ █  █   ▀▄'])
        m.session['model']='offline-fixture-with-a-long-name'
        terminal.draw()
        header='\n'.join(terminal.screen.line(y) for y in range(5))
        self.assertIn('main',header)
        self.assertNotIn('offline-f',header)
        terminal.screen.size=(40,128);terminal.draw()
        header='\n'.join(terminal.screen.line(y) for y in range(5))
        self.assertIn('main | offline-fixture-with-a-long-name',header)

    def test_active_acid_has_ordered_work_and_real_diff_pane(self):
        terminal=self.active()
        text=self.text(terminal)
        session,panel,mode=tui.layout(128,40,terminal.model.config)
        self.assertEqual((panel.w,session.w,mode),(42,86,'docked'))
        for label in ('USER','SHIFT','READ','EDIT','OUTPUT DIFF','FILES','TELEMETRY','+allow make test (project)','-allow make test'):
            self.assertIn(label,text)
        self.assertLess(text.index('Trace the'),text.index('I will trace'))
        self.assertLess(text.index('I will trace'),text.index('  READ '))
        self.assertLess(text.index('EDIT'),text.index('Source labels added.'))
        self.assertNotIn('PASS',text)
        self.assertIn('MODEL MEM N/A',text)

    def test_bottom_placement_groups_toggle_and_survive_resize(self):
        terminal=self.active('bottom')
        m=terminal.model
        session,panel,_=tui.layout(128,40,m.config)
        self.assertEqual(session.w,128)
        self.assertEqual(panel.h,3)
        self.assertIn('OUTPUT DIFF',self.text(terminal))
        self.assertIn('+allow make test (project)',self.text(terminal))
        terminal.key('\x17');terminal.key('\x0f');terminal.draw()
        self.assertNotIn('  READ ',self.text(terminal))
        self.assertNotIn('+allow make test (project)',self.text(terminal))
        self.assertIn('▶ WORK',self.text(terminal))
        self.assertIn('▶ OUTPUT DIFF',self.text(terminal))
        terminal.screen.size=(24,80);terminal.draw()
        self.assertFalse(m.work);self.assertFalse(m.show_diff)
        terminal.screen.size=(40,128);terminal.key('\x17');terminal.key('\x0f');terminal.draw()
        self.assertIn('  READ ',self.text(terminal))
        self.assertIn('+allow make test (project)',self.text(terminal))

    def test_tabs_really_change_content_and_keep_draft(self):
        terminal=self.active()
        m=terminal.model
        m.draft='keep this';m.cursor=4
        terminal.key('\t');terminal.draw()
        self.assertEqual(m.panel_tab,'diff')
        self.assertIn('@@ -1 +1 @@',self.text(terminal))
        terminal.key('\t');terminal.draw()
        self.assertEqual(m.panel_tab,'session')
        self.assertIn('LATEST RECEIPT',self.text(terminal))
        terminal.screen.size=(24,80);terminal.draw()
        terminal.screen.size=(40,128);terminal.draw()
        self.assertEqual(m.panel_tab,'session')
        self.assertEqual((m.draft,m.cursor),('keep this',4))
        m.control('needs_approval')
        terminal.key('\t');terminal.key('\x17');terminal.key('\x0f')
        terminal.child.send.assert_not_called()
        self.assertTrue(m.approval)

    def test_telemetry_bars_use_only_reported_values(self):
        terminal=self.active()
        parts=terminal.meter(('CONTEXT',25,100,2),24)
        bar=''.join(text for text,_,_ in parts)
        self.assertIn('█',bar)
        segments=sum(bar.count(ch) for ch in '█░')
        self.assertLessEqual(abs(bar.count('█')/segments-.25),.5/segments)
        reported=''.join(text for text,_,_ in terminal.meter(('CONTEXT',24000,131072,2),37))
        self.assertIn('24k / 131k',reported)
        self.assertGreaterEqual(reported.count('█'),2)
        for value,expected in ((-1,'█'),(200,'░')):
            clamped=''.join(text for text,_,_ in terminal.meter(('ROUND',value,100,3),40))
            self.assertNotIn(expected,clamped)
        unknown=''.join(text for text,_,_ in terminal.meter(('RAM',None,None,4),40))
        self.assertIn('not measured',unknown)
        self.assertNotIn('█',unknown)
        terminal.model.config['ascii']=True
        self.assertTrue(all(text.isascii() for text,_,_ in terminal.meter(('ROUND',1,4,3),40)))

    def test_diff_frame_insets_highlights_and_fits_narrow_widths(self):
        terminal=self.active('bottom')
        group=terminal.active_group()
        group['truncated']=True
        for width in (8,16,34,76):
            rows=terminal.framed_diff(group,width)
            text=[''.join(part[0] for part in row) for row in rows]
            self.assertEqual(text[0],'┌'+'─'*(width-2)+'┐')
            self.assertEqual(text[-1],'└'+'─'*(width-2)+'┘')
            for line in text:
                self.assertEqual(sum(tui.cell_width(ch) for ch in line),width)
            highlighted=[row for row in rows if any(part[1] in (10,11) for part in row)]
            for row in highlighted:
                self.assertEqual(row[0],('│ ',3,False))
                self.assertEqual(row[-1],(' │',3,False))

    def test_diff_tab_scrolls_without_losing_transcript_or_draft(self):
        terminal=self.active()
        m=terminal.model
        m.groups[1]['diff']='\n'.join('+line '+str(i) for i in range(100))
        m.draft='preserved';m.cursor=4
        terminal.key('\t');terminal.draw()
        terminal.key(tui.curses.KEY_NPAGE);terminal.draw()
        self.assertEqual(m.panel_scroll['diff'],10)
        self.assertEqual(m.scroll,0)
        self.assertNotIn('+line 0 ',self.text(terminal))
        for _ in range(30):terminal.key(tui.curses.KEY_NPAGE);terminal.draw()
        self.assertIn('+line 99',self.text(terminal))
        for _ in range(30):terminal.key(tui.curses.KEY_PPAGE);terminal.draw()
        self.assertEqual(m.panel_scroll['diff'],0)
        self.assertEqual((m.draft,m.cursor),('preserved',4))

    def test_committed_diff_does_not_leak_into_next_turn(self):
        terminal=self.active()
        terminal.model.event({'type':'turn-start','value':{'turn':2}})
        self.assertEqual(terminal.active_group(),{})
        self.assertIsNone(terminal.model.usage['prompt'])
        self.assertEqual(terminal.model.usage['round'],0)
        self.assertEqual(terminal.model.receipt,{})
        terminal.model.event({'type':'diff','value':{'turn':2,'text':''}})
        self.assertNotIn(2,terminal.model.groups)

    def test_show_work_hides_new_transcript_groups_but_keeps_inspector_facts(self):
        terminal=self.active()
        m=terminal.model
        m.event({'type':'session','value':{**m.session,'show_work':False}})
        self.assertIs(m.session['show_work'],False)
        m.event({'type':'turn-start','value':{'turn':2}})
        m.event({'type':'tool','value':{'turn':2,'id':3,'name':'read','summary':'hidden.txt'}})
        terminal.draw()
        session,_,_=tui.layout(128,40,m.config)
        body='\n'.join(terminal.screen.line(y)[:session.w] for y in range(session.y,session.y+session.h))
        self.assertNotIn('hidden.txt',body)
        self.assertIn('settings.scm',body)
        self.assertIn('hidden.txt',self.text(terminal))
        self.assertTrue(m.groups[1]['visible'])
        self.assertFalse(m.groups[2]['visible'])
        m.event({'type':'session','value':{**m.session,'show_work':True}})
        self.assertIs(m.session['show_work'],True)
        self.assertFalse(m.groups[2]['visible'])
        self.assertEqual(m.groups[2]['tools'][0]['summary'],'hidden.txt')

    def test_programmable_palette_is_exact_and_restored_without_overriding_indexed_colors(self):
        terminal=terminal_view()
        terminal.palette=None;terminal.saved_colors={}
        terminal.screen.bkgd=Mock()
        terminal.model.config['foreground']=255
        with patch.object(tui.curses,'COLORS',256,create=True), \
             patch.object(tui.curses,'has_colors',return_value=True), \
             patch.object(tui.curses,'can_change_color',return_value=True), \
             patch.object(tui.curses,'color_content',return_value=(100,200,300)), \
             patch.object(tui.curses,'init_color') as init_color, \
             patch.object(tui.curses,'init_pair'), patch.object(tui.curses,'color_pair',return_value=1):
            tui.Terminal.colors(terminal)
            self.assertTrue(terminal.saved_colors)
            self.assertNotIn(255,terminal.saved_colors)
            self.assertIn((90,24,149),[call.args[1:] for call in init_color.call_args_list])
            saved=list(terminal.saved_colors)
            terminal.restore_colors()
            for index in saved:self.assertIn(unittest.mock.call(index,100,200,300),init_color.call_args_list)
            self.assertEqual(terminal.saved_colors,{})

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


class WorkingMark(unittest.TestCase):
    def test_scaled_slashes_match_wordmark_height_and_animate_whole_strokes(self):
        terminal=terminal_view(40,120)
        terminal.model.config['wordmark']=['logo','name ///','tail']
        terminal.model.control('working');terminal.draw()
        self.assertEqual(len(terminal.marks),1)
        self.assertEqual(terminal.marks[0][2],3)
        before=[terminal.screen.line(i) for i in range(40)]
        terminal.put=Mock(wraps=terminal.screen.put)
        for phase in (0,1,2):
            terminal.put.reset_mock()
            terminal.paint_marks(phase)
            calls=terminal.put.call_args_list
            self.assertEqual(len(calls),9)
            for index,call in enumerate(calls):
                self.assertEqual(call.args[-2],index//3==phase)
                self.assertEqual(call.args[2],'█')
            self.assertEqual([terminal.screen.line(i) for i in range(40)],before)
        terminal.model.config.update(branding='replace',identity='thrashr888')
        terminal.draw()
        self.assertEqual(terminal.marks[0][2],1)
        self.assertIn('thrashr888 ///',terminal.screen.line(1))

    def test_phase_only_advances_while_working(self):
        terminal=terminal_view()
        m=terminal.model
        self.assertIsNone(terminal.mark_phase(0))
        m.control('working')
        self.assertEqual([terminal.mark_phase(t) for t in (0,.24,.25,.49,.5,.74,.75)],[0,0,1,1,2,2,0])
        m.control('needs_approval')
        self.assertIsNone(terminal.mark_phase(.5))
        m.control('working')
        m.config['motion']=False
        self.assertIsNone(terminal.mark_phase(.5))
        m.config['motion']=True
        terminal.child=Mock()
        terminal.key('\x03')
        self.assertEqual(m.status(),'CANCELLING')
        self.assertIsNone(terminal.mark_phase(.5))
        m.control('working')
        self.assertIsNone(terminal.mark_phase(.5))
        m.control('ready')
        self.assertEqual(m.status(),'READY')
        self.assertIsNone(terminal.mark_phase(.5))

    def test_brand_animation_does_not_change_text_or_geometry(self):
        terminal=terminal_view(40,120)
        terminal.model.control('working')
        for config in ({}, {'ascii':True}, {'branding':'replace','identity':'thrashr888'},
                       {'ascii':True,'wordmark':['CUSTOM ///']},
                       {'wordmark':['Custom ///','second line']}):
            terminal.model.config=tui.Model().config
            terminal.model.config.update(config)
            terminal.draw()
            before=[terminal.screen.line(i) for i in range(40)]
            self.assertTrue(terminal.marks)
            for phase in (0,1,2,None):
                terminal.paint_marks(phase)
                self.assertEqual([terminal.screen.line(i) for i in range(40)],before)
        terminal.model.config.update(branding='none',identity='my name')
        terminal.draw()
        self.assertEqual(terminal.marks,[])
        terminal.model.config.update(branding='subtitle',wordmark=['CUSTOM ART'])
        terminal.draw()
        self.assertEqual(terminal.marks,[])

    def test_partial_or_hidden_marks_are_not_repainted(self):
        terminal=terminal_view(24,40)
        terminal.model.config.update(branding='replace',identity='x'*35)
        terminal.draw()
        self.assertEqual(terminal.marks,[])
        terminal.model.config['identity']='shift'
        terminal.menu=True
        terminal.draw()
        self.assertEqual(terminal.marks,[])

    def test_motion_command_is_a_ui_patch(self):
        child=Mock();terminal=terminal_view(child=child)
        for key in '/motion off\n':terminal.key(key)
        child.ui.assert_called_once_with({'action':'patch','patch':{'motion':False}})
        child.send.assert_not_called()
        self.assertTrue(terminal.local('/motion on'))
        with self.assertRaises(ValueError):terminal.local('/motion maybe')

    def test_timer_repaints_only_mark_cells_and_preserves_cursor(self):
        terminal=terminal_view(child=Mock())
        terminal.model.control('working')
        terminal.model.draft='keep draft';terminal.model.cursor=3
        terminal.screen.get_wch=Mock(side_effect=tui.curses.error)
        terminal.child.process.poll.side_effect=[None,None,0,0]
        terminal.child.poll.return_value=False
        terminal.mark_phase=Mock(side_effect=[0,0,1,1])
        terminal.draw=Mock(wraps=terminal.draw)
        terminal.paint_marks=Mock(wraps=terminal.paint_marks)
        self.assertEqual(terminal.run(),0)
        self.assertEqual(terminal.draw.call_count,1)
        self.assertEqual(terminal.paint_marks.call_count,2)
        self.assertEqual(terminal.screen.cursor,(21,8))
        self.assertEqual(terminal.model.draft,'keep draft')


class Interaction(unittest.TestCase):
    def setUp(self):
        self.t=terminal_view(40,120,Mock())
        self.m=self.t.model
        self.m.control('ready')
        self.t.draw()

    def click(self,kind,value=None,event='press'):
        r=next(r for r,a in self.t.hits if a==(kind,value))
        self.t.pointer(r.x,r.y,event)
        return r

    def test_click_modes_deduplicates_release_and_never_submits_draft(self):
        self.m.draft='unsent';self.m.cursor=2
        r=self.click('mode')
        self.t.pointer(r.x,r.y,'release');self.t.pointer(r.x,r.y,'click')
        self.t.child.ui.assert_called_once_with({'action':'session-command','command':'/mode plan','request_id':1})
        self.t.child.send.assert_not_called()
        self.assertEqual((self.m.draft,self.m.cursor),('unsent',2))
        self.m.event({'type':'session-command-result','value':{'request_id':1,'ok':False,'error':'busy'}})
        self.assertEqual(self.m.notice,'busy')

    def test_shift_tab_cycles_exact_order_and_blocks_busy_approval(self):
        for index,mode in enumerate(tui.MODES):
            self.m.session['mode']=mode
            self.m.command_pending=None
            self.t.key(tui.curses.KEY_BTAB)
            self.assertEqual(self.t.child.ui.call_args.args[0]['command'],'/mode '+tui.MODES[(index+1)%4])
        self.t.child.ui.reset_mock()
        for state in ('working','needs_approval'):
            self.m.command_pending=None;self.m.control(state)
            self.t.key(tui.curses.KEY_BTAB)
            self.t.child.ui.assert_not_called()
        self.assertTrue(self.m.approval)
        self.t.child.send.assert_not_called()

    def test_wheel_routes_regions_and_keeps_history_and_draft(self):
        for i in range(100):self.m.output('line '+str(i)+'\n')
        self.m.history=['old'];self.m.history_index=1;self.m.draft='draft';self.m.cursor=3
        self.t.draw()
        before=self.t.screen.line(7)
        self.t.pointer(5,10,'up');self.t.draw()
        self.assertEqual(self.m.scroll,3)
        self.assertNotEqual(self.t.screen.line(7),before)
        self.assertEqual((self.m.draft,self.m.cursor,self.m.history_index),('draft',3,1))
        self.t.pointer(5,10,'down');self.t.draw()
        self.assertEqual(self.m.scroll,0)
        self.m.panel_tab='diff'
        group=self.m.group(1);self.m.current_turn=1;group['diff']='\n'.join('+item'+str(i) for i in range(80))
        self.t.draw();r=self.t.regions['panel']
        self.t.pointer(r.x+2,r.y+2,'down');self.t.draw()
        self.assertEqual(self.m.panel_scroll['diff'],3)
        self.assertEqual(self.m.scroll,0)
        self.t.key(tui.curses.KEY_UP)
        self.assertEqual(self.m.draft,'old')
        self.t.child.ui.assert_not_called()

    def test_mouse_hit_regions_refresh_after_resize_and_tabs_work(self):
        old=next(r for r,a in self.t.hits if a[0]=='mode')
        self.t.screen.size=(8,20)
        self.t.pointer(old.x,old.y,'press')
        self.t.child.ui.assert_not_called()
        self.t.draw()
        self.assertFalse(any(action[0]=='mode' for _,action in self.t.hits))
        self.t.screen.size=(40,120);self.t.draw()
        self.click('tab','diff')
        self.assertEqual(self.m.panel_tab,'diff')
        self.click('sidebar')
        self.assertEqual(self.t.child.ui.call_args.args[0]['patch'],{'sidebar':'off'})

    def test_completion_filter_arguments_escape_palette_and_mouse(self):
        for key in '/mo':self.t.key(key)
        self.t.draw()
        self.assertEqual([c[0] for c in self.t.completion_choices],['/mode','/motion','/model'])
        self.t.key('\t');self.assertEqual(self.m.draft,'/mode')
        self.t.child.ui.assert_not_called()
        for key in ' a':self.t.key(key)
        self.t.draw()
        self.assertEqual([c[0] for c in self.t.completion_choices],['/mode accept','/mode auto'])
        self.click('complete',1)
        self.assertEqual(self.m.draft,'/mode auto')
        self.t.child.ui.assert_not_called()
        self.t.key('\n')
        self.assertEqual(self.t.child.ui.call_args.args[0]['command'],'/mode auto')
        self.m.draft='unfinished';self.m.cursor=3;self.t.open_palette()
        self.assertEqual(self.m.draft,'')
        for key in 'theme':self.t.key(key)
        self.t.key('\x1b')
        self.assertEqual((self.m.draft,self.m.cursor),('unfinished',3))
        self.m.draft='/not-a-command';self.t.draw()
        self.assertEqual(self.t.completion_choices,[])
        self.t.key('\n');self.t.child.send.assert_not_called()

    def test_theme_registry_cycles_bare_f2_and_pending_approval_without_answers(self):
        self.m.themes=['acid','paddock','custom'];self.m.config['theme']='custom'
        for state in ('ready','working','needs_approval'):
            self.m.control(state)
            self.assertTrue(self.t.local('/theme'))
            self.assertEqual(self.t.child.ui.call_args.args[0],{'action':'patch','patch':{'theme':'acid'}})
            self.t.key(tui.curses.KEY_F2)
            self.assertEqual(self.t.child.ui.call_args.args[0],{'action':'patch','patch':{'theme':'acid'}})
        self.assertTrue(self.m.approval)
        self.t.child.send.assert_not_called()
        self.assertEqual(tui.suggestions('/theme c',self.m.themes),[('/theme custom',tui.COMMANDS['/theme'])])
        self.assertTrue(self.t.local('/theme custom'))
        self.assertEqual(self.t.child.ui.call_args.args[0]['patch'],{'theme':'custom'})

    def test_prose_wrap_and_markdown_preserve_preformatted_and_unicode(self):
        self.assertEqual(tui.wrap('a live Guile image',15,words=True),['a live Guile','image'])
        self.assertEqual(tui.wrap('界界 hello world',8,words=True),['界界','hello','world'])
        self.m.event({'type':'transcript','value':{'role':'assistant','text':'**Heading** and `code`\n```python\n    x = "**literal**"\n```\nnext'}})
        lines,_=self.t.body_rows(30,False,False)
        text='\n'.join(''.join(p[0] for p in line) for line in lines)
        self.assertIn('Heading and code',text)
        self.assertIn('    x = "**literal**"',text)
        self.assertNotIn('```',text)
        long_text='a longer word '*2000
        with patch.object(tui,'cell_width',wraps=tui.cell_width) as width:
            tui.wrap(long_text,40,words=True)
            self.assertLess(width.call_count,len(long_text)*3)

    def test_sgr_mouse_and_shift_tab_decoder_and_cleanup(self):
        for i in range(100):self.m.output('row '+str(i)+'\n')
        self.t.draw()
        self.t.screen.timeout=Mock()
        self.t.screen.get_wch=Mock(return_value='\x1b')
        self.t.screen.getch=Mock(side_effect=list(map(ord,'[<64;6;11M')))
        self.t.read_key();self.assertEqual(self.m.scroll,3)
        self.t.screen.getch=Mock(side_effect=list(map(ord,'[Z')))
        self.assertEqual(self.t.read_key(),tui.curses.KEY_BTAB)
        self.t.mouse_enabled=True
        with patch.object(tui.curses,'mousemask') as mask, patch.object(tui.sys,'stdout') as output:
            self.t.stop_mouse()
            mask.assert_called_once_with(0)
            self.assertIn('\x1b[?1000l',output.write.call_args.args[0])
            self.assertIn('\x1b[?1000;1006;1007r',output.write.call_args.args[0])


class TelemetrySnapshots(unittest.TestCase):
    def test_complete_initial_snapshot_survives_ui_modes_and_new_turn(self):
        t=terminal_view(40,120,Mock());m=t.model
        usage={'prompt':1234,'prompt_tokens':1234,'prompt_source':'estimated','limit':65536,
               'context_source':'ollama:/api/ps','round':0,'round_source':'not-started','max_rounds':6,
               'memory_bytes':11473612963,'memory_label':'GPU/model allocated','provider':'ollama','model':'fixture'}
        m.event({'type':'usage','value':usage.copy()})
        m.control('ready');m.panel_tab='session';t.draw()
        text='\n'.join(t.screen.line(y) for y in range(40))
        self.assertIn('Prompt: 1,234 (estimated)',text)
        self.assertIn('Max rounds: 6',text)
        self.assertIn('Round: 0 (not started)',text)
        self.assertIn('11,473,612,963 bytes',text)
        m.event({'type':'ui','value':{'config':m.config,'revision':12}})
        m.event({'type':'session','value':{'mode':'auto'}})
        self.assertEqual(m.usage,usage)
        m.event({'type':'turn-start','value':{'turn':2}})
        self.assertEqual(m.usage['max_rounds'],6)
        self.assertEqual(m.usage['limit'],65536)
        self.assertEqual(m.usage['memory_bytes'],11473612963)
        self.assertIsNone(m.usage['prompt'])

    def test_memory_units_null_reasons_and_zero_are_honest(self):
        t=terminal_view();m=t.model;m.control('ready')
        m.usage={'prompt':8600,'prompt_source':'estimated','limit':None,'round':3,'max_rounds':6,
                 'memory_bytes':None,'memory_reason':'model-not-loaded'}
        context=''.join(p[0] for p in t.meter(t.telemetry()[0],50))
        self.assertIn('~8.6k / ?',context)
        self.assertNotIn('░',context)
        self.assertIn('MEM: model not loaded',t.telemetry_notes())
        self.assertIn('CTX: /context limit N',t.telemetry_notes())
        m.usage['memory_bytes']=0
        memory=''.join(p[0] for p in t.meter(t.telemetry()[2],50))
        self.assertEqual(memory,'MODEL MEM 0.0 GiB')
        m.usage['memory_bytes']=1073741824
        self.assertIn('1.0 GiB',''.join(p[0] for p in t.meter(t.telemetry()[2],50)))
        m.event({'type':'usage','value':{'prompt':0,'limit':4096,'round':0,'max_rounds':6,
                                      'memory_bytes':None,'memory_reason':'provider-metadata-unsupported'}})
        self.assertEqual(m.usage['prompt'],0)
        self.assertIsNone(m.usage['memory_bytes'])
        self.assertIn('MEM: provider does not report it',t.telemetry_notes())


class PresentationReload(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='shift-reload-')
        self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'tui.py'
        self.source=(ROOT/'scripts/tui.py').read_text()
        self.path.write_text(self.source)
        self.t=terminal_view(40,120,Mock())
        self.t.model.control('ready')
        self.reload=tui.Reloader(self.path,watch=True)
        self.t.reloader=self.reload

    def test_atomic_swap_preserves_session_input_scroll_and_pending_events(self):
        m=self.t.model
        m.draft='draft';m.cursor=2;m.history=['earlier'];m.scroll=3
        m.control('needs_approval')
        m.approval_prompt='allow?';m.approval_preview='read notes.txt'
        m.event({'type':'transcript','value':{'role':'assistant','text':'streaming','stream':True}})
        self.t.anchor=(3,0);m.panel_tab='session'
        snapshot=copy.deepcopy(m.__dict__)
        old_class=self.t.__class__
        self.path.write_text(self.source.replace("self.box(r,'PENDING TOOL: PgUp/PgDn')","self.box(r,'LIVE PENDING TOOL')"))
        self.reload.request()
        self.assertTrue(self.reload.check(self.t,now=1))
        self.assertIsNot(self.t.__class__,old_class)
        self.assertIs(self.t.model,m)
        for name,value in snapshot.items():
            if name not in ('notice','source_identity'):self.assertEqual(m.__dict__[name],value,name)
        self.assertEqual(self.t.anchor,(3,0))
        self.t.child.send.assert_not_called();self.t.child.ui.assert_not_called()
        self.t.draw()
        self.assertIn('LIVE PENDING TOOL','\n'.join(self.t.screen.line(i) for i in range(40)))
        m.event({'type':'transcript','value':{'role':'assistant','text':' continued','stream':True,'end':True}})
        self.assertIn('streaming continued','\n'.join(m.lines))

    def test_failed_candidates_keep_last_working_class_and_state(self):
        old_class=self.t.__class__
        for bad in (self.source+'\n!',self.source.replace('import locale','import nonexistent_reload_dependency'),
                    self.source.replace('self.screen.erase()','self.nonexistent_render_field()'),
                    self.source.replace('self.ready=state==','self.ready=state!=')):
            self.path.write_text(bad)
            self.reload.request();self.reload.check(self.t,now=1)
            self.assertIs(self.t.__class__,old_class)
            self.assertIn('rejected',self.t.model.notice)
            notice=self.t.model.notice
            self.assertFalse(self.reload.check(self.t,now=2))
            self.reload.request();self.reload.check(self.t,now=3)
            self.assertEqual(self.t.model.notice,notice)
        self.t.child.send.assert_not_called()

    def test_watch_debounce_and_no_watch_contract(self):
        self.path.write_text(self.source.replace('Type a task below to start.','Live source update.'))
        self.assertFalse(self.reload.check(self.t,now=1))
        self.assertFalse(self.reload.check(self.t,now=1.1))
        self.assertTrue(self.reload.check(self.t,now=1.6))
        self.assertIn('reloaded',self.t.model.notice)
        self.reload.watch=False
        old_class=self.t.__class__
        self.path.write_text(self.source.replace('Type a task below to start.','Explicit update.'))
        self.assertFalse(self.reload.check(self.t,now=3))
        self.assertIs(self.t.__class__,old_class)
        self.reload.request();self.assertTrue(self.reload.check(self.t,now=4))
        self.assertIsNot(self.t.__class__,old_class)
        self.assertFalse(tui.watch_enabled(['--no-watch','--session','--watch']))
        self.assertTrue(tui.watch_enabled(['--no-watch','--watch']))


class SourceIdentity(unittest.TestCase):
    def test_chrome_uses_acs_or_wide_cells_and_keeps_diff_hyphens_literal(self):
        for acs,unicode,ascii_,expected in ((True,False,False,1234),(False,True,False,'─'),
                                            (False,False,False,'-'),(True,True,True,'-')):
            t=terminal_view();t.screen.addch=Mock();t.screen.addstr=Mock()
            t.acs=acs;t.unicode=unicode;t.model.config['ascii']=ascii_
            with patch.object(tui.curses,'has_colors',return_value=False), patch.object(tui.curses,'ACS_HLINE',1234,create=True):
                tui.Terminal.put(t,0,0,'──',10)
                self.assertEqual(t.screen.addch.call_args_list[0].args[2],expected)
                self.assertEqual(t.screen.addch.call_count,2)
                tui.Terminal.put(t,1,0,'--- a/file',10)
                self.assertEqual(t.screen.addstr.call_args.args[2],'--- a/file')

    def test_install_root_not_working_project_and_gitignore_dirty_semantics(self):
        with tempfile.TemporaryDirectory(prefix='shift-identity-') as tmp:
            root=Path(tmp)/'install';root.mkdir()
            other=Path(tmp)/'project';other.mkdir()
            def git(*args):
                return subprocess.run(['git','-C',str(root),'-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null',*args],
                                      check=True,capture_output=True,text=True,timeout=5).stdout.strip()
            git('init','-q')
            (root/'.gitignore').write_text('generated/\n')
            (root/'source.py').write_text('original')
            git('add','.')
            git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')
            with patch('os.getcwd',return_value=str(other)):
                result=tui.identity(root)
            self.assertEqual(result['commit'],git('rev-parse','HEAD'))
            self.assertFalse(result['dirty'])
            (root/'generated').mkdir();(root/'generated/data').write_text('ignored')
            self.assertFalse(tui.identity(root)['dirty'])
            (root/'source.py').write_text('changed')
            self.assertTrue(tui.identity(root)['dirty'])
            self.assertEqual(tui.identity(other)['label'],'source unavailable')
            with patch('tui_identity.subprocess.run',side_effect=FileNotFoundError):
                self.assertEqual(tui.identity(root)['label'],'source unavailable')

    def test_qdos_geometry_controls_and_revision_truncation(self):
        for width,height in ((80,25),(128,40),(60,20),(20,8)):
            t=terminal_view(height,width,Mock());m=t.model
            m.config.update(theme='qdos',placement='left',density='compact',wordmark=['shift ///'])
            m.source_identity['loaded']['label']='abcdef12 +dirty'
            m.control('ready');t.draw()
            if width>=80:
                self.assertEqual(tui.layout(width,height,m.config)[1].w,30)
                self.assertIn('Commands',t.screen.line(0))
                self.assertIn('═══',t.screen.line(2))
                self.assertTrue(any(a==('tab','session') for _,a in t.hits))
            for r,_ in t.hits:self.assertLessEqual(r.x+r.w,width)


class PTY(unittest.TestCase):
    def test_live_source_reload_uses_same_backend_with_watch_and_explicit_no_watch(self):
        for watch in (False,True):
            with self.subTest(watch=watch), tempfile.TemporaryDirectory(prefix='shift-live-source-') as tmp:
                root=Path(tmp);candidate=root/'tui.py';pidfile=root/'pid'
                source=(ROOT/'scripts/tui.py').read_text();candidate.write_text(source)
                code=("import sys\nsys.path.insert(0,"+repr(str(ROOT/'scripts'))+")\nimport tui\n"
                      "tui.__file__="+repr(str(candidate))+"\n"
                      "original=tui.Child.__init__\n"
                      "def init(self,*a,**kw):\n original(self,*a,**kw)\n open("+repr(str(pidfile))+",'a').write(str(self.process.pid)+'\\n')\n"
                      "tui.Child.__init__=init\nsys.exit(tui.main())\n")
                master,slave=pty.openpty()
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
                proc=subprocess.Popen([sys.executable,'-c',code,'--agent',str(ROOT/'test/session-agent.scm'),
                    '--watch' if watch else '--no-watch','--session','reload','--state-dir',tmp+'/state'],
                    stdin=slave,stdout=slave,stderr=slave,start_new_session=True,
                    env={**os.environ,'TERM':'xterm-256color','XDG_CONFIG_HOME':tmp+'/config'})
                data=b''
                def wait_for(predicate):
                    nonlocal data
                    end=time.monotonic()+10
                    while time.monotonic()<end:
                        if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                        if predicate():return
                        if proc.poll() is not None:break
                    self.fail(data[-4000:].decode(errors='replace'))
                try:
                    wait_for(lambda:b'READY' in data)
                    pid=pidfile.read_text()
                    os.write(master,b'retained draft')
                    candidate.write_text(source.replace('Type a task below to start.','Live source replacement.'))
                    if not watch:
                        os.write(master,b'\x10/ui code-reload\n\n')
                    wait_for(lambda:b'Live source replacement.' in data)
                    self.assertEqual(pidfile.read_text(),pid)
                    os.write(master,b'\n')
                    session=root/'state/sessions/reload/session.json'
                    wait_for(lambda:session.exists() and any(m.get('content')=='retained draft' for m in json.loads(session.read_text())['history']))
                    os.write(master,b'\x04');wait_for(lambda:proc.poll() is not None)
                    self.assertEqual(proc.returncode,0)
                finally:
                    if proc.poll() is None:proc.kill()
                    proc.wait(timeout=5);os.close(master);os.close(slave)

    def test_make_default_recipe_launches_curses(self):
        with tempfile.TemporaryDirectory(prefix='shift-make-tui-') as tmp:
            master,slave=pty.openpty()
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
            args=['--agent',str(ROOT/'test/session-agent.scm'),'--no-watch',
                  '--state-dir',tmp+'/state','--session','make-test']
            process=subprocess.Popen(['make','SHIFT_ARGS='+shlex.join(args)],cwd=ROOT,
                stdin=slave,stdout=slave,stderr=slave,start_new_session=True,
                env={**os.environ,'TERM':'xterm-256color','XDG_CONFIG_HOME':tmp+'/config'})
            data=b''
            try:
                deadline=time.monotonic()+20
                while b'READY' not in data:
                    self.assertLess(time.monotonic(),deadline,data.decode(errors='replace'))
                    if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                    self.assertIsNone(process.poll(),data.decode(errors='replace'))
                self.assertIn(b'\x1b[?1049h',data)
                os.write(master,b'\x04')
                while process.poll() is None:
                    self.assertLess(time.monotonic(),deadline,data.decode(errors='replace'))
                    if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                self.assertEqual(process.returncode,0,data.decode(errors='replace'))
            finally:
                if process.poll() is None:os.killpg(process.pid,signal.SIGTERM)
                os.close(master);os.close(slave)
                process.wait(timeout=5)

    def test_option_values_and_literal_prompt_do_not_select_a_mode(self):
        for name in ('--tui','--print','-p','--mcp','session-fork'):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix='shift-tui-argv-') as tmp:
                master,slave=pty.openpty()
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
                process=subprocess.Popen([str(ROOT/'bin/shift'),'--tui',
                    '--agent',str(ROOT/'test/session-agent.scm'),'--no-watch',
                    '--state-dir',tmp+'/state','--session',name,'session-fork'],
                    stdin=slave,stdout=slave,stderr=slave,start_new_session=True,
                    env={**os.environ,'TERM':'xterm-256color','XDG_CONFIG_HOME':tmp+'/config'})
                data=b''
                try:
                    deadline=time.monotonic()+15
                    while b'READY' not in data:
                        self.assertLess(time.monotonic(),deadline,data.decode(errors='replace'))
                        if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                        if process.poll() is not None:break
                    if name.startswith('-'):
                        self.assertNotEqual(process.returncode,0,data.decode(errors='replace'))
                        self.assertIn(b'session names must match',data)
                        self.assertIn(name.encode(),data)
                        self.assertNotIn(b'cannot be combined',data)
                        continue
                    self.assertIn(b'READY',data)
                    checkpoint=json.loads((Path(tmp)/'state/sessions'/name/'session.json').read_text())
                    self.assertTrue(any(m.get('role')=='user' and m.get('content')=='session-fork' for m in checkpoint['history']))
                    os.write(master,b'\x04')
                    deadline=time.monotonic()+10
                    while process.poll() is None:
                        self.assertLess(time.monotonic(),deadline,data.decode(errors='replace'))
                        if select.select([master],[],[],.05)[0]:data+=os.read(master,65536)
                    self.assertEqual(process.returncode,0)
                finally:
                    if process.poll() is None:process.kill()
                    os.close(master);os.close(slave)
                    process.wait(timeout=5)

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
                os.write(master,b'\x1b[Z')
                wait_for(lambda:b'PLAN' in data)
                # SGR click the current mode badge, then release: exactly one
                # transition. These bytes also cover old X10-only terminfo.
                hit_view=terminal_view(40,120)
                hit_view.model.session={'name':'pty','model':'demo','mode':'plan'}
                hit_view.draw()
                region=next(r for r,a in reversed(hit_view.hits) if a[0]=='mode')
                os.write(master,f'\x1b[<0;{region.x+1};{region.y+1}M\x1b[<0;{region.x+1};{region.y+1}m'.encode())
                wait_for(lambda:b'ACCEPT' in data)
                os.write(master,b'\x1b[<0;14;40M\x1b[<0;14;40m')
                wait_for(lambda:b'COMMANDS:' in data)
                os.write(master,b'\x1b')
                time.sleep(.06)
                os.write(master,b'/name racer\n')
                prefs=Path(tmp)/'state/sessions/pty/ui.json'
                wait_for(lambda:prefs.exists() and json.loads(prefs.read_text()).get('identity')=='racer')
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
                process.send_signal(signal.SIGWINCH)
                os.write(master,b'hello\x1b[<64;6;10M\x1b[<65;6;10M\n')
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
                self.assertIn(b'\x1b[?1000;1006;1007r',data)
                self.assertNotIn('\ufffd',data.decode('utf-8'))
            finally:
                if process.poll() is None:process.kill();process.wait()
                os.close(master);os.close(slave)


class Arguments(unittest.TestCase):
    def test_values_are_preserved_before_filtering_flags(self):
        for option in tui.VALUE_OPTIONS:
            for value in ('--tui','--print','-p','--mcp','--list-sessions','session-fork'):
                self.assertEqual(tui.frontend_arguments(['--tui',option,value]),[option,value])
        self.assertEqual(tui.frontend_arguments(['--tui','explain --print and --tui']),['explain --print and --tui'])
        self.assertEqual(tui.frontend_arguments(['--tui','session-fork']),['session-fork'])

    def test_real_incompatible_options_are_rejected(self):
        for option in ('--print','-p','--mcp','--list-sessions','--fork-session'):
            with self.assertRaises(ValueError):tui.frontend_arguments(['--tui',option,'task'])

    def test_unsupported_double_dash_does_not_start_a_frontend(self):
        result=subprocess.run([str(ROOT/'bin/shift'),'--','--tui'],
                              input='',text=True,capture_output=True,timeout=15)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('requires a terminal',result.stderr)
        self.assertNotIn('\x1b[?1049h',result.stdout)

    def test_piped_flag_values_reach_backend_validation(self):
        with tempfile.TemporaryDirectory(prefix='shift-argv-pipe-') as tmp:
            for value in ('--tui','--print','--mcp'):
                result=subprocess.run([str(ROOT/'bin/shift'),'--agent',str(ROOT/'test/session-agent.scm'),
                    '--state-dir',tmp+'/state','--session',value],input='/quit\n',
                    text=True,capture_output=True,timeout=15,
                    env={**os.environ,'XDG_CONFIG_HOME':tmp+'/config'})
                self.assertNotEqual(result.returncode,0)
                self.assertIn('session names must match',result.stderr)
                self.assertNotIn('requires a terminal',result.stderr)

if __name__=='__main__':unittest.main()
