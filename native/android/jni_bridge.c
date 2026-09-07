#include "sp_crypto.h"

#include <jni.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define SP_JNI_BUFFER_BYTES (64u * 1024u)

typedef struct {
    jclass bridge;
    jmethodID size;
    jmethodID prepare;
    jmethodID connect;
    jmethodID read;
    jmethodID close;
} bridge_methods;

typedef struct {
    bridge_methods methods;
    jstring url;
    jbyteArray bytes;
    pthread_mutex_t lock;
    jlong active_id;
    uint64_t generation;
    int terminated;
    uint64_t position;
    int64_t total;
} bridge_io;

typedef struct native_handle {
    jlong id;
    sp_stream *stream;
    bridge_io *network; /* Owned by stream, valid until all references end. */
    pthread_mutex_t operation;
    pthread_cond_t idle;
    unsigned references;
    int closing;
    uint8_t bytes[SP_JNI_BUFFER_BYTES];
    struct native_handle *next;
} native_handle;

static JavaVM *java_vm;
static bridge_methods cached_methods;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static native_handle *handles;
static uint64_t next_handle = 1;

static void throw_io(JNIEnv *env, const char *message) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass type = (*env)->FindClass(env, "java/io/IOException");
    if (type != NULL) {
        (*env)->ThrowNew(env, type, message);
        (*env)->DeleteLocalRef(env, type);
    }
}

/* Callbacks do not leave a pending Java exception while the C parser unwinds
 * and releases I/O. The JNI entry point reports the resulting sp_error as an
 * IOException. No JNIEnv is shared across threads. */
static int callback_failed(JNIEnv *env) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    (*env)->ExceptionClear(env);
    return 1;
}

static JNIEnv *thread_env(int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    if (java_vm == NULL) return NULL;
    jint status = (*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_OK) return env;
    if (status != JNI_EDETACHED) return NULL;
#ifdef __ANDROID__
    status = (*java_vm)->AttachCurrentThread(java_vm, &env, NULL);
#else
    status = (*java_vm)->AttachCurrentThread(java_vm, (void **)&env, NULL);
#endif
    if (status != JNI_OK) return NULL;
    *attached = 1;
    return env;
}

static void leave_thread(int attached) {
    if (attached) (*java_vm)->DetachCurrentThread(java_vm);
}

static void close_java_stream(JNIEnv *env, bridge_io *io, jlong id) {
    if (id == 0) return;
    (*env)->CallStaticVoidMethod(env, io->methods.bridge, io->methods.close, id);
    (void)callback_failed(env);
}

static int64_t bridge_size(void *user) {
    bridge_io *io = user;
    int attached;
    JNIEnv *env = thread_env(&attached);
    if (env == NULL) return -1;
    jlong total = (*env)->CallStaticLongMethod(env, io->methods.bridge,
                                             io->methods.size, io->url);
    if (callback_failed(env) || total <= 0) total = -1;
    io->total = total;
    leave_thread(attached);
    return total;
}

static void discard_request(JNIEnv *env, bridge_io *io, jlong id) {
    pthread_mutex_lock(&io->lock);
    if (io->active_id == id) io->active_id = 0;
    pthread_mutex_unlock(&io->lock);
    close_java_stream(env, io, id);
}

static ptrdiff_t bridge_read_at(void *user, uint64_t offset, uint8_t *buffer, size_t length) {
    bridge_io *io = user;
    if (length == 0) return 0;
    if (io->total <= 0 || offset > (uint64_t)io->total) return -1;
    if (offset == (uint64_t)io->total) return 0;
    if (length > SP_JNI_BUFFER_BYTES) length = SP_JNI_BUFFER_BYTES;
    if (length > (uint64_t)io->total - offset) length = (size_t)((uint64_t)io->total - offset);
    int attached;
    JNIEnv *env = thread_env(&attached);
    if (env == NULL) return -1;

    pthread_mutex_lock(&io->lock);
    if (io->terminated) {
        pthread_mutex_unlock(&io->lock);
        leave_thread(attached);
        return -1;
    }
    uint64_t generation = io->generation;
    jlong id = io->active_id;
    jlong obsolete = 0;
    if (id != 0 && io->position != offset) {
        obsolete = id;
        io->active_id = 0;
        id = 0;
    }
    pthread_mutex_unlock(&io->lock);
    close_java_stream(env, io, obsolete);

    if (id == 0) {
        /* prepare only creates/registers a Call. Publish its id before the
         * blocking connect, so cancel also interrupts connect/headers. */
        id = (*env)->CallStaticLongMethod(env, io->methods.bridge, io->methods.prepare,
                                         io->url, (jlong)offset, (jlong)io->total);
        if (callback_failed(env) || id <= 0) {
            leave_thread(attached);
            return -1;
        }
        pthread_mutex_lock(&io->lock);
        int cancelled = io->terminated || io->generation != generation;
        if (!cancelled) {
            io->active_id = id;
            io->position = offset;
        }
        pthread_mutex_unlock(&io->lock);
        if (cancelled) {
            close_java_stream(env, io, id);
            leave_thread(attached);
            return -1;
        }
        jboolean connected = (*env)->CallStaticBooleanMethod(env, io->methods.bridge,
                                                             io->methods.connect, id);
        if (callback_failed(env) || connected != JNI_TRUE) {
            discard_request(env, io, id);
            leave_thread(attached);
            return -1;
        }
    }

    jint count = (*env)->CallStaticIntMethod(env, io->methods.bridge, io->methods.read,
                                            id, io->bytes, (jint)length);
    if (callback_failed(env) || count <= 0 || (size_t)count > length) {
        /* EOF before the known total is an I/O failure, never a successful
         * end of the decrypted movie. */
        discard_request(env, io, id);
        leave_thread(attached);
        return -1;
    }
    (*env)->GetByteArrayRegion(env, io->bytes, 0, count, (jbyte *)buffer);
    if (callback_failed(env)) {
        discard_request(env, io, id);
        leave_thread(attached);
        return -1;
    }
    pthread_mutex_lock(&io->lock);
    int cancelled = io->terminated || io->generation != generation || io->active_id != id;
    if (!cancelled) io->position = offset + (uint64_t)count;
    pthread_mutex_unlock(&io->lock);
    leave_thread(attached);
    return cancelled ? -1 : (ptrdiff_t)count;
}

static void bridge_cancel(void *user) {
    bridge_io *io = user;
    pthread_mutex_lock(&io->lock);
    ++io->generation;
    jlong id = io->active_id;
    io->active_id = 0;
    pthread_mutex_unlock(&io->lock);
    int attached;
    JNIEnv *env = thread_env(&attached);
    if (env == NULL) return;
    close_java_stream(env, io, id);
    leave_thread(attached);
}

static void bridge_close(void *user) {
    bridge_io *io = user;
    pthread_mutex_lock(&io->lock);
    io->terminated = 1;
    pthread_mutex_unlock(&io->lock);
    bridge_cancel(io);
    int attached;
    JNIEnv *env = thread_env(&attached);
    if (env != NULL) {
        if (io->url != NULL) (*env)->DeleteGlobalRef(env, io->url);
        if (io->bytes != NULL) (*env)->DeleteGlobalRef(env, io->bytes);
        leave_thread(attached);
    }
    pthread_mutex_destroy(&io->lock);
    free(io);
}

static bridge_io *create_io(JNIEnv *env, jstring url) {
    bridge_io *io = calloc(1, sizeof(*io));
    if (io == NULL) {
        throw_io(env, "Cannot allocate crypto network context");
        return NULL;
    }
    if (pthread_mutex_init(&io->lock, NULL) != 0) {
        free(io);
        throw_io(env, "Cannot initialize crypto network lock");
        return NULL;
    }
    pthread_mutex_lock(&init_lock);
    io->methods = cached_methods;
    pthread_mutex_unlock(&init_lock);
    if (io->methods.bridge == NULL) {
        pthread_mutex_destroy(&io->lock);
        free(io);
        throw_io(env, "CryptoNative.ensureInit() must run before opening a stream");
        return NULL;
    }
    io->url = (*env)->NewGlobalRef(env, url);
    jbyteArray bytes = NULL;
    if (io->url != NULL) bytes = (*env)->NewByteArray(env, SP_JNI_BUFFER_BYTES);
    if (bytes != NULL) {
        io->bytes = (*env)->NewGlobalRef(env, bytes);
        (*env)->DeleteLocalRef(env, bytes);
    }
    if (io->url == NULL || io->bytes == NULL) {
        bridge_close(io);
        throw_io(env, "Cannot allocate crypto network buffer");
        return NULL;
    }
    return io;
}

static native_handle *acquire_handle(JNIEnv *env, jlong id) {
    pthread_mutex_lock(&registry_lock);
    native_handle *entry = handles;
    while (entry != NULL && entry->id != id) entry = entry->next;
    if (entry != NULL) ++entry->references;
    pthread_mutex_unlock(&registry_lock);
    if (entry == NULL) {
        throw_io(env, "Invalid or closed crypto stream handle");
        return NULL;
    }
    pthread_mutex_lock(&entry->operation);
    pthread_mutex_lock(&registry_lock);
    int closing = entry->closing;
    if (closing) {
        // Drop the operation lock before the last reference permits close to
        // destroy it. registry_lock still protects the entry in this window.
        pthread_mutex_unlock(&entry->operation);
        --entry->references;
        if (entry->references == 0) pthread_cond_signal(&entry->idle);
    }
    pthread_mutex_unlock(&registry_lock);
    if (closing) {
        throw_io(env, "Crypto stream is closing");
        return NULL;
    }
    return entry;
}

static void release_handle(native_handle *entry) {
    pthread_mutex_unlock(&entry->operation);
    pthread_mutex_lock(&registry_lock);
    --entry->references;
    if (entry->closing && entry->references == 0) pthread_cond_signal(&entry->idle);
    pthread_mutex_unlock(&registry_lock);
}

static int hex_digit(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

static void erase_key(uint8_t key[16]) {
    volatile uint8_t *bytes = key;
    for (size_t i = 0; i < 16; ++i) bytes[i] = 0;
}

static int decode_key(JNIEnv *env, jstring key_hex, uint8_t key[16]) {
    if (key_hex == NULL || (*env)->GetStringUTFLength(env, key_hex) != 32) {
        throw_io(env, "CENC key must contain exactly 32 hexadecimal characters");
        return 0;
    }
    const char *text = (*env)->GetStringUTFChars(env, key_hex, NULL);
    if (text == NULL) return 0;
    int valid = 1;
    for (size_t i = 0; i < 16; ++i) {
        int high = hex_digit(text[i * 2]);
        int low = hex_digit(text[i * 2 + 1]);
        if (high < 0 || low < 0) {
            valid = 0;
            break;
        }
        key[i] = (uint8_t)((high << 4) | low);
    }
    (*env)->ReleaseStringUTFChars(env, key_hex, text);
    if (!valid) {
        erase_key(key);
        throw_io(env, "CENC key contains a non-hexadecimal character");
    }
    return valid;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    java_vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jboolean JNICALL Java_com_example_shortplay_CryptoNative_nativeInit(
        JNIEnv *env, jobject instance, jclass bridge) {
    (void)instance;
    if (bridge == NULL) {
        throw_io(env, "HttpBridge class is required");
        return JNI_FALSE;
    }
    pthread_mutex_lock(&init_lock);
    if (cached_methods.bridge != NULL) {
        pthread_mutex_unlock(&init_lock);
        return JNI_TRUE;
    }
    bridge_methods methods = {0};
    methods.size = (*env)->GetStaticMethodID(env, bridge, "httpSize", "(Ljava/lang/String;)J");
    if (methods.size != NULL) methods.prepare = (*env)->GetStaticMethodID(
            env, bridge, "streamPrepare", "(Ljava/lang/String;JJ)J");
    if (methods.prepare != NULL) methods.connect = (*env)->GetStaticMethodID(env, bridge, "streamConnect", "(J)Z");
    if (methods.connect != NULL) methods.read = (*env)->GetStaticMethodID(env, bridge, "streamRead", "(J[BI)I");
    if (methods.read != NULL) methods.close = (*env)->GetStaticMethodID(env, bridge, "streamClose", "(J)V");
    if (methods.close != NULL) methods.bridge = (*env)->NewGlobalRef(env, bridge);
    if (methods.bridge != NULL) cached_methods = methods;
    pthread_mutex_unlock(&init_lock);
    if (methods.bridge == NULL) {
        (void)callback_failed(env);
        throw_io(env, "HttpBridge does not implement the native streaming I/O contract");
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

JNIEXPORT jlong JNICALL Java_com_example_shortplay_CryptoNative_nativePlayerStreamOpen(
        JNIEnv *env, jclass type, jstring url, jstring key_hex) {
    (void)type;
    if (url == NULL || (*env)->GetStringLength(env, url) == 0) {
        throw_io(env, "Crypto stream URL is required");
        return 0;
    }
    uint8_t key[16] = {0};
    if (!decode_key(env, key_hex, key)) return 0;
    bridge_io *network = create_io(env, url);
    if (network == NULL) {
        erase_key(key);
        return 0;
    }
    sp_io io = {network, bridge_size, bridge_read_at, bridge_cancel, bridge_close};
    sp_error error = {0};
    sp_stream *stream = sp_stream_open(&io, key, &error);
    erase_key(key);
    if (stream == NULL) {
        bridge_close(network); /* Failed open does not take ownership. */
        throw_io(env, error.message[0] ? error.message : "Cannot open CENC stream");
        return 0;
    }
    native_handle *entry = calloc(1, sizeof(*entry));
    if (entry == NULL) {
        sp_stream_close(stream);
        throw_io(env, "Cannot allocate crypto stream handle");
        return 0;
    }
    if (pthread_mutex_init(&entry->operation, NULL) != 0) {
        sp_stream_close(stream);
        free(entry);
        throw_io(env, "Cannot initialize crypto stream lock");
        return 0;
    }
    if (pthread_cond_init(&entry->idle, NULL) != 0) {
        pthread_mutex_destroy(&entry->operation);
        sp_stream_close(stream);
        free(entry);
        throw_io(env, "Cannot initialize crypto stream condition");
        return 0;
    }
    entry->stream = stream;
    entry->network = network;
    pthread_mutex_lock(&registry_lock);
    if (next_handle > INT64_MAX) {
        pthread_mutex_unlock(&registry_lock);
        pthread_cond_destroy(&entry->idle);
        pthread_mutex_destroy(&entry->operation);
        sp_stream_close(stream);
        free(entry);
        throw_io(env, "Crypto stream handle space is exhausted");
        return 0;
    }
    entry->id = (jlong)next_handle++;
    entry->next = handles;
    handles = entry;
    jlong id = entry->id;
    pthread_mutex_unlock(&registry_lock);
    return id;
}

JNIEXPORT jint JNICALL Java_com_example_shortplay_CryptoNative_nativePlayerStreamRead(
        JNIEnv *env, jclass type, jlong id, jbyteArray bytes, jint length) {
    (void)type;
    if (bytes == NULL || length < 0 || length > (*env)->GetArrayLength(env, bytes)) {
        throw_io(env, "Crypto read length is outside the destination array");
        return -1;
    }
    native_handle *entry = acquire_handle(env, id);
    if (entry == NULL) return -1;
    if (length == 0) {
        release_handle(entry);
        return 0;
    }
    size_t requested = (size_t)length;
    if (requested > SP_JNI_BUFFER_BYTES) requested = SP_JNI_BUFFER_BYTES;
    sp_error error = {0};
    ptrdiff_t count = sp_stream_read(entry->stream, entry->bytes, requested, &error);
    if (count >= 0 && (size_t)count <= requested) {
        if (count > 0) (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)count, (jbyte *)entry->bytes);
        release_handle(entry);
        return (*env)->ExceptionCheck(env) ? -1 : (jint)count;
    }
    release_handle(entry);
    throw_io(env, error.message[0] ? error.message : "CENC stream read failed");
    return -1;
}

JNIEXPORT jlong JNICALL Java_com_example_shortplay_CryptoNative_nativePlayerStreamSeek(
        JNIEnv *env, jclass type, jlong id, jlong position) {
    (void)type;
    if (position < 0) {
        throw_io(env, "Crypto seek position cannot be negative");
        return -1;
    }
    native_handle *entry = acquire_handle(env, id);
    if (entry == NULL) return -1;
    sp_error error = {0};
    int64_t actual = sp_stream_seek(entry->stream, position, &error);
    release_handle(entry);
    if (actual != position) {
        throw_io(env, error.message[0] ? error.message : "CENC seek could not reach the requested position");
        return -1;
    }
    return actual;
}

JNIEXPORT jlong JNICALL Java_com_example_shortplay_CryptoNative_nativePlayerStreamSize(
        JNIEnv *env, jclass type, jlong id) {
    (void)type;
    native_handle *entry = acquire_handle(env, id);
    if (entry == NULL) return -1;
    int64_t total = sp_stream_size(entry->stream);
    release_handle(entry);
    if (total < 0) throw_io(env, "CENC stream size is unavailable");
    return total;
}

JNIEXPORT void JNICALL Java_com_example_shortplay_CryptoNative_nativePlayerStreamClose(
        JNIEnv *env, jclass type, jlong id) {
    (void)env;
    (void)type;
    pthread_mutex_lock(&registry_lock);
    native_handle **link = &handles;
    while (*link != NULL && (*link)->id != id) link = &(*link)->next;
    native_handle *entry = *link;
    if (entry != NULL) {
        *link = entry->next;
        entry->closing = 1;
    }
    pthread_mutex_unlock(&registry_lock);
    if (entry == NULL) return; /* Repeated close, including zero, is harmless. */

    /* Cancelling never waits for the operation mutex. In-flight reads (and
     * response headers) unblock before we wait for their references to end. */
    pthread_mutex_lock(&entry->network->lock);
    entry->network->terminated = 1;
    pthread_mutex_unlock(&entry->network->lock);
    /* The terminal gate also covers a reader between the core's cancelled
     * check and its read_at call. It must not start a new request after our
     * cancellation has already completed. Ordinary seeks only cancel the
     * current request and leave this gate open. */
    sp_stream_cancel(entry->stream);
    pthread_mutex_lock(&registry_lock);
    while (entry->references != 0) pthread_cond_wait(&entry->idle, &registry_lock);
    pthread_mutex_unlock(&registry_lock);
    sp_stream_close(entry->stream);
    pthread_cond_destroy(&entry->idle);
    pthread_mutex_destroy(&entry->operation);
    free(entry);
}

JNIEXPORT jint JNICALL Java_com_example_shortplay_CryptoNative_nativePrewarmHeaderOnly(
        JNIEnv *env, jobject instance, jstring url, jstring key_hex) {
    (void)instance;
    jlong id = Java_com_example_shortplay_CryptoNative_nativePlayerStreamOpen(env, NULL, url, key_hex);
    if (id == 0) return -1;
    Java_com_example_shortplay_CryptoNative_nativePlayerStreamClose(env, NULL, id);
    return 0;
}

JNIEXPORT jint JNICALL Java_com_example_shortplay_CryptoNative_nativePrewarm(
        JNIEnv *env, jobject instance, jstring url, jstring key_hex) {
    return Java_com_example_shortplay_CryptoNative_nativePrewarmHeaderOnly(env, instance, url, key_hex);
}
