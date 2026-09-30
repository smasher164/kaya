/* The session_send helper (docs/media-plan.md §5; measured in
 * docs/probes/media-mac-2026-09-30.md): a remote command sent THROUGH THE
 * SYSTEM, as a media key would. MediaRemote drops a command from an
 * unentitled process while answering true, so this is loaded into Apple's
 * own /usr/bin/perl by the interpreter's session_send verb. It refuses unless
 * the system names the requesting guest as Now Playing: anything else would
 * drive the user's own player.
 *
 *   KAYA_MR_ACTION=send:<MRCommand>:<guest pid>   send, or refuse
 *   KAYA_MR_ACTION=pid                            print the Now Playing pid
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*GetPid)(dispatch_queue_t, void (^)(int));
typedef Boolean (*Send)(int, CFDictionaryRef);

static int now_playing_pid(GetPid get) {
    __block int got = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    get(dispatch_get_global_queue(0, 0), ^(int pid) {
        got = pid;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC)))
        return -2;
    return got;
}

void kaya_mediaremote_run(void *interp, void *cv) {
    (void)interp;
    (void)cv;
    const char *action = getenv("KAYA_MR_ACTION");
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                      RTLD_NOW);
    if (!mr) {
        fprintf(stderr, "mediaremote: dlopen failed: %s\n", dlerror());
        return;
    }
    GetPid get = (GetPid)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    Send send = (Send)dlsym(mr, "MRMediaRemoteSendCommand");
    if (!get || !send) {
        fprintf(stderr, "mediaremote: MediaRemote exports no %s\n",
                get ? "MRMediaRemoteSendCommand" : "MRMediaRemoteGetNowPlayingApplicationPID");
        return;
    }
    int pid = now_playing_pid(get);
    int command = -1, want = -1;
    if (!action || strcmp(action, "pid") == 0) {
        fprintf(stderr, "mediaremote: now playing pid %d\n", pid);
        return;
    }
    if (sscanf(action, "send:%d:%d", &command, &want) != 2 || want <= 0) {
        fprintf(stderr, "mediaremote: KAYA_MR_ACTION %s is not send:<command>:<pid>\n", action);
        return;
    }
    if (pid != want) {
        fprintf(stderr,
                "mediaremote: REFUSED command %d: the system's Now Playing is pid %d, not "
                "the guest %d (-2: no answer in 3 s)\n",
                command, pid, want);
        return;
    }
    Boolean ok = send(command, NULL);
    fprintf(stderr, "mediaremote: sent command %d to pid %d, MediaRemote answered %d\n", command,
            pid, (int)ok);
}
