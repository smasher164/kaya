#include <stdio.h>
#include <string.h>
#include <unicode/unum.h>
#include <unicode/ustring.h>
static void fmt(const char*loc,double v,int frac){
  UErrorCode e=U_ZERO_ERROR; UNumberFormat*f=unum_open(UNUM_DECIMAL,NULL,0,loc,NULL,&e);
  unum_setAttribute(f,UNUM_GROUPING_USED,0); if(frac>=0){unum_setAttribute(f,UNUM_MIN_FRACTION_DIGITS,frac);unum_setAttribute(f,UNUM_MAX_FRACTION_DIGITS,frac);}
  UChar u[64]; unum_formatDouble(f,v,u,64,NULL,&e); char o[128]; u_strToUTF8(o,128,NULL,u,-1,&e);
  UChar g[64]; unum_open; 
  printf("%s fmt %g -> [%s] %s\n",loc,v,o,u_errorName(e)); unum_close(f);}
static void grp(const char*loc){UErrorCode e=U_ZERO_ERROR; UNumberFormat*f=unum_open(UNUM_DECIMAL,NULL,0,loc,NULL,&e);
  UChar u[64]; unum_formatDouble(f,1234567.891,u,64,NULL,&e); char o[128]; u_strToUTF8(o,128,NULL,u,-1,&e); printf("%s grouped -> [%s]\n",loc,o); unum_close(f);}
static void parse(const char*loc,const char*t){
  UErrorCode e=U_ZERO_ERROR; UNumberFormat*f=unum_open(UNUM_DECIMAL,NULL,0,loc,NULL,&e);
  unum_setAttribute(f,UNUM_GROUPING_USED,0);
  UChar u[64]; int32_t n; u_strFromUTF8(u,64,&n,t,-1,&e); int32_t pos=0; double v=unum_parseDouble(f,u,n,&pos,&e);
  printf("%s parse [%s] -> %g pos %d/%d %s\n",loc,t,v,pos,n,u_errorName(e)); unum_close(f);}
int main(){
  const char*locs[]={"ar_EG","ar-EG","en_US","de_DE"};
  for(int i=0;i<4;i++){fmt(locs[i],3.5,1);fmt(locs[i],-40,0);fmt(locs[i],1234.25,2);grp(locs[i]);}
  const char*texts[]={"3.5","٣٫٥","3٫5","٣.٥","٣,٥","3,5","-٤٠","−٤٠","؜-٤٠","-40","١٢٣٤٫٢٥","1234.25","۳٫۵","١٬٢٣٤٫٥","12.5abc"};
  for(int i=0;i<15;i++) parse("ar_EG",texts[i]);
  const char*t2[]={"3.5","3,5","٣٫٥","٣,٥","12.5"};
  for(int i=0;i<5;i++){parse("de_DE",t2[i]);parse("en_US",t2[i]);}
}
