#include <glib.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
/* copy of gtk_spin_button_default_input (gtk main, gtkspinbutton.c) */
static int spin_input(const char *text, double *v){
  char *err=NULL; *v=g_strtod(text,&err);
  if(*err){ gint64 val=0; int sign=1; const char*p;
    for(p=text;*p;p=g_utf8_next_char(p)){ gunichar ch=g_utf8_get_char(p);
      if(p==text&&ch=='-'){sign=-1;continue;}
      if(!g_unichar_isdigit(ch))break; val=val*10+g_unichar_digit_value(ch);}
    if(*p) return 1; *v=sign*val;}
  return 0;}
int main(void){
  const char*locs[]={"en_US.UTF-8","de_DE.UTF-8","ar_EG.UTF-8"};
  const char*in[]={"3.5","3,5","1234","1.234","1,234","1.234,5","1,234.5","٣٫٥","٣٤","١٬٢٣٤","3٫5","1 234"};
  for(int l=0;l<3;l++){ if(!setlocale(LC_ALL,locs[l])){printf("%s: NO LOCALE\n",locs[l]);continue;}
    printf("== %s decimal_point='%s' thousands_sep='%s'\n",locs[l],localeconv()->decimal_point,localeconv()->thousands_sep);
    for(unsigned i=0;i<sizeof in/sizeof*in;i++){ char*e; double s=strtod(in[i],&e); double v; int r=spin_input(in[i],&v);
      printf("  %-14s strtod=%g rest='%s' | spin=%s %g\n",in[i],s,e,r?"ERROR":"ok",r?0:v);} }
}
