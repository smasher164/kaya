#include <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
static double now(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec*1000.0+ts.tv_nsec/1e6; }
static double run(JSGlobalContextRef ctx, const char* src){
  JSStringRef s=JSStringCreateWithUTF8CString(src); JSValueRef e=NULL;
  double t=now(); JSEvaluateScript(ctx,s,NULL,NULL,1,&e); double d=now()-t; JSStringRelease(s);
  if(e){printf("THREW\n");} return d; }
int main(void){
  JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
  double a = run(ctx, "{let x=0; for(let i=0;i<50000000;i++) x=(x+i*3)|0; x;}");
  double b = run(ctx, "{const u=new Uint8Array(1024); let s=0; for(let i=0;i<20000000;i++){ u[i&1023]=i&255; s+=u[i&1023]; } s;}");
  double c = run(ctx, "{let s=''; for(let i=0;i<200000;i++){ s = 'w'+i; } s.length;}");
  printf("JIT=%-8s arith=%.0fms  typedarray=%.0fms  strings=%.0fms\n",
         getenv("JSC_useJIT")?getenv("JSC_useJIT"):"default", a,b,c);
  return 0; }
