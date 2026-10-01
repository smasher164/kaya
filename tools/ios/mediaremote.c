/* session_send on the simulator (docs/media-plan.md §5; measured in
 * docs/media-plan.md §6): MediaRemote's command, sent from a process the
 * host starts inside the simulator with `simctl spawn`, reaches the Now
 * Playing app's MPRemoteCommandCenter the way Control Center's does. The
 * simulator answers no Now Playing read to this unentitled process, so the
 * guest proves the command arrived by its own handler counter.
 *
 *   mediaremote <MRCommand>
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef Boolean (*Send)(int, CFDictionaryRef);

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "mediaremote: usage: mediaremote <MRCommand>\n");
        return 2;
    }
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                      RTLD_NOW);
    if (!mr) {
        fprintf(stderr, "mediaremote: dlopen failed: %s\n", dlerror());
        return 1;
    }
    Send send = (Send)dlsym(mr, "MRMediaRemoteSendCommand");
    if (!send) {
        fprintf(stderr, "mediaremote: MediaRemote exports no MRMediaRemoteSendCommand\n");
        return 1;
    }
    int command = atoi(argv[1]);
    Boolean ok = send(command, NULL);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    printf("mediaremote: sent command %d, MediaRemote answered %d\n", command, (int)ok);
    return ok ? 0 : 1;
}
