from ramp import *
def lch(h): return lab2lch(srgb2lab(hexrgb(h)))
def lum(h):
    r=lin(hexrgb(h)); return 0.2126*r[0]+0.7152*r[1]+0.0722*r[2]
def cr(a,b):
    x,y=sorted([lum(a),lum(b)]); return (y+0.05)/(x+0.05)
def over(fg,a,bg):
    f=hexrgb(fg); b=hexrgb(bg); return '#'+''.join('%02X'%round(255*(a*f[i]+(1-a)*b[i])) for i in range(3))
ramps={'brandWeb':{160:'#ebf3fc',150:'#cfe4fa',80:'#0f6cbd',20:'#082338',30:'#0a2e4a'},
       'brandTeams':{160:'#e8ebfa',150:'#dce0fa',80:'#5b5fc7',20:'#2f2f4a',30:'#333357'},
       'brandTeamsV21':{160:'#e8e8ff',150:'#dcdbff',80:'#654cf5',20:'#2f2a5e',30:'#352e70'}}
if __name__=='__main__':
    for n,r in ramps.items():
        k=lch(r[80])
        for s,h in sorted(r.items()):
            L,C,H=lch(h); print(f'{n:14} {s:4} {h} L={L:5.1f} C={C:5.1f} H={H:5.1f} C/Ckey={C/k[1]:.3f} cr(#242424)={cr(h,"#242424"):5.2f} cr(#fff)={cr(h,"#ffffff"):5.2f}')
