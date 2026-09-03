#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static JSGlobalContextRef g_ctx;
static JSObjectRef g_handler;
static char* eval(const char* src){ JSStringRef s=JSStringCreateWithUTF8CString(src); JSValueRef e=NULL;
  JSValueRef r=JSEvaluateScript(g_ctx,s,NULL,NULL,1,&e); JSStringRelease(s);
  JSStringRef m=JSValueToStringCopy(g_ctx,e?e:r,NULL); size_t n=JSStringGetMaximumUTF8CStringSize(m);
  char* b=malloc(n+8); if(e){strcpy(b,"THREW: ");JSStringGetUTF8CString(m,b+7,n);} else JSStringGetUTF8CString(m,b,n);
  JSStringRelease(m); return b; }
static void show(const char* l, char* v){ printf("%-38s => %s\n", l, v); free(v); }

/* a native fn that BLOCKS (kaya's PickedFile.read / a slow submit) */
static JSValueRef blocking(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;(void)e; usleep(120000); return JSValueMakeUndefined(c); }
/* a native fn that throws */
static JSValueRef thrower(JSContextRef c, JSObjectRef f, JSObjectRef t, size_t n, const JSValueRef a[], JSValueRef* e)
{ (void)f;(void)t;(void)n;(void)a;
  JSStringRef m=JSStringCreateWithUTF8CString("kaya: refused by the native side");
  *e = JSValueMakeString(c,m); JSStringRelease(m); return JSValueMakeUndefined(c); }

static void def(const char* nm, JSObjectCallAsFunctionCallback cb){ JSStringRef s=JSStringCreateWithUTF8CString(nm);
  JSObjectSetProperty(g_ctx,JSContextGetGlobalObject(g_ctx),s,JSObjectMakeFunctionWithCallback(g_ctx,s,cb),0,NULL); JSStringRelease(s); }

static void* appThread(void* a){ (void)a; free(eval("order.push('app:enter'); blocking(); order.push('app:leave');")); return NULL; }
static void* pumpThread(void* a){ (void)a; usleep(30000); /* fire while the app thread is inside blocking() */
  JSValueRef e=NULL; JSObjectCallAsFunction(g_ctx,g_handler,NULL,0,NULL,&e); return NULL; }

int main(void){
  g_ctx=JSGlobalContextCreate(NULL);
  def("blocking", blocking); def("thrower", thrower);
  printf("== console ==\n");
  show("typeof console.log", eval("typeof console.log"));
  printf("  (next line, if any, is console.log's destination)\n");
  free(eval("console.log('KAYA-CONSOLE-PROBE')"));

  printf("\n== a native callback throwing ==\n");
  show("try{thrower()}catch(e)", eval("(()=>{try{thrower();return 'no throw';}catch(e){return 'caught: '+e;}})()"));

  printf("\n== REENTRANCY: pump enters JS while the app thread blocks in native ==\n");
  free(eval("globalThis.order=[]; globalThis.onOcc=()=>{ order.push('pump:handler'); };"));
  { JSValueRef e=NULL; JSStringRef k=JSStringCreateWithUTF8CString("onOcc");
    g_handler=JSValueToObject(g_ctx,JSObjectGetProperty(g_ctx,JSContextGetGlobalObject(g_ctx),k,&e),&e);
    JSStringRelease(k); JSValueProtect(g_ctx,g_handler); }
  pthread_t a,p; pthread_create(&a,NULL,appThread,NULL); pthread_create(&p,NULL,pumpThread,NULL);
  pthread_join(a,NULL); pthread_join(p,NULL);
  show("order", eval("order.join(' | ')"));
  printf("%-38s => %s\n","  verdict",
    "if pump:handler sits BETWEEN app:enter and app:leave, JS was re-entered mid-call");
  return 0; }
