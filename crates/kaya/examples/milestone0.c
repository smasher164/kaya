/* Milestone 0 from C over the C ABI (function floor): the ABI's home
 * language validated the same way as every other guest. The main thread
 * enters kaya_run() and becomes the core's UI thread; a pthread is the
 * app thread, draining occurrences and sending commands.
 *
 * Built and run by the Linux container suite (tools/linux/run-suites.sh),
 * where a plain cc and the shared library are both at hand. */

#include <kaya.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

static void *app(void *arg) {
    (void)arg;
    uint64_t count = 0;
    KayaOccurrence occurrence;
    while (kaya_next_occurrence(&occurrence)) {
        if (occurrence.kind == KAYA_OCCURRENCE_BUTTON_CLICKED) {
            char text[64];
            count += 1;
            snprintf(text, sizeof text, "Clicked %llu %s",
                     (unsigned long long)count, count == 1 ? "time" : "times");
            kaya_set_text(KAYA_WIDGET_LABEL, (const uint8_t *)text, strlen(text));
        }
    }
    return NULL;
}

int main(void) {
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
