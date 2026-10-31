import os
import re,sys,statistics as st
D=os.environ.get('RHINE_AB_DIR',
  os.path.join(os.path.dirname(os.path.abspath(__file__)),'out')) + '/'
def load(tag):
    tl={}
    for l in open(D+tag+'.timeline'):
        ts,n=l.split(); tl[n]=int(ts)
    segs=[]
    bounds=[('idleA','idleA_start','idleA_end'),('seg1','seg1_start','seg1_end'),
            ('seg2','seg2_start','seg2_end'),('seg3','seg3_start','seg3_end')]
    rows=[]
    for line in open(D+tag+'.log',errors='replace'):
        ts,_,t=line.partition('\t'); ts=int(ts)
        rows.append((ts,t.rstrip()))
    return tl,rows
def seg_of(ts,tl):
    for name,a,b in [('idleA','idleA_start','idleA_end'),('seg1','seg1_start','seg1_end'),
                     ('seg2','seg2_start','seg2_end'),('seg3','seg3_start','seg3_end')]:
        if tl[a]<=ts<=tl[b]: return name
    return None
PACE=re.compile(r"tick/s=(\d+) sceneUpd/s=(\d+) hudUpd/s=(\d+) render/s=(\d+) wake/s=(\d+) changed/s=(\d+) gpu=([\d.]+)ms\((\w+)\) interval=(\d+)ms timerActive=(\d+) sleeping=(\d+) sceneSleeping=(\d+) rotating=(\d+) hudAnimating=(\d+) pendingAnim=(\d+) stableFrames=(\d+) \| 间隔均=([\d.]+)ms 最大=([\d.]+)ms step均=([\d.]+)ms 最大=([\d.]+)ms")
COST=re.compile(r"拍成本: 合计 ([\d.]+) ms = app->step ([\d.]+) \+ 其余 ([\d.]+) \| 线程CPU ([\d.]+) ms \| 等待 ([\d.]+) ms")
APP=re.compile(r"app->step 内部: 场景采样 ([\d.]+)/峰([\d.]+) ms \| HUD 绘制 ([\d.]+)/峰([\d.]+) ms \| 其余\(观察\+返回拷贝\) ([\d.]+)/峰([\d.]+) ms")
D3=re.compile(r"3D内部: 后处理 ([\d.]+) +纹理 ([\d.]+)/峰([\d.]+) +draw列表 ([\d.]+)/峰([\d.]+) +构建 ([\d.]+)/峰([\d.]+) +录制 ([\d.]+)/峰([\d.]+) ms \| draws (\d+)")
TEX=re.compile(r"准入 (\d+)/(\d+)（未准入跳过 (\d+)） \| 取消 (\d+) \| 在途峰值 (\d+) \| 纹理 (\d+) / ([\d.]+) MiB \| 标签 (\d+)\(([\d.]+)ms\)")
def collect(tags):
    out={}
    for tag in tags:
        tl,rows=load(tag)
        for ts,t in rows:
            s=seg_of(ts,tl)
            if not s: continue
            m=PACE.search(t)
            if m:
                g=[float(m.group(i)) for i in (1,2,3,4,5,6)]; 
                out.setdefault((s,'pace'),[]).append(dict(tick=g[0],scene=g[1],hud=g[2],render=g[3],wake=g[4],changed=g[5],
                    gpu=float(m.group(7)),gstatus=m.group(8),interval=float(m.group(9)),sleeping=float(m.group(11)),
                    sceneSleeping=float(m.group(12)),pendingAnim=float(m.group(15)),stable=float(m.group(16)),
                    step=float(m.group(19)),stepMx=float(m.group(20)),gap=float(m.group(17))))
                continue
            m=COST.search(t)
            if m: out.setdefault((s,'cost'),[]).append(dict(total=float(m.group(1)),app=float(m.group(2)),rest=float(m.group(3)))); continue
            m=APP.search(t)
            if m: out.setdefault((s,'app'),[]).append(dict(sample=float(m.group(1)),sampleMx=float(m.group(2)),hud=float(m.group(3)),hudMx=float(m.group(4)),rest=float(m.group(5)))); continue
            m=D3.search(t)
            if m: out.setdefault((s,'d3'),[]).append(dict(tex=float(m.group(2)),texMx=float(m.group(3)),lst=float(m.group(4)),lstMx=float(m.group(5)),bld=float(m.group(6)),bldMx=float(m.group(7)),rec=float(m.group(8)),recMx=float(m.group(9)),draws=float(m.group(10)))); continue
            m=TEX.search(t)
            if m: out.setdefault((s,'tex'),[]).append(dict(adm=float(m.group(1)),tries=float(m.group(2)),skip=float(m.group(3)),cancel=float(m.group(4)),peak=float(m.group(5)),created=float(m.group(6)),mib=float(m.group(7)),labels=float(m.group(8)),labelMs=float(m.group(9)))); continue
    return out
def avg(rows,k):
    v=[r.get(k) for r in rows if r.get(k) is not None]
    return sum(v)/len(v) if v else float('nan')
A=collect(['delay0-d0b','delay0-d0c']); B=collect(['delay100-d100b','delay100-d100c'])
print(f"{'段/指标':34s}{'delay0':>10s}{'delay100':>10s}{'Δ':>9s}")
def row(label,s,kind,keys,fmt='%8.2f'):
    ra=A.get((s,kind),[]); rb=B.get((s,kind),[])
    if not ra or not rb: return
    for k in keys:
        a,b=avg(ra,k),avg(rb,k)
        print(f"  {label+' '+k:32s}{fmt%a:>10s}{fmt%b:>10s}{fmt%(b-a):>9s}")
for s in ('seg1','seg2','seg3'):
    print(f"\n== {s}")
    row('pace',s,'pace',['render','tick','step','gpu','wake','gap'])
    row('app',s,'app',['sample','hud','sampleMx','hudMx'])
    row('d3',s,'d3',['tex','lst','bld','rec','texMx','lstMx','bldMx','recMx','draws'])
    row('tex',s,'tex',['adm','tries','skip','labels','labelMs','created','mib'])
    ra=A.get((s,'pace'),[]); rb=B.get((s,'pace'),[])
    if ra and rb:
        for name,rows in (('delay0',ra),('delay100',rb)):
            t=avg(rows,'tick'); r=avg(rows,'render'); st_=avg(rows,'step'); g=avg(rows,'gpu')
            print(f"  派生 {name:9s} tick/frame={t/max(r,1e-9):.2f}  CPU/s={t*st_/1000:.2f}s  每帧CPU={st_*t/max(r,1e-9):.2f}ms  GPU占用={g*r/10:.0f}%  帧期={1000/max(r,1e-9):.1f}ms")
print("\n== seg3 逐秒（delay0 / delay100 第一轮）")
for tag in ('delay0-d0b','delay100-d100b','delay0-d0c','delay100-d100c'):
    tl,rows=load(tag); print('--',tag)
    for ts,t in rows:
        if seg_of(ts,tl)!='seg3': continue
        m=PACE.search(t)
        if m: print(f"   t+{(ts-tl['seg3_start'])/1000:4.1f}s render={m.group(4):>3} tick={m.group(1):>3} step={m.group(19):>5} max={m.group(20):>5} gpu={m.group(7):>5} sleep={m.group(11)} sceneSleep={m.group(12)} pendAnim={m.group(15)} stable={m.group(16):>3} gap={m.group(17):>6}")
