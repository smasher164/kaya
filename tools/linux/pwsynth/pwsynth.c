/*
 * The linux lane's synthetic capture devices (docs/capture-plan.md §7):
 *
 *     pwsynth camera <node.name> <description> <RRGGBB>
 *     pwsynth microphone <node.name> <description> <hz>
 *
 * A PipeWire node a real camera's or microphone's consumer finds by its
 * node.name: a camera is a Video/Source with media.role=Camera (what the
 * camera portal counts) offering NV12 at 640x480 and 1280x720, each at 15
 * and 30 fps, video-range BT.601 frames of one flat colour; a microphone
 * is an Audio/Source of F32 stereo at 48 kHz, one sine on both channels.
 * Not gst-launch's pipewiresink: its provide mode offers one format and
 * exits when its consumer unlinks (docs/probes/capture-2026-10-01/
 * linux-measured.md).
 */
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <spa/param/audio/format-utils.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/buffers.h>
#include <spa/pod/builder.h>
#include <pipewire/pipewire.h>

struct synth {
    struct pw_main_loop *loop;
    struct pw_stream *stream;
    struct spa_source *timer;
    int camera;
    uint8_t y, u, v;
    uint32_t width, height, fps;
    double hz, phase;
};

static const uint32_t SIZES[][2] = {{640, 480}, {1280, 720}};
static const uint32_t RATES[] = {15, 30};

static void video_process(void *userdata) {
    struct synth *s = userdata;
    struct pw_buffer *b = pw_stream_dequeue_buffer(s->stream);
    if (b == NULL) {
        return;
    }
    struct spa_data *d = &b->buffer->datas[0];
    uint8_t *p = d->data;
    uint32_t stride = s->width;
    uint32_t luma = stride * s->height;
    uint32_t size = luma + luma / 2;
    if (p != NULL && d->maxsize >= size) {
        memset(p, s->y, luma);
        for (uint32_t i = luma; i < size; i += 2) {
            p[i] = s->u;
            p[i + 1] = s->v;
        }
        d->chunk->offset = 0;
        d->chunk->size = size;
        d->chunk->stride = (int32_t)stride;
    }
    pw_stream_queue_buffer(s->stream, b);
}

static void audio_process(void *userdata) {
    struct synth *s = userdata;
    struct pw_buffer *b = pw_stream_dequeue_buffer(s->stream);
    if (b == NULL) {
        return;
    }
    struct spa_data *d = &b->buffer->datas[0];
    float *dst = d->data;
    if (dst != NULL) {
        uint32_t frame = 2 * sizeof(float);
        uint32_t n = d->maxsize / frame;
        if (b->requested != 0 && b->requested < n) {
            n = (uint32_t)b->requested;
        }
        for (uint32_t i = 0; i < n; i++) {
            float x = (float)(sin(s->phase) * 0.5);
            dst[2 * i] = x;
            dst[2 * i + 1] = x;
            s->phase += 2.0 * M_PI * s->hz / 48000.0;
            if (s->phase > 2.0 * M_PI) {
                s->phase -= 2.0 * M_PI;
            }
        }
        d->chunk->offset = 0;
        d->chunk->stride = (int32_t)frame;
        d->chunk->size = n * frame;
    }
    pw_stream_queue_buffer(s->stream, b);
}

static void on_timeout(void *userdata, uint64_t expirations) {
    (void)expirations;
    struct synth *s = userdata;
    pw_stream_trigger_process(s->stream);
}

static void arm(struct synth *s, int on) {
    struct timespec value = {0, 0}, interval = {0, 0};
    if (on) {
        value.tv_nsec = 1;
        interval.tv_nsec = 1000000000L / s->fps;
    }
    pw_loop_update_timer(pw_main_loop_get_loop(s->loop), s->timer, &value, &interval, false);
}

static void on_state_changed(void *userdata, enum pw_stream_state old, enum pw_stream_state state,
                             const char *error) {
    (void)old;
    struct synth *s = userdata;
    fprintf(stderr, "pwsynth: stream %s%s%s\n", pw_stream_state_as_string(state), error ? ": " : "",
            error ? error : "");
    if (s->camera) {
        arm(s, state == PW_STREAM_STATE_STREAMING);
    }
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
    struct synth *s = userdata;
    if (param == NULL || id != SPA_PARAM_Format || !s->camera) {
        return;
    }
    struct spa_video_info_raw info;
    spa_zero(info);
    if (spa_format_video_raw_parse(param, &info) < 0) {
        return;
    }
    s->width = info.size.width;
    s->height = info.size.height;
    s->fps = info.framerate.denom ? info.framerate.num / info.framerate.denom : 30;
    if (s->fps == 0) {
        s->fps = 30;
    }
    fprintf(stderr, "pwsynth: negotiated %ux%u@%u\n", s->width, s->height, s->fps);
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    uint32_t size = s->width * s->height * 3 / 2;
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 2, 16),
        SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_size, SPA_POD_Int((int32_t)size),
        SPA_PARAM_BUFFERS_stride, SPA_POD_Int((int32_t)s->width),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    pw_stream_update_params(s->stream, params, 1);
}

static const struct pw_stream_events video_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = video_process,
};

static const struct pw_stream_events audio_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .process = audio_process,
};

static void quit(void *userdata, int signal_number) {
    (void)signal_number;
    struct synth *s = userdata;
    pw_main_loop_quit(s->loop);
}

int main(int argc, char *argv[]) {
    if (argc != 5 || (strcmp(argv[1], "camera") != 0 && strcmp(argv[1], "microphone") != 0)) {
        fprintf(stderr, "usage: %s camera <node.name> <description> <RRGGBB> | microphone <node.name> <description> <hz>\n",
                argv[0]);
        return 2;
    }
    struct synth s;
    spa_zero(s);
    s.camera = strcmp(argv[1], "camera") == 0;
    char *end = NULL;
    unsigned long content = strtoul(argv[4], &end, s.camera ? 16 : 10);
    if (end == argv[4] || *end != '\0') {
        fprintf(stderr, "pwsynth: %s is not a %s\n", argv[4], s.camera ? "RRGGBB colour" : "frequency in Hz");
        return 2;
    }
    if (s.camera) {
        double r = (double)((content >> 16) & 0xff), g = (double)((content >> 8) & 0xff), bl = (double)(content & 0xff);
        s.y = (uint8_t)lround(16 + 0.257 * r + 0.504 * g + 0.098 * bl);
        s.u = (uint8_t)lround(128 - 0.148 * r - 0.291 * g + 0.439 * bl);
        s.v = (uint8_t)lround(128 + 0.439 * r - 0.368 * g - 0.071 * bl);
        s.width = 640;
        s.height = 480;
        s.fps = 30;
    } else {
        s.hz = (double)content;
    }

    pw_init(&argc, &argv);
    s.loop = pw_main_loop_new(NULL);
    if (s.loop == NULL) {
        fprintf(stderr, "pwsynth: no main loop\n");
        return 1;
    }
    struct pw_loop *loop = pw_main_loop_get_loop(s.loop);
    pw_loop_add_signal(loop, SIGINT, quit, &s);
    pw_loop_add_signal(loop, SIGTERM, quit, &s);

    struct pw_properties *props = pw_properties_new(
        PW_KEY_NODE_NAME, argv[2],
        PW_KEY_NODE_DESCRIPTION, argv[3],
        PW_KEY_MEDIA_TYPE, s.camera ? "Video" : "Audio",
        PW_KEY_MEDIA_CLASS, s.camera ? "Video/Source" : "Audio/Source",
        NULL);
    if (s.camera) {
        pw_properties_set(props, PW_KEY_MEDIA_ROLE, "Camera");
    }
    s.stream = pw_stream_new_simple(loop, argv[2], props, s.camera ? &video_events : &audio_events, &s);
    if (s.stream == NULL) {
        fprintf(stderr, "pwsynth: pw_stream_new_simple failed: %s\n", strerror(errno));
        return 1;
    }

    uint8_t buffer[4096];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[4];
    uint32_t n = 0;
    enum pw_stream_flags flags = PW_STREAM_FLAG_MAP_BUFFERS;
    if (s.camera) {
        for (size_t i = 0; i < SPA_N_ELEMENTS(SIZES); i++) {
            for (size_t j = 0; j < SPA_N_ELEMENTS(RATES); j++) {
                params[n++] = spa_pod_builder_add_object(
                    &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
                    SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
                    SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
                    SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_NV12),
                    SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(SIZES[i][0], SIZES[i][1])),
                    SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(RATES[j], 1)),
                    SPA_FORMAT_VIDEO_colorRange, SPA_POD_Id(SPA_VIDEO_COLOR_RANGE_16_235),
                    SPA_FORMAT_VIDEO_colorMatrix, SPA_POD_Id(SPA_VIDEO_COLOR_MATRIX_BT601));
            }
        }
        flags |= PW_STREAM_FLAG_DRIVER;
        s.timer = pw_loop_add_timer(loop, on_timeout, &s);
    } else {
        struct spa_audio_info_raw info;
        spa_zero(info);
        info.format = SPA_AUDIO_FORMAT_F32;
        info.channels = 2;
        info.rate = 48000;
        info.position[0] = SPA_AUDIO_CHANNEL_FL;
        info.position[1] = SPA_AUDIO_CHANNEL_FR;
        params[n++] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);
    }
    int res = pw_stream_connect(s.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, flags, params, n);
    if (res < 0) {
        fprintf(stderr, "pwsynth: pw_stream_connect: %s\n", strerror(-res));
        return 1;
    }
    if (s.camera) {
        fprintf(stderr, "pwsynth: camera %s offered, colour %06lX (Y %u, U %u, V %u), NV12 640x480 and 1280x720 at 15 and 30\n",
                argv[2], content, (unsigned)s.y, (unsigned)s.u, (unsigned)s.v);
    } else {
        fprintf(stderr, "pwsynth: microphone %s offered, %lu Hz on both channels, F32 stereo at 48000\n", argv[2], content);
    }
    pw_main_loop_run(s.loop);
    pw_stream_destroy(s.stream);
    pw_main_loop_destroy(s.loop);
    pw_deinit();
    return 0;
}
