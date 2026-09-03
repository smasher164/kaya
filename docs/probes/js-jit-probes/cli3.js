var out=(typeof print==="function")?print:console.log, now=Date.now, t;
t=now(); {let x=0; for(let i=0;i<50000000;i++) x=(x+i*3)|0;} out("arith\t"+(now()-t));
t=now(); {const u=new Uint8Array(1024); let s=0; for(let i=0;i<20000000;i++){ u[i&1023]=i&255; s+=u[i&1023]; }} out("typedarray\t"+(now()-t));
t=now(); {let s=''; for(let i=0;i<200000;i++){ s='w'+i; }} out("strings\t"+(now()-t));
