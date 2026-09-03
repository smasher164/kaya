/* The Android python-host shim (docs/python-mobile-plan.md §D4): one JNI
 * entry running CPython to completion on the CALLING thread, so the UI
 * thread stays the host's. Signal handlers off. */
#include <Python.h>
#include <jni.h>
#include <stdio.h>
#include <string.h>

static int run_python(const char *home, const char *appdir) {
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    pre.configure_locale = 1;
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) {
        printf("pyhost: preinit failed: %s\n", st.err_msg ? st.err_msg : "?");
        return 1;
    }
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    PyConfig_SetBytesString(&config, &config.home, home);
    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) {
        printf("pyhost: init failed: %s\n", st.err_msg ? st.err_msg : "?");
        return 1;
    }
    char code[4096];
    snprintf(code, sizeof code,
             "import sys\n"
             "sys.path.insert(0, '%s')\n"
             "import runpy\n"
             "runpy.run_path('%s/main.py', run_name='__main__')\n",
             appdir, appdir);
    int rc = PyRun_SimpleString(code);
    if (rc != 0) {
        /* The traceback went to logcat's python.stderr tag; this line
         * rides the kaya tag path the lane's failure dump reads. */
        printf("pyhost: the guest raised; python.stderr has the traceback\n");
    }
    Py_FinalizeEx();
    return rc;
}

JNIEXPORT jint JNICALL
Java_dev_kaya_KayaPy_run(JNIEnv *env, jclass cls, jstring jhome, jstring japp) {
    (void)cls;
    const char *home = (*env)->GetStringUTFChars(env, jhome, NULL);
    const char *app = (*env)->GetStringUTFChars(env, japp, NULL);
    int rc = run_python(home, app);
    (*env)->ReleaseStringUTFChars(env, jhome, home);
    (*env)->ReleaseStringUTFChars(env, japp, app);
    return rc;
}
