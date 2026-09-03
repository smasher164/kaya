// A VIRTUAL POINTER FOR THE HEADLESS WAYLAND SESSIONS, wtype's twin.
// The lane's sway has no input devices, so its seat advertises no
// pointer and sway's own `seat - cursor press` returns success while
// delivering NOTHING (docs/traps.md, measured 2026-09-02). A drag is a
// grab on a real button press, so this adds a zwlr_virtual_pointer_v1
// device for the life of the process — the seat is deviceless again the
// moment it exits, which is the rule the pool runs under.
//
//   wlpointer set X Y | move DX DY | press BTN | release BTN
//             | click BTN | sleep MS ...           (BTN: left right middle)
//
// Coordinates are output pixels; every command is followed by a frame
// and a roundtrip. Built by run-suites.sh, proven every lane run by
// tools/linux/dragprobe.py before the first leg.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct wl_output *output;
static struct zwlr_virtual_pointer_manager_v1 *manager;
static int32_t out_w, out_h;

static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                            int32_t pw, int32_t ph, int32_t sub, const char *make,
                            const char *model, int32_t tr) {
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sub; (void)make;
    (void)model; (void)tr;
}
static void output_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w,
                        int32_t h, int32_t r) {
    (void)d; (void)o; (void)r;
    if (flags & WL_OUTPUT_MODE_CURRENT) { out_w = w; out_h = h; }
}
static void output_done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void output_scale(void *d, struct wl_output *o, int32_t f) { (void)d; (void)o; (void)f; }
static void output_name(void *d, struct wl_output *o, const char *n) { (void)d; (void)o; (void)n; }
static void output_desc(void *d, struct wl_output *o, const char *n) { (void)d; (void)o; (void)n; }
static const struct wl_output_listener output_listener = {
    output_geometry, output_mode, output_done, output_scale, output_name, output_desc,
};

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface,
                   uint32_t ver) {
    (void)d; (void)ver;
    if (!strcmp(iface, wl_seat_interface.name) && !seat) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    } else if (!strcmp(iface, wl_output_interface.name) && !output) {
        output = wl_registry_bind(r, name, &wl_output_interface, 4);
        wl_output_add_listener(output, &output_listener, NULL);
    } else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) {
        manager = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 2);
    }
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {
    (void)d; (void)r; (void)name;
}
static const struct wl_registry_listener registry_listener = { global, global_remove };

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int button_code(const char *s, uint32_t *code) {
    if (!strcmp(s, "left")) { *code = 0x110; return 1; }
    if (!strcmp(s, "right")) { *code = 0x111; return 1; }
    if (!strcmp(s, "middle")) { *code = 0x112; return 1; }
    return 0;
}

static int usage(const char *why) {
    fprintf(stderr, "wlpointer: %s\n  usage: wlpointer (set X Y | move DX DY | press BTN | "
            "release BTN | click BTN | sleep MS)...\n", why);
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage("no commands");
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "wlpointer: no wayland display (WAYLAND_DISPLAY=%s, XDG_RUNTIME_DIR=%s)\n",
                getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "unset",
                getenv("XDG_RUNTIME_DIR") ? getenv("XDG_RUNTIME_DIR") : "unset");
        return 2;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);
    if (!seat || !output || !manager || !out_w || !out_h) {
        fprintf(stderr, "wlpointer: the compositor offers seat=%s output=%s "
                "zwlr_virtual_pointer_manager_v1=%s mode=%dx%d; every one is needed\n",
                seat ? "yes" : "NO", output ? "yes" : "NO", manager ? "yes" : "NO", out_w, out_h);
        return 2;
    }
    struct zwlr_virtual_pointer_v1 *ptr =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(manager, seat, output);
    wl_display_roundtrip(display);

    int i = 1;
    while (i < argc) {
        const char *cmd = argv[i];
        uint32_t code;
        if (!strcmp(cmd, "set") && i + 2 < argc) {
            uint32_t x = (uint32_t)strtoul(argv[i + 1], NULL, 10);
            uint32_t y = (uint32_t)strtoul(argv[i + 2], NULL, 10);
            zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), x, y, (uint32_t)out_w,
                                                    (uint32_t)out_h);
            zwlr_virtual_pointer_v1_frame(ptr);
            i += 3;
        } else if (!strcmp(cmd, "move") && i + 2 < argc) {
            zwlr_virtual_pointer_v1_motion(ptr, now_ms(), wl_fixed_from_int(atoi(argv[i + 1])),
                                           wl_fixed_from_int(atoi(argv[i + 2])));
            zwlr_virtual_pointer_v1_frame(ptr);
            i += 3;
        } else if ((!strcmp(cmd, "press") || !strcmp(cmd, "release") || !strcmp(cmd, "click"))
                   && i + 1 < argc) {
            if (!button_code(argv[i + 1], &code)) return usage("unknown button");
            if (strcmp(cmd, "release") != 0) {
                zwlr_virtual_pointer_v1_button(ptr, now_ms(), code, WL_POINTER_BUTTON_STATE_PRESSED);
                zwlr_virtual_pointer_v1_frame(ptr);
            }
            if (!strcmp(cmd, "click")) {
                wl_display_roundtrip(display);
                usleep(50000);
            }
            if (strcmp(cmd, "press") != 0) {
                zwlr_virtual_pointer_v1_button(ptr, now_ms(), code, WL_POINTER_BUTTON_STATE_RELEASED);
                zwlr_virtual_pointer_v1_frame(ptr);
            }
            i += 2;
        } else if (!strcmp(cmd, "sleep") && i + 1 < argc) {
            wl_display_roundtrip(display);
            usleep((useconds_t)atoi(argv[i + 1]) * 1000);
            i += 2;
        } else {
            return usage(cmd);
        }
        wl_display_roundtrip(display);
    }
    zwlr_virtual_pointer_v1_destroy(ptr);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
