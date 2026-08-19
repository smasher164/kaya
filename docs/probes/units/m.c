#include <stdio.h>
#include <string.h>
int main(void) {
    const char *s1 = "ab😀cd"; const char *s2 = "ab👨‍👩‍👧‍👦cd";
    printf("LANG c\n");
    printf("natural_len_S1 %zu\n", strlen(s1));
    printf("natural_len_S2 %zu\n", strlen(s2));
    printf("natural_index_cd_S2 %ld\n", (long)(strstr(s2, "cd") - s2));
    printf("split_codepoint_S1 bytes=");
    for (int i = 0; i < 3; i++) printf("%02x ", (unsigned char)s1[i]);
    printf("\nstdlib_graphemes NONE\n");
    return 0;
}
