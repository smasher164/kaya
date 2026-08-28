/* The iOS python-host main (docs/python-mobile-plan.md §D4, hand-proof
 * draft): a C guest whose scene is built by an embedded CPython. The
 * process main thread enters kaya_run exactly as every iOS guest does;
 * CPython boots on a worker pthread with signal handlers off, imports
 * the bundled guest, and the guest's app.run() parks that thread as
 * the occurrence consumer (the binding's HOSTED_ENTRY arm). */
#include <Python.h>
#include <libgen.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int32_t kaya_run(void);

static char bundle_root[PATH_MAX];

static void *worker(void *arg) {
    (void)arg;
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    pre.configure_locale = 1;
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) {
        printf("pyhost: preinit failed: %s\n", st.err_msg ? st.err_msg : "?");
        return NULL;
    }
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    char home[PATH_MAX];
    snprintf(home, sizeof home, "%s/python", bundle_root);
    PyConfig_SetBytesString(&config, &config.home, home);
    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) {
        printf("pyhost: init failed: %s\n", st.err_msg ? st.err_msg : "?");
        return NULL;
    }
    char code[PATH_MAX * 2 + 256];
    snprintf(code, sizeof code,
             "import sys\n"
             "sys.path.insert(0, '%s/app')\n"
             "import runpy\n"
             "runpy.run_path('%s/app/main.py', run_name='__main__')\n",
             bundle_root, bundle_root);
    if (PyRun_SimpleString(code) != 0) {
        printf("pyhost: the guest raised; traceback above\n");
    }
    Py_FinalizeEx();
    return NULL;
}

int main(int argc, char **argv) {
    (void)argc;
    char exe[PATH_MAX];
    if (!realpath(argv[0], exe)) {
        printf("pyhost: realpath(argv[0]) failed\n");
        return 2;
    }
    snprintf(bundle_root, sizeof bundle_root, "%s", dirname(exe));
    setenv("LANG", "en_US.UTF-8", 0);
    pthread_t t;
    if (pthread_create(&t, NULL, worker, NULL) != 0) {
        printf("pyhost: pthread_create failed\n");
        return 2;
    }
    return (int)kaya_run();
}
