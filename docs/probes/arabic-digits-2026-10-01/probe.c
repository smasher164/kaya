#include <stdio.h>
#include <locale.h>
#include <langinfo.h>
#include <time.h>
#include <monetary.h>
#include <wchar.h>
int main(int argc,char**argv){
  const char*l=argc>1?argv[1]:"ar_EG.UTF-8";
  if(!setlocale(LC_ALL,l)){printf("no locale %s\n",l);return 1;}
  struct lconv*c=localeconv();
  printf("locale=%s decimal=[%s] thousands=[%s] grouping0=%d\n",l,c->decimal_point,c->thousands_sep,c->grouping[0]);
  printf("mon_decimal=[%s] mon_thousands=[%s] int_curr=[%s] curr=[%s]\n",c->mon_decimal_point,c->mon_thousands_sep,c->int_curr_symbol,c->currency_symbol);
  printf("%%f: [%f] %%'f: [%'.3f] %%If: [%I.1f] %%Id: [%Id] %%'Id: [%'Id] neg %%I: [%I.1f]\n",3.5,1234567.891,3.5,1234567,1234567,-3.5);
  printf("RADIXCHAR=[%s] THOUSEP=[%s] CODESET=[%s]\n",nl_langinfo(RADIXCHAR),nl_langinfo(THOUSEP),nl_langinfo(CODESET));
  printf("ALT_DIGITS=[%s]\n",nl_langinfo(ALT_DIGITS));
  char buf[256]; struct tm tm={0}; tm.tm_year=126;tm.tm_mon=8;tm.tm_mday=7;tm.tm_hour=8;tm.tm_min=30;tm.tm_wday=1;
  strftime(buf,sizeof buf,"%x | %Od %Om %Ey | %e %B %Y",&tm); printf("strftime=[%s]\n",buf);
  strfmon(buf,sizeof buf,"%n",1234567.89); printf("strfmon=[%s]\n",buf);
  return 0;}
