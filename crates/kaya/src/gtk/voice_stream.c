/*
 * The GTK voice's PipeWire stream (gtk/voice.rs). Not pipewiresink, which
 * deadlocks when the Format arrives before PAUSED (docs/traps.md, the linux
 * voice the graph never pulled); nothing here may wait, under the loop's
 * lock or on the caller's thread. The far-end legs hold that ordering on
 * every run (tools/linux/pwsynth/formatfirst.c).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>
#include <pipewire/pipewire.h>

typedef void (*kaya_voice_pull)(void *user, float *out, uint32_t frames);
typedef void (*kaya_voice_failed)(void *user, const char *why);

struct kaya_voice {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    kaya_voice_pull pull;
    kaya_voice_failed failed;
    void *user;
    int reported;
};

static void on_process(void *data)
{
    struct kaya_voice *v = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(v->stream);
    if (b == NULL)
        return;
    struct spa_data *d = &b->buffer->datas[0];
    uint32_t frames = 0;
    if (d->data != NULL) {
        frames = d->maxsize / sizeof(float);
        if (b->requested != 0 && b->requested < frames)
            frames = (uint32_t)b->requested;
        v->pull(v->user, d->data, frames);
    }
    d->chunk->offset = 0;
    d->chunk->stride = sizeof(float);
    d->chunk->size = frames * sizeof(float);
    pw_stream_queue_buffer(v->stream, b);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
    struct kaya_voice *v = data;
    (void)old;
    if (state == PW_STREAM_STATE_ERROR && !v->reported) {
        v->reported = 1;
        v->failed(v->user, error ? error : "the stream reported an error with no message");
    }
}

static const struct pw_stream_events events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .process = on_process,
};

void voice_stream_free(struct kaya_voice *v)
{
    if (v == NULL)
        return;
    if (v->loop != NULL)
        pw_thread_loop_stop(v->loop);
    if (v->stream != NULL)
        pw_stream_destroy(v->stream);
    if (v->loop != NULL)
        pw_thread_loop_destroy(v->loop);
    free(v);
}

struct kaya_voice *voice_stream_new(const char *target, uint32_t rate, kaya_voice_pull pull, kaya_voice_failed failed,
                                  void *user, char *why, size_t why_len)
{
    pw_init(NULL, NULL);
    struct kaya_voice *v = calloc(1, sizeof(*v));
    if (v == NULL) {
        snprintf(why, why_len, "out of memory");
        return NULL;
    }
    v->pull = pull;
    v->failed = failed;
    v->user = user;
    v->loop = pw_thread_loop_new("kaya-voice", NULL);
    if (v->loop == NULL) {
        snprintf(why, why_len, "pw_thread_loop_new failed");
        voice_stream_free(v);
        return NULL;
    }
    struct pw_properties *props = pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
                                                    PW_KEY_MEDIA_ROLE, "Phone", NULL);
    if (target != NULL)
        pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);
    pw_properties_setf(props, PW_KEY_NODE_RATE, "1/%u", rate);
    uint8_t pod[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod, sizeof(pod));
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat,
                                           &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .rate = rate,
                                                                    .channels = 1, .position = {SPA_AUDIO_CHANNEL_MONO}));
    int res = pw_thread_loop_start(v->loop);
    if (res < 0) {
        pw_properties_free(props);
        snprintf(why, why_len, "pw_thread_loop_start: %s", spa_strerror(res));
        voice_stream_free(v);
        return NULL;
    }
    pw_thread_loop_lock(v->loop);
    v->stream = pw_stream_new_simple(pw_thread_loop_get_loop(v->loop), "kaya voice", props, &events, v);
    res = v->stream == NULL ? -errno
                            : pw_stream_connect(v->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    pw_thread_loop_unlock(v->loop);
    if (res < 0) {
        snprintf(why, why_len, "%s: %s", v->stream == NULL ? "pw_stream_new_simple" : "pw_stream_connect",
                 spa_strerror(res));
        voice_stream_free(v);
        return NULL;
    }
    return v;
}
