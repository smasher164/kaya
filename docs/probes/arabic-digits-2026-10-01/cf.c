#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
static void p(CFLocaleRef l,const char*tag,const char*t){
  CFNumberFormatterRef f=CFNumberFormatterCreate(NULL,l,kCFNumberFormatterDecimalStyle);
  CFNumberFormatterSetProperty(f,kCFNumberFormatterUseGroupingSeparator,kCFBooleanFalse);
  CFStringRef s=CFStringCreateWithCString(NULL,t,kCFStringEncodingUTF8); CFIndex n=CFStringGetLength(s);
  CFRange r={0,n}; double v=0; Boolean ok=CFNumberFormatterGetValueFromString(f,s,&r,kCFNumberDoubleType,&v);
  printf("%s parse [%s] -> ok=%d %g range %ld/%ld => %s\n",tag,t,ok,v,(long)r.length,(long)n,(ok&&r.location==0&&r.length==n)?"READ":"refused");}
static void w(CFLocaleRef l,const char*tag,double v){CFNumberFormatterRef f=CFNumberFormatterCreate(NULL,l,kCFNumberFormatterDecimalStyle);
  CFStringRef s=CFNumberFormatterCreateStringWithValue(NULL,f,kCFNumberDoubleType,&v);char b[128];CFStringGetCString(s,b,128,kCFStringEncodingUTF8);printf("%s write %g -> [%s]\n",tag,v,b);}
int main(){const char*tags[]={"ar-EG","ar_EG","de-DE","en-US"};
 const char*texts[]={"3.5","٣٫٥","3٫5","٣.٥","3,5","٣,٥","-40","-٤٠","؜-٤٠","1234.25","١٢٣٤٫٢٥"};
 for(int i=0;i<4;i++){CFStringRef id=CFStringCreateWithCString(NULL,tags[i],kCFStringEncodingUTF8);CFLocaleRef l=CFLocaleCreate(NULL,id);
  w(l,tags[i],3.5);w(l,tags[i],-40);w(l,tags[i],1234567.891);for(int j=0;j<11;j++)p(l,tags[i],texts[j]);}}
