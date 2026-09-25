import math, re, sys
HM=[[float(v) for v in m] for m in re.findall(r'\[([\d.e-]+), ([\d.e-]+), ([\d.e-]+)\]', open('hueMap.ts',encoding='utf-8').read())]
def mm(M,v): return [sum(M[i][j]*v[j] for j in range(3)) for i in range(3)]
def lin(c): return [ (v/12.92 if abs(v)<0.04045 else math.copysign(((abs(v)+0.055)/1.055)**2.4,v)) for v in c]
def gam(c): return [ (math.copysign(1.055*abs(v)**(1/2.4)-0.055,v) if abs(v)>0.0031308 else 12.92*v) for v in c]
M1=[[0.41239079926595934,0.357584339383878,0.1804807884018343],[0.21263900587151027,0.715168678767756,0.07219231536073371],[0.01933081871559182,0.11919477979462598,0.9505321522496607]]
M2=[[3.2409699419045226,-1.537383177570094,-0.4986107602930034],[-0.9692436362808796,1.8759675015077202,0.04155505740717559],[0.05563007969699366,-0.20397695888897652,1.0569715142428786]]
A1=[[1.0479298208405488,0.022946793341019088,-0.05019222954313557],[0.029627815688159344,0.990434484573249,-0.01707382502938514],[-0.009243058152591178,0.015055144896577895,0.7518742899580008]]
A2=[[0.9554734527042182,-0.023098536874261423,0.0632593086610217],[-0.028369706963208136,1.0099954580058226,0.021041398966943008],[0.012314001688319899,-0.020507696433477912,1.3303659366080753]]
W=[0.96422,1.0,0.82521]; e=216/24389; k=24389/27
def xyz2lab(X):
    x=[X[i]/W[i] for i in range(3)]; f=[(math.copysign(abs(v)**(1/3),v) if v>e else (k*v+16)/116) for v in x]
    return [116*f[1]-16,500*(f[0]-f[1]),200*(f[1]-f[2])]
def lab2xyz(L):
    f1=(L[0]+16)/116; f0=L[1]/500+f1; f2=f1-L[2]/200
    x=[f0**3 if f0**3>e else (116*f0-16)/k, ((L[0]+16)/116)**3 if L[0]>k*e else L[0]/k, f2**3 if f2**3>e else (116*f2-16)/k]
    return [x[i]*W[i] for i in range(3)]
def lab2lch(L):
    h=math.atan2(L[2],L[1])*180/math.pi; return [L[0],math.hypot(L[1],L[2]),h if h>=0 else h+360]
def lch2lab(C): return [C[0],C[1]*math.cos(C[2]*math.pi/180),C[1]*math.sin(C[2]*math.pi/180)]
def srgb2lab(c): return xyz2lab(mm(A1,mm(M1,lin(c))))
def lab2srgb(L): return gam(mm(M2,mm(A2,lab2xyz(L))))
def inside(l,c,h): return all(-5e-6<=v<=1+5e-6 for v in lab2srgb(lch2lab([l,c,h])))
def snap(L):
    l,c,h=lab2lch(L)
    if inside(l,c,h): return L
    hi,lo=c,0; c/=2
    while hi-lo>1e-4:
        if inside(l,c,h): lo=c
        else: hi=c
        c=(hi+lo)/2
    return lch2lab([l,c,h])
def hexrgb(s): return [int(s[i:i+2],16)/255 for i in (1,3,5)]
def tohex(rgb): return '#'+''.join('%02x'%(0 if x<0 else math.floor(255 if x>=1 else x*256)) for x in rgb)
def hexhue(s):
    r,g,b=hexrgb(s); mx=max(r,g,b); mn=min(r,g,b); d=mx-mn
    if d==0: h=0
    elif mx==r: h=math.fmod((g-b)/d,6)
    elif mx==g: h=(b-r)/d+2
    else: h=(r-g)/d+4
    h=math.floor(h*60+0.5)  # Math.round
    return h+360 if h<0 else h
def qb(t,p0,p1,p2): return (1-t)**2*p0+2*(1-t)*t*p1+t*t*p2
def ptscurve(c,n): return [[qb(d/n,c[0][i],c[1][i],c[2][i]) for i in range(3)] for d in range(n+1)]
def ramp(key,darkCp=2/3,lightCp=1/3,torsion=0,linearity=1,depth=24,n=16):
    L=srgb2lab(hexrgb(key)); l,a,b=L
    curves=[[[0,0,0],[l*(1-darkCp),a,b],L],[L,[l+(100-l)*lightCp,a,b],[100,0,0]]]
    div=math.ceil(depth*(1+abs(torsion or 1))/2)
    pts=[];last=None
    for c in curves:
        for p in ptscurve(c,div):
            if last is not None and p==last: continue
            pts.append(p); last=p
    def helix(p):
        t=p[0]; ll,cc,hh=lab2lch(p); return lch2lab([ll,cc,hh+torsion*(t-l)])
    pts=[helix(p) for p in pts]
    hue=hexhue(key); sp=[v*100 for v in HM[hue]]
    start,end,mid=sp[0],sp[2],sp[1]
    r=(mid-start)/(end-start); idx=math.floor((n-1)*r)
    lin_=[None]*n; lin_[0]=start; lin_[idx]=mid; lin_[n-1]=end
    for i in range(1,idx): lin_[i]=start+i*(mid-start)/idx
    for i in range(idx+1,n-1): lin_[i]=mid+(i-idx)*(end-mid)/(n-1-idx)
    # log space: log10(0) = -inf -> a=0 since min<=0
    A=0; B=math.log(math.log10(100)); dl=(B-A)/n
    logs=[math.e**A]+[math.e**(A+dl*i) for i in range(1,n)]+[math.e**B]
    out=[];c=0
    for i in range(n):
        lv=min(end,max(start,logs[i]*(1-linearity)+lin_[i]*linearity))
        while lv>pts[c+1][0]: c+=1
        (l1,a1,b1),(l2,a2,b2)=pts[c],pts[c+1]; u=(lv-l1)/(l2-l1)
        out.append(snap([l1+(l2-l1)*u,a1+(a2-a1)*u,b1+(b2-b1)*u]))
    return {(i+1)*10:tohex(lab2srgb(p)) for i,p in enumerate(out)}
if __name__=='__main__':
    for key in sys.argv[1:]:
        print(key, ramp(key))
