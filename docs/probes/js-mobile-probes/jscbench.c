#include <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
static double now(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec*1000.0+ts.tv_nsec/1e6; }
int main(void){
  double t0 = now();
  JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
  double tcreate = now()-t0;
  /* representative of kaya's wire packing: DataView writes + UTF-8 encode by hand + Uint8Array copies */
  const char* src =
  "globalThis.pack=function(n){"
  " let total=0;"
  " for(let i=0;i<n;i++){"
  "   const s='widget-'+i+'-label';"
  "   const b=new Uint8Array(64); const v=new DataView(b.buffer);"
  "   v.setUint32(0, 64, true); v.setUint16(4, 12, true); v.setUint16(6, 0, true);"
  "   v.setFloat64(8, i*1.5, true); v.setBigInt64(16, BigInt(i), true);"
  "   let at=24; for(let k=0;k<s.length;k++){ const c=s.charCodeAt(k); if(c<128) b[at++]=c; else { b[at++]=0xC0|(c>>6); b[at++]=0x80|(c&63);} }"
  "   total += b[at-1] + v.getUint32(0,true);"
  " } return total; };"
  "const t=Date.now(); const r=pack(200000); r;";
  JSStringRef s = JSStringCreateWithUTF8CString(src);
  double t1 = now();
  JSValueRef exc=NULL; JSValueRef r = JSEvaluateScript(ctx,s,NULL,NULL,1,&exc);
  double trun = now()-t1;
  if (exc){ JSStringRef m=JSValueToStringCopy(ctx,exc,NULL); char b[512]; JSStringGetUTF8CString(m,b,sizeof b); printf("THREW %s\n",b); return 1; }
  printf("ctxCreate=%.1fms  pack(200000)=%.0fms  result=%.0f  JIT=%s\n",
         tcreate, trun, JSValueToNumber(ctx,r,NULL), getenv("JSC_useJIT")?getenv("JSC_useJIT"):"(default)");
  JSStringRelease(s); JSGlobalContextRelease(ctx);
  return 0;
}
