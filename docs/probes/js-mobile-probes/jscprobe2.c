#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>

static JSGlobalContextRef g_ctx;
static atomic_int g_inside = 0, g_maxOverlap = 0, g_calls = 0;

static char* eval(JSGlobalContextRef ctx, const char* src) {
  JSStringRef s = JSStringCreateWithUTF8CString(src);
  JSValueRef exc = NULL;
  JSValueRef r = JSEvaluateScript(ctx, s, NULL, NULL, 1, &exc);
  JSStringRelease(s);
  JSValueRef v = exc ? exc : r;
  JSStringRef m = JSValueToStringCopy(ctx, v, NULL);
  size_t n = JSStringGetMaximumUTF8CStringSize(m); char* buf = malloc(n + 8);
  if (exc) { strcpy(buf, "THREW: "); JSStringGetUTF8CString(m, buf + 7, n); }
  else JSStringGetUTF8CString(m, buf, n);
  JSStringRelease(m);
  return buf;
}
static void show(const char* label, char* v) { printf("%-34s => %s\n", label, v); free(v); }

/* a native fn that records how many threads are inside JS at once */
static JSValueRef spin(JSContextRef ctx, JSObjectRef f, JSObjectRef t, size_t argc,
                       const JSValueRef argv[], JSValueRef* exc) {
  (void)f;(void)t;(void)argc;(void)argv;(void)exc;
  int cur = atomic_fetch_add(&g_inside, 1) + 1;
  int prev = atomic_load(&g_maxOverlap);
  while (cur > prev && !atomic_compare_exchange_weak(&g_maxOverlap, &prev, cur)) {}
  atomic_fetch_add(&g_calls, 1);
  usleep(2000);
  atomic_fetch_sub(&g_inside, 1);
  return JSValueMakeUndefined(ctx);
}

static void* hammer(void* arg) {
  (void)arg;
  for (int i = 0; i < 40; i++) { free(eval(g_ctx, "spin(); 0")); }
  return NULL;
}

/* the PUMP shape: native thread calls a JS function it was handed */
static JSObjectRef g_handler = NULL;
static void* pump(void* arg) {
  (void)arg;
  for (int i = 0; i < 3; i++) {
    unsigned char rec[3] = { (unsigned char)i, 0xAA, 0xBB };
    JSValueRef exc = NULL;
    JSObjectRef arr = JSObjectMakeTypedArray(g_ctx, kJSTypedArrayTypeUint8Array, 3, &exc);
    void* p = JSObjectGetTypedArrayBytesPtr(g_ctx, arr, &exc);
    memcpy(p, rec, 3);
    JSValueRef args[1] = { arr };
    JSObjectCallAsFunction(g_ctx, g_handler, NULL, 1, args, &exc);
    if (exc) printf("  [pump] handler threw\n");
  }
  return NULL;
}

int main(void) {
  g_ctx = JSGlobalContextCreate(NULL);
  JSObjectRef global = JSContextGetGlobalObject(g_ctx);
  JSStringRef nm = JSStringCreateWithUTF8CString("spin");
  JSObjectSetProperty(g_ctx, global, nm, JSObjectMakeFunctionWithCallback(g_ctx, nm, spin), 0, NULL);
  JSStringRelease(nm);

  printf("== typed array byteOffset ==\n");
  show("a=[0..5]; s=a.subarray(2,5)", eval(g_ctx, "globalThis.a=new Uint8Array([0,1,2,3,4,5]); globalThis.s=a.subarray(2,5); s.join(',')"));
  {
    JSValueRef exc = NULL;
    JSStringRef k = JSStringCreateWithUTF8CString("s");
    JSObjectRef s = JSValueToObject(g_ctx, JSObjectGetProperty(g_ctx, global, k, &exc), &exc);
    JSStringRelease(k);
    unsigned char* p = JSObjectGetTypedArrayBytesPtr(g_ctx, s, &exc);
    size_t len = JSObjectGetTypedArrayByteLength(g_ctx, s, &exc);
    size_t off = JSObjectGetTypedArrayByteOffset(g_ctx, s, &exc);
    printf("%-34s => bytesPtr[0..len)=%u,%u,%u  byteLength=%zu byteOffset=%zu\n",
           "C API reads the VIEW", p[0], p[1], p[2], len, off);
    printf("%-34s => %s\n", "  => bytesPtr already view-based?",
           (p[0] == 2) ? "YES, offset already applied" : "NO, it is the BUFFER base - add byteOffset");
  }

  printf("\n== Atomics without SharedArrayBuffer ==\n");
  show("SharedArrayBuffer", eval(g_ctx, "typeof SharedArrayBuffer"));
  show("Atomics.wait on plain Int32Array", eval(g_ctx, "(()=>{try{ return String(Atomics.wait(new Int32Array(new ArrayBuffer(4)),0,0,10)); }catch(e){ return 'threw '+e.name+': '+e.message; }})()"));

  printf("\n== dynamic import() actually resolving ==\n");
  show("import('./x.js')", eval(g_ctx, "(()=>{try{ const p = import('./x.js'); p.then(()=>globalThis.impres='resolved', (e)=>globalThis.impres='rejected: '+e.message); return 'call returned '+(p&&p.constructor.name);}catch(e){return 'threw '+e.name;}})()"));
  show("  (after drain)", eval(g_ctx, "String(globalThis.impres)"));

  printf("\n== two threads hammering ONE JSContext ==\n");
  pthread_t a, b, c;
  pthread_create(&a, NULL, hammer, NULL);
  pthread_create(&b, NULL, hammer, NULL);
  pthread_create(&c, NULL, hammer, NULL);
  pthread_join(a, NULL); pthread_join(b, NULL); pthread_join(c, NULL);
  printf("%-34s => calls=%d maxThreadsInsideJSAtOnce=%d\n", "3 threads x 40 evals",
         atomic_load(&g_calls), atomic_load(&g_maxOverlap));
  printf("%-34s => %s\n", "  => VM serialises?",
         atomic_load(&g_maxOverlap) == 1 ? "YES, exactly one at a time (the API lock)" : "NO, concurrent entry observed");

  printf("\n== the PUMP: native thread calls a JS handler ==\n");
  free(eval(g_ctx, "globalThis.seen=[]; globalThis.onOccurrence=(u8)=>{ seen.push(u8[0]); };"));
  {
    JSValueRef exc = NULL;
    JSStringRef k = JSStringCreateWithUTF8CString("onOccurrence");
    g_handler = JSValueToObject(g_ctx, JSObjectGetProperty(g_ctx, global, k, &exc), &exc);
    JSStringRelease(k);
    JSValueProtect(g_ctx, g_handler);
  }
  pthread_t p; pthread_create(&p, NULL, pump, NULL); pthread_join(p, NULL);
  show("seen after 3 pumped records", eval(g_ctx, "seen.join(',')"));

  printf("\n== implicit-commit shape: microtask inside a pumped call ==\n");
  free(eval(g_ctx, "globalThis.order=[]; globalThis.onOccurrence=(u8)=>{ order.push('h'+u8[0]); Promise.resolve().then(()=>order.push('commit'+u8[0])); };"));
  {
    JSValueRef exc = NULL;
    JSStringRef k = JSStringCreateWithUTF8CString("onOccurrence");
    g_handler = JSValueToObject(g_ctx, JSObjectGetProperty(g_ctx, global, k, &exc), &exc);
    JSStringRelease(k);
  }
  pthread_create(&p, NULL, pump, NULL); pthread_join(p, NULL);
  show("order", eval(g_ctx, "order.join(',')"));
  printf("%-34s => %s\n", "  => commit runs per call?", "read the interleaving above");
  return 0;
}
