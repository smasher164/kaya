#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static JSGlobalContextRef g_ctx;
static double now(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec*1000.0+ts.tv_nsec/1e6; }
static JSValueRef napSleep(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;(void)e; usleep(20000); return JSValueMakeUndefined(c); }
static void ev(const char* src){ JSStringRef s=JSStringCreateWithUTF8CString(src); JSValueRef x=NULL;
  JSEvaluateScript(g_ctx,s,NULL,NULL,1,&x); JSStringRelease(s); }
static void* busyJS(void* a){ (void)a; ev("{let x=0; for(let i=0;i<60000000;i++) x+=i; x;}"); return NULL; }
static void* nativeSleep(void* a){ (void)a; ev("nap();"); return NULL; }

static double timeThreads(void*(*fn)(void*), int n){
  pthread_t t[8]; double t0=now();
  for(int i=0;i<n;i++) pthread_create(&t[i],NULL,fn,NULL);
  for(int i=0;i<n;i++) pthread_join(t[i],NULL);
  return now()-t0;
}
int main(void){
  g_ctx = JSGlobalContextCreate(NULL);
  JSStringRef s=JSStringCreateWithUTF8CString("nap");
  JSObjectSetProperty(g_ctx, JSContextGetGlobalObject(g_ctx), s,
    JSObjectMakeFunctionWithCallback(g_ctx,s,napSleep),0,NULL); JSStringRelease(s);

  double one = timeThreads(busyJS,1);
  double four = timeThreads(busyJS,4);
  printf("PURE JS busy loop, one JSContext:  1 thread %.0fms, 4 threads %.0fms  (ratio %.2f)\n", one, four, four/one);
  printf("  => %s\n", four/one > 2.5 ? "SERIALISED: the VM's API lock is held across JS execution"
                                      : "CONCURRENT: JS ran in parallel in one context");

  double n1 = timeThreads(nativeSleep,1);
  double n4 = timeThreads(nativeSleep,4);
  printf("NATIVE callback sleeping 20ms:     1 thread %.0fms, 4 threads %.0fms  (ratio %.2f)\n", n1, n4, n4/n1);
  printf("  => %s\n", n4/n1 > 2.5 ? "the API lock is HELD across a native callback (a blocking native fn stalls every thread)"
                                   : "the API lock is DROPPED around a native callback");
  return 0;
}
