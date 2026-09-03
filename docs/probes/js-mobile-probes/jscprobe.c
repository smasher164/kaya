#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static JSValueRef native_take(JSContextRef ctx, JSObjectRef fn, JSObjectRef thisObj,
                              size_t argc, const JSValueRef argv[], JSValueRef* exc) {
  (void)fn; (void)thisObj;
  if (argc < 1) return JSValueMakeUndefined(ctx);
  JSTypedArrayType t = JSValueGetTypedArrayType(ctx, argv[0], exc);
  JSObjectRef o = JSValueToObject(ctx, argv[0], exc);
  void* p = JSObjectGetTypedArrayBytesPtr(ctx, o, exc);
  size_t n = JSObjectGetTypedArrayByteLength(ctx, o, exc);
  printf("  [native] took typedArrayType=%d len=%zu first=%u last=%u\n",
         (int)t, n, n ? ((unsigned char*)p)[0] : 0, n ? ((unsigned char*)p)[n-1] : 0);
  // hand back a NEW Uint8Array of 4 bytes (copy-in)
  unsigned char out[4] = {9, 8, 7, 6};
  JSObjectRef arr = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, 4, exc);
  void* dst = JSObjectGetTypedArrayBytesPtr(ctx, arr, exc);
  memcpy(dst, out, 4);
  return arr;
}

static void freeit(void* b, void* c) { (void)c; free(b); }

static JSValueRef native_nocopy(JSContextRef ctx, JSObjectRef fn, JSObjectRef thisObj,
                                size_t argc, const JSValueRef argv[], JSValueRef* exc) {
  (void)fn; (void)thisObj; (void)argc; (void)argv;
  unsigned char* b = malloc(3); b[0]=1; b[1]=2; b[2]=3;
  return JSObjectMakeTypedArrayWithBytesNoCopy(ctx, kJSTypedArrayTypeUint8Array, b, 3, freeit, NULL, exc);
}

static void run(JSGlobalContextRef ctx, const char* label, const char* src) {
  JSStringRef s = JSStringCreateWithUTF8CString(src);
  JSValueRef exc = NULL;
  JSValueRef r = JSEvaluateScript(ctx, s, NULL, NULL, 1, &exc);
  JSStringRelease(s);
  if (exc) {
    JSStringRef m = JSValueToStringCopy(ctx, exc, NULL);
    size_t n = JSStringGetMaximumUTF8CStringSize(m); char* buf = malloc(n);
    JSStringGetUTF8CString(m, buf, n);
    printf("%-28s THREW: %s\n", label, buf); free(buf); JSStringRelease(m);
    return;
  }
  JSStringRef m = JSValueToStringCopy(ctx, r, NULL);
  size_t n = JSStringGetMaximumUTF8CStringSize(m); char* buf = malloc(n);
  JSStringGetUTF8CString(m, buf, n);
  printf("%-28s => %s\n", label, buf); free(buf); JSStringRelease(m);
}

static JSGlobalContextRef g_ctx;
static JSContextGroupRef g_group;

static void* worker(void* arg) {
  (void)arg;
  printf("\n== on a BACKGROUND pthread, main thread is asleep ==\n");
  JSGlobalContextRef ctx = g_ctx;

  // install natives
  JSObjectRef global = JSContextGetGlobalObject(ctx);
  JSStringRef nm = JSStringCreateWithUTF8CString("nativeTake");
  JSObjectSetProperty(ctx, global, nm, JSObjectMakeFunctionWithCallback(ctx, nm, native_take), 0, NULL);
  JSStringRelease(nm);
  nm = JSStringCreateWithUTF8CString("nativeNoCopy");
  JSObjectSetProperty(ctx, global, nm, JSObjectMakeFunctionWithCallback(ctx, nm, native_nocopy), 0, NULL);
  JSStringRelease(nm);

  run(ctx, "engine identity", "typeof globalThis");
  run(ctx, "ES2022 (at)", "[1,2,3].at(-1)");
  run(ctx, "ES2024 groupBy", "typeof Object.groupBy");
  run(ctx, "Proxy", "typeof Proxy");
  run(ctx, "BigInt/DataView", "typeof BigInt + ',' + typeof DataView");
  run(ctx, "TextEncoder", "typeof TextEncoder");
  run(ctx, "TextDecoder", "typeof TextDecoder");
  run(ctx, "queueMicrotask", "typeof queueMicrotask");
  run(ctx, "setTimeout", "typeof setTimeout");
  run(ctx, "setImmediate", "typeof setImmediate");
  run(ctx, "console", "typeof console");
  run(ctx, "SharedArrayBuffer", "typeof SharedArrayBuffer");
  run(ctx, "Atomics", "typeof Atomics");
  run(ctx, "Atomics.wait", "typeof Atomics === 'object' ? typeof Atomics.wait : 'n/a'");
  run(ctx, "WeakRef/FinalizationReg", "typeof WeakRef + ',' + typeof FinalizationRegistry");
  run(ctx, "structuredClone", "typeof structuredClone");
  run(ctx, "import() dynamic", "(()=>{try{ (0,eval)('import(\"x\")'); return 'parsed'; }catch(e){ return 'refused: '+e.name; }})()");
  run(ctx, "import stmt in script", "(()=>{try{ (0,eval)('import * as x from \"y\";'); return 'parsed'; }catch(e){ return 'refused: '+e.constructor.name; }})()");

  printf("\n-- bytes across the boundary --\n");
  run(ctx, "nativeTake(Uint8Array)", "(()=>{const a=new Uint8Array([11,22,33,44]); const b=nativeTake(a); return b.constructor.name+':'+Array.from(b).join(',');})()");
  run(ctx, "nativeNoCopy()", "(()=>{const b=nativeNoCopy(); return b.constructor.name+':'+Array.from(b).join(',');})()");
  run(ctx, "subarray offset survives", "(()=>{const a=new Uint8Array([0,1,2,3,4,5]); const s=a.subarray(2,5); nativeTake(s); return s.byteOffset+'/'+s.byteLength;})()");

  printf("\n-- microtask drain across the API boundary --\n");
  run(ctx, "setup log", "globalThis.log=[]; 'ok'");
  run(ctx, "queue a microtask", "Promise.resolve().then(()=>log.push('micro')); log.push('sync'); log.join(',')");
  run(ctx, "AFTER JSEvaluateScript", "log.join(',')");
  run(ctx, "async fn resolution", "(async()=>{log.push('a'); await null; log.push('b');})(); log.join(',')");
  run(ctx, "AFTER (await resumed?)", "log.join(',')");

  printf("\n-- calling the SAME context from a second thread --\n");
  return NULL;
}

static void* second(void* arg) {
  (void)arg;
  JSGlobalContextRef ctx = g_ctx;
  run(ctx, "  2nd thread, same ctx", "globalThis.fromSecond = 42; 'wrote from another thread'");
  return NULL;
}

int main(void) {
  g_group = JSContextGroupCreate();
  g_ctx = JSGlobalContextCreateInGroup(g_group, NULL);
  printf("JSGlobalContextIsInspectable default = %s\n", JSGlobalContextIsInspectable(g_ctx) ? "true" : "false");
  pthread_t t; pthread_create(&t, NULL, worker, NULL); pthread_join(t, NULL);
  pthread_t t2; pthread_create(&t2, NULL, second, NULL); pthread_join(t2, NULL);
  run(g_ctx, "back on MAIN thread", "globalThis.fromSecond + ' / ' + log.join(',')");
  JSGlobalContextRelease(g_ctx);
  JSContextGroupRelease(g_group);
  return 0;
}
