#!/usr/bin/env python3
"""Character-cell layout proof, not Shift's terminal frontend.
python3 terminal-layout.py --columns 80 --rows 24 --placement bottom
python3 terminal-layout.py --check
"""
import argparse
from dataclasses import dataclass

@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int

def layout(columns, rows, placement, policy):
    if columns < 40 or rows < 16:
        raise ValueError('Compact fallback required below 40 columns or 16 rows')
    body = Rect(0, 3, columns, rows - 6)
    session = Rect(body.x, body.y, body.w, body.h)
    fits = columns >= 120 and body.h >= 16 if placement in ('left', 'right') else body.h >= 26
    visible = policy == 'on' or policy == 'auto' and fits and placement != 'modal'
    panel = None
    mode = 'hidden'
    if visible:
        if placement == 'modal' or not fits:
            mode = 'overlay'
            panel = Rect((columns-min(42, columns-4))//2, body.y+1,
                         min(42, columns-4), min(18, body.h-2))
            if placement == 'left': panel.x = 0
            if placement == 'right': panel.x = columns-panel.w
        elif placement in ('left', 'right'):
            mode = 'docked'
            width = min(36, columns//3)
            panel = Rect(0 if placement == 'left' else columns-width, body.y, width, body.h)
            session.x = width if placement == 'left' else 0
            session.w -= width
        else:
            mode = 'docked'
            height = 10
            panel = Rect(0, body.y if placement == 'top' else body.y+body.h-height, columns, height)
            session.y += height if placement == 'top' else 0
            session.h -= height
    return {'header':Rect(0,0,columns,3),'session':session,'inspector':panel,
            'composer':Rect(0,rows-3,columns,3)}, mode

def check():
    count=0
    for columns in (40,80,110,120,160):
        for rows in (16,24,40,48):
            for placement in ('left','right','top','bottom','modal'):
                for policy in ('auto','on','off'):
                    parts,mode=layout(columns,rows,placement,policy)
                    for r in filter(None,parts.values()):
                        assert r.w>0 and r.h>0 and r.x>=0 and r.y>=0
                        assert r.x+r.w<=columns and r.y+r.h<=rows
                    a,b=parts['session'],parts['inspector']
                    if b:
                        assert b.y>=3 and b.y+b.h<=rows-3 # never cover composer
                        if mode=='docked':
                            assert a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y
                            assert a.w>=40 and a.h>=16
                    if policy=='off': assert b is None
                    count+=1
    print(f'{count} layouts pass bounds, composer clearance, and docked non-overlap checks')

def preview(columns,rows,placement,policy):
    parts,mode=layout(columns,rows,placement,policy)
    grid=[[' ']*columns for _ in range(rows)]
    def text(x,y,value,width):
        for i,ch in enumerate(value[:max(0,width)]): grid[y][x+i]=ch
    def box(r,title):
        for y in range(r.y,r.y+r.h):
            for x in range(r.x,r.x+r.w): grid[y][x]=' '
        for x in range(r.x,r.x+r.w):grid[r.y][x]=grid[r.y+r.h-1][x]='-'
        for y in range(r.y,r.y+r.h):grid[y][r.x]=grid[y][r.x+r.w-1]='|'
        text(r.x+2,r.y,title,r.w-4)
    for name,r in parts.items():
        if r is None:continue
        box(r,{'header':'thrashr888 ///  main  ACCEPT','session':'SESSION','inspector':'CONTEXT / '+mode,'composer':'> What next?'}[name])
        if name=='session':
            for i,line in enumerate(['YOU: Make this mine.','SHIFT: Identity and layout updated.','READ settings.scm','EDIT main.scm +7 -2','PASS 24 tests'][:r.h-2]):text(r.x+2,r.y+1+i,line,r.w-4)
        if name=='inspector':text(r.x+2,r.y+1,'24k / 131k | round 06',r.w-4)
    return '\n'.join(''.join(line) for line in grid)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--columns',type=int,default=120)
    parser.add_argument('--rows',type=int,default=40)
    parser.add_argument('--placement',choices=['left','right','top','bottom','modal'],default='right')
    parser.add_argument('--policy',choices=['auto','on','off'],default='on')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    if args.check:check()
    else:print(preview(args.columns,args.rows,args.placement,args.policy))
