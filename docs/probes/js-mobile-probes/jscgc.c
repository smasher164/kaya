#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdio.h>
#include <mach/mach.h>
static JSGlobalContextRef g_ctx;
static size_t rss(void){ struct mach_task_basic_info i; mach_msg_type_number_t c=MACH_TASK_BASIC_INFO_COUNT;
  if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&i,&c)!=KERN_SUCCESS) return 0; return i.resident_size; }
static void ev(const char* s){ JSStringRef j=JSStringCreateWithUTF8CString(s); JSValueRef e=NULL;
  JSEvaluateScript(g_ctx,j,NULL,NULL,1,&e); JSStringRelease(j);
  if(e){ JSStringRef m=JSValueToStringCopy(g_ctx,e,NULL); char b[300]; JSStringGetUTF8CString(m,b,sizeof b); printf("  THREW %s\n",b);} }
static void* worker(void* a){ (void)a;
  printf("  thread has a CFRunLoop object but it is NOT running (no CFRunLoopRun call)\n");
  size_t before = rss();
  for (int round=0; round<20; round++)
    ev("{ let keep=null; for(let i=0;i<200000;i++){ keep={a:i,b:'s'+i,c:[i,i,i]}; } keep.a; }");
  size_t after = rss();
  printf("  RSS before=%.1f MB  after 4,000,000 short-lived objects=%.1f MB  delta=%+.1f MB\n",
         before/1048576.0, after/1048576.0, (double)(after-before)/1048576.0);
  printf("  => %s\n", (after-before) < 200u*1048576u
    ? "collected: GC runs on the allocating thread without a running run loop"
    : "NOT collected: memory grew unbounded without a run loop");
  return NULL; }
int main(void){
  g_ctx = JSGlobalContextCreate(NULL);
  printf("JSContextGroup binds deferred tasks to the run loop of the CREATING thread\n");
  printf("(JSContextRef.h: \"there is no API to change a JSContextGroup's run loop once it has been created\")\n");
  pthread_t t; pthread_create(&t,NULL,worker,NULL); pthread_join(t,NULL);
  return 0; }
