#include <arpa/inet.h>
#include <errno.h>
#include <jni.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include "byedpi/error.h"
#include "main.h"

extern int server_fd;
static pthread_mutex_t proxy_mutex = PTHREAD_MUTEX_INITIALIZER;
static int proxy_started;
static int proxy_running;

int __wrap_daemon(__attribute__((unused)) int nochdir, __attribute__((unused)) int noclose) {
    LOG(LOG_S, "daemon mode is not supported in the native worker");
    errno = EPERM;
    return -1;
}

/*
 * AutoDPI: ByeDPI's name lookups go to DohResolver (DNS over HTTPS) instead of plain DNS.
 * Linked with -Wl,--wrap=getaddrinfo, so only calls inside this library are redirected.
 */
int __real_getaddrinfo(const char *node, const char *service,
        const struct addrinfo *hints, struct addrinfo **res);

static JavaVM *doh_vm;
static jclass doh_class;
static jmethodID doh_resolve;

static void doh_setup(JNIEnv *env) {
    if (doh_class) return;
    (*env)->GetJavaVM(env, &doh_vm);
    jclass local = (*env)->FindClass(env, "io/github/romanvht/byedpi/utility/DohResolver");
    if (!local) {
        (*env)->ExceptionClear(env);
        return;
    }
    doh_resolve = (*env)->GetStaticMethodID(env, local, "resolve", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!doh_resolve) {
        (*env)->ExceptionClear(env);
        return;
    }
    doh_class = (*env)->NewGlobalRef(env, local);
}

/* 1 = got an address in ip, 0 = name does not exist, -1 = encrypted DNS not available */
static int doh_lookup(const char *node, char *ip, size_t size) {
    if (!doh_class) return -1;
    JNIEnv *env;
    int attached = 0;
    if ((*doh_vm)->GetEnv(doh_vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*doh_vm)->AttachCurrentThread(doh_vm, &env, NULL) != JNI_OK) return -1;
        attached = 1;
    }
    int result = -1;
    jstring name = (*env)->NewStringUTF(env, node);
    jstring answer = name ? (jstring) (*env)->CallStaticObjectMethod(env, doh_class, doh_resolve, name) : NULL;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        answer = NULL;
    }
    if (answer) {
        const char *text = (*env)->GetStringUTFChars(env, answer, NULL);
        if (text) {
            result = text[0] ? 1 : 0;
            snprintf(ip, size, "%s", text);
            (*env)->ReleaseStringUTFChars(env, answer, text);
        }
        (*env)->DeleteLocalRef(env, answer);
    }
    if (name) (*env)->DeleteLocalRef(env, name);
    if (attached) (*doh_vm)->DetachCurrentThread(doh_vm);
    return result;
}

int __wrap_getaddrinfo(const char *node, const char *service,
        const struct addrinfo *hints, struct addrinfo **res) {
    struct in6_addr tmp;
    int numeric = !node || (hints && (hints->ai_flags & AI_NUMERICHOST)) ||
        inet_pton(AF_INET, node, &tmp) == 1 || inet_pton(AF_INET6, node, &tmp) == 1 ||
        !strcmp(node, "localhost");
    if (numeric || (hints && hints->ai_family == AF_INET6)) {
        return __real_getaddrinfo(node, service, hints, res);
    }
    char ip[64];
    switch (doh_lookup(node, ip, sizeof(ip))) {
        case 1: {
            struct addrinfo h = hints ? *hints : (struct addrinfo) {0};
            h.ai_flags = (h.ai_flags & ~AI_ADDRCONFIG) | AI_NUMERICHOST;
            h.ai_family = AF_INET;
            return __real_getaddrinfo(ip, service, &h, res);
        }
        case 0:
            return EAI_NONAME;
        default:
            return __real_getaddrinfo(node, service, hints, res);
    }
}

JNIEXPORT jint JNICALL
Java_io_github_romanvht_byedpi_core_ByeDpiProxy_jniStartProxy(JNIEnv *env, __attribute__((unused)) jobject thiz, jobjectArray args) {
    doh_setup(env);
    pthread_mutex_lock(&proxy_mutex);
    if (proxy_started) {
        pthread_mutex_unlock(&proxy_mutex);
        LOG(LOG_S, "proxy process already used");
        return -1;
    }
    proxy_started = 1;
    pthread_mutex_unlock(&proxy_mutex);

    int argc = (*env)->GetArrayLength(env, args);
    char **argv = calloc(argc + 1, sizeof(char *));
    int result = -1;
    if (!argv) {
        return result;
    }

    for (int i = 0; i < argc; i++) {
        jstring arg = (jstring) (*env)->GetObjectArrayElement(env, args, i);
        if (!arg) {
            goto cleanup;
        }

        const char *arg_str = (*env)->GetStringUTFChars(env, arg, NULL);
        if (arg_str) {
            argv[i] = strdup(arg_str);
            (*env)->ReleaseStringUTFChars(env, arg, arg_str);
        }
        (*env)->DeleteLocalRef(env, arg);
        if (!argv[i]) {
            goto cleanup;
        }
    }

    LOG(LOG_S, "starting proxy with %d args", argc);
    pthread_mutex_lock(&proxy_mutex);
    server_fd = -1;
    proxy_running = 1;
    pthread_mutex_unlock(&proxy_mutex);

    result = main(argc, argv);

    pthread_mutex_lock(&proxy_mutex);
    proxy_running = 0;
    pthread_mutex_unlock(&proxy_mutex);
    LOG(LOG_S, "proxy return code %d", result);

cleanup:
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    return result;
}

JNIEXPORT jint JNICALL
Java_io_github_romanvht_byedpi_core_ByeDpiProxy_jniStopProxy(__attribute__((unused)) JNIEnv *env, __attribute__((unused)) jobject thiz) {
    LOG(LOG_S, "send shutdown to proxy");
    pthread_mutex_lock(&proxy_mutex);
    int result = proxy_running && server_fd >= 0 ? shutdown(server_fd, SHUT_RDWR) : -1;
    pthread_mutex_unlock(&proxy_mutex);
    return result;
}
