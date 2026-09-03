#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>

static JSGlobalContextRef g_ctx;
static atomic_int inJS = 0, maxInJS = 0;
static atomic_int inNative = 0, maxInNative = 0;

static void bump(atomic_int* cur, atomic_int* mx, int d) {
  if (d > 0) { int c = atomic_fetch_add(cur, 1) + 1; int p = atomic_load(mx);
               while (c > p && !atomic_compare_exchange_weak(mx, &p, c)) {} }
  else atomic_fetch_sub(cur, 1);
}
static JSValueRef enterJS(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;(void)e; bump(&inJS,&maxInJS,1); return JSValueMakeUndefined(c); }
static JSValueRef leaveJS(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;(void)e; bump(&inJS,&maxInJS,-1); return JSValueMakeUndefined(c); }
static JSValueRef sleepNative(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;(void)e; bump(&inNative,&maxInNative,1); usleep(3000); bump(&inNative,&maxInNative,-1);
  return JSValueMakeUndefined(c); }

static void def(const char* name, JSObjectCallAsFunctionCallback cb) {
  JSStringRef s = JSStringCreateWithUTF8CString(name);
  JSObjectSetProperty(g_ctx, JSContextGetGlobalObject(g_ctx), s,
                      JSObjectMakeFunctionWithCallback(g_ctx, s, cb), 0, NULL);
  JSStringRelease(s);
}
static void ev(const char* src) {
  JSStringRef s = JSStringCreateWithUTF8CString(src);
  JSValueRef exc = NULL; JSEvaluateScript(g_ctx, s, NULL, NULL, 1, &exc); JSStringRelease(s);
  if (exc) { JSStringRef m = JSValueToStringCopy(g_ctx, exc, NULL);
             char b[512]; JSStringGetUTF8CString(m, b, sizeof b); printf("  THREW %s\n", b); JSStringRelease(m); }
}
static void* pureJS(void* a){ (void)a; for(int i=0;i<20;i++) ev("enterJS(); { let x=0; for(let i=0;i<4000000;i++) x+=i; } leaveJS();"); return NULL; }
static void* viaNative(void* a){ (void)a; for(int i=0;i<20;i++) ev("sleepNative();"); return NULL; }

int main(void){
  g_ctx = JSGlobalContextCreate(NULL);
  def("enterJS", enterJS); def("leaveJS", leaveJS); def("sleepNative", sleepNative);

  pthread_t t[4];
  for (int i=0;i<4;i++) pthread_create(&t[i],NULL,pureJS,NULL);
  for (int i=0;i<4;i++) pthread_join(t[i],NULL);
  printf("4 threads running PURE JS in one JSContext: maxConcurrentInsideJS = %d  => %s\n",
         atomic_load(&maxInJS),
         atomic_load(&maxInJS)==1 ? "SERIALISED by the API lock" : "CONCURRENT (no serialisation!)");

  for (int i=0;i<4;i++) pthread_create(&t[i],NULL,viaNative,NULL);
  for (int i=0;i<4;i++) pthread_join(t[i],NULL);
  printf("4 threads blocked in a NATIVE callback:     maxConcurrentInNative = %d  => %s\n",
         atomic_load(&maxInNative),
         atomic_load(&maxInNative)==1 ? "lock held across the callback" : "lock DROPPED around the native callback");
  return 0;
}
