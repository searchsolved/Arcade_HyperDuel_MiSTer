import csv, sys, collections
csv.field_size_limit(sys.maxsize)
path='/Users/leefoot/python_scripts/hyperduel-mister/sim/build/ramphunt_11/raster_writes_sim.csv'
FG={'478872':'sx0','478874':'sy1','478876':'sx1','47887a':'sx2'}
writes=collections.defaultdict(list)   # reg -> list of (frame, value)
ramp_frames=set()
with open(path) as f:
    next(f)
    for line in f:
        parts=line.strip().split(",")
        if len(parts)!=5: continue
        frame,vpos,hpos,addr,data=parts
        if addr in FG:
            writes[addr].append((int(frame),int(data,16)))
        elif addr in ('478870','478878') and int(vpos)>=224:
            ramp_frames.add(int(frame))
print(f"ramp frames: {len(ramp_frames)} ({min(ramp_frames)}..{max(ramp_frames)})" if ramp_frames else "no ramp")
def s16(x):
    x&=0xFFFF
    return x-65536 if x>32768 else x
for addr,name in FG.items():
    seq=writes[addr]
    # last write per frame (game writes once per frame during line 0)
    perfr={}
    for fr,v in seq: perfr[fr]=v
    frames=sorted(perfr)
    errs=[]; ramp_errs=[]
    for i in range(2,len(frames)):
        f2,f1,f0=frames[i],frames[i-1],frames[i-2]
        if f2-f1==1 and f1-f0==1:   # consecutive frames: predictor has valid prev
            pred=(perfr[f1]+(perfr[f1]-perfr[f0]))&0xFFFF
            e=s16(perfr[f2]-pred)
            errs.append(e)
            if f2 in ramp_frames: ramp_errs.append(e)
    def summ(es):
        if not es: return "n=0"
        h=collections.Counter(abs(e) for e in es)
        exact=h[0]; small=sum(v for k,v in h.items() if 1<=k<=2)
        big=sum(v for k,v in h.items() if k>2)
        mx=max(abs(e) for e in es)
        return f"n={len(es)} exact={exact} err1-2px={small} err>2px={big} max={mx}"
    # stale (old behavior) error for comparison: err_stale = v[f2]-v[f1]
    stale=[s16(perfr[frames[i]]-perfr[frames[i-1]]) for i in range(1,len(frames)) if frames[i]-frames[i-1]==1]
    stale_ramp=[s16(perfr[frames[i]]-perfr[frames[i-1]]) for i in range(1,len(frames)) if frames[i]-frames[i-1]==1 and frames[i] in ramp_frames]
    print(f"\n{name} ({addr}): writes={len(seq)} frames-with-write={len(frames)}")
    print(f"  predicted : {summ(errs)}")
    print(f"  ramp only : {summ(ramp_errs)}")
    print(f"  stale(old): {summ(stale)}")
    print(f"  stale ramp: {summ(stale_ramp)}")
