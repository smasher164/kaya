/* The main executable of every python, java, C# and JS kaya app on the Mac,
 * one binary per runtime (tools/lib/lanes/mac.py build_hosts; docs/traps.md,
 * SwiftUI resolves its design generation from the MAIN EXECUTABLE's SDK stamp). */
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((used)) static const char kaya_build_id[] = "kaya-build-id:" KAYA_BUILD_ID;

#if defined(KAYA_HOST_PYTHON)

extern int Py_BytesMain(int argc, char **argv);

int main(int argc, char **argv) { return Py_BytesMain(argc, argv); }

#elif defined(KAYA_HOST_JAVA)

extern int JLI_Launch(int argc, char **argv, int jargc, const char **jargv,
                      int appclassc, const char **appclassv,
                      const char *fullversion, const char *dotversion,
                      const char *pname, const char *lname,
                      unsigned char javaargs, unsigned char cpwildcard,
                      unsigned char javaw, int ergo);

int main(int argc, char **argv) {
    return JLI_Launch(argc, argv, 0, NULL, 0, NULL, KAYA_JAVA_VERSION,
                      KAYA_JAVA_VERSION, "java", "openjdk", 0, 1, 0, 0);
}

#elif defined(KAYA_HOST_DOTNET)

struct get_hostfxr_parameters {
    size_t size;
    const char *assembly_path;
    const char *dotnet_root;
};
extern int get_hostfxr_path(char *buffer, size_t *buffer_size,
                            const struct get_hostfxr_parameters *parameters);

struct hostfxr_initialize_parameters {
    size_t size;
    const char *host_path;
    const char *dotnet_root;
};
typedef int32_t (*hostfxr_init_fn)(int argc, const char **argv,
                                   const struct hostfxr_initialize_parameters *parameters,
                                   void **handle);
typedef int32_t (*hostfxr_run_fn)(void *handle);
typedef int32_t (*hostfxr_close_fn)(void *handle);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "kaya-dotnet: usage: kaya-dotnet <app.dll> [args...]\n");
        return 2;
    }
    struct get_hostfxr_parameters where = {sizeof where, NULL, KAYA_DOTNET_ROOT};
    char fxr[PATH_MAX];
    size_t len = sizeof fxr;
    int rc = get_hostfxr_path(fxr, &len, &where);
    if (rc != 0) {
        fprintf(stderr, "kaya-dotnet: nethost found no hostfxr under %s (0x%x)\n",
                KAYA_DOTNET_ROOT, (unsigned)rc);
        return 2;
    }
    void *lib = dlopen(fxr, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "kaya-dotnet: dlopen %s: %s\n", fxr, dlerror());
        return 2;
    }
    hostfxr_init_fn init = (hostfxr_init_fn)dlsym(lib, "hostfxr_initialize_for_dotnet_command_line");
    hostfxr_run_fn run = (hostfxr_run_fn)dlsym(lib, "hostfxr_run_app");
    hostfxr_close_fn close_fn = (hostfxr_close_fn)dlsym(lib, "hostfxr_close");
    if (!init || !run || !close_fn) {
        fprintf(stderr, "kaya-dotnet: %s lacks the hosting entry points\n", fxr);
        return 2;
    }
    char self[PATH_MAX];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) {
        fprintf(stderr, "kaya-dotnet: _NSGetExecutablePath needs %u bytes\n", size);
        return 2;
    }
    struct hostfxr_initialize_parameters params = {sizeof params, self, KAYA_DOTNET_ROOT};
    void *handle = NULL;
    rc = init(argc - 1, (const char **)(argv + 1), &params, &handle);
    if (rc != 0 || !handle) {
        fprintf(stderr, "kaya-dotnet: hostfxr_initialize_for_dotnet_command_line(%s) failed (0x%x)\n",
                argv[1], (unsigned)rc);
        if (handle) close_fn(handle);
        return 2;
    }
    rc = run(handle);
    close_fn(handle);
    return rc;
}

#elif defined(KAYA_HOST_NODE)

typedef int (*node_start_fn)(int argc, char **argv);

int main(int argc, char **argv) {
    void *node = dlopen(KAYA_NODE_PATH, RTLD_NOW | RTLD_GLOBAL);
    if (!node) {
        fprintf(stderr, "kaya-node: dlopen %s: %s\n", KAYA_NODE_PATH, dlerror());
        return 2;
    }
    node_start_fn start = (node_start_fn)dlsym(node, "_ZN4node5StartEiPPc");
    if (!start) {
        fprintf(stderr, "kaya-node: %s exports no node::Start(int, char**)\n", KAYA_NODE_PATH);
        return 2;
    }
    return start(argc, argv);
}

#else
#error "kaya-host: define KAYA_HOST_PYTHON, KAYA_HOST_JAVA, KAYA_HOST_DOTNET or KAYA_HOST_NODE"
#endif
