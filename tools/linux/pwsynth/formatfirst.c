/*
 * LD_PRELOADed into every far-end leg's guest by tools/linux/capture-leg.py:
 * a media.role=Phone stream that has reached PAUSED reads CONNECTING, so the
 * session manager's Format always arrives before the app sees PAUSED. That is
 * the ordering pipewiresink's setcaps deadlocks on (docs/traps.md, the linux
 * voice the graph never pulled), held on every run instead of once a month.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

#include <pipewire/pipewire.h>

enum pw_stream_state pw_stream_get_state(struct pw_stream *stream, const char **error)
{
    static enum pw_stream_state (*real)(struct pw_stream *, const char **);
    if (real == NULL)
        real = (enum pw_stream_state (*)(struct pw_stream *, const char **))dlsym(RTLD_NEXT, "pw_stream_get_state");
    enum pw_stream_state state = real(stream, error);
    if (state != PW_STREAM_STATE_PAUSED)
        return state;
    const struct pw_properties *props = pw_stream_get_properties(stream);
    const char *role = props ? pw_properties_get(props, PW_KEY_MEDIA_ROLE) : NULL;
    return role && strcmp(role, "Phone") == 0 ? PW_STREAM_STATE_CONNECTING : state;
}
