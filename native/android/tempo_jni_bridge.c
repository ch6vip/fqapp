/*
 * sp_atempo 的 JNI 桥：给 Kotlin 侧的 AudioProcessor 用。
 *
 * 设计原则与 crypto 的 jni_bridge.c 一致——C 侧只做数据搬运，不持有
 * Java 对象；句柄表加锁，失效句柄一律拒绝而不是静默返回成功。
 *
 * 缓冲约定：
 *   nativeProcess 一次调用内完成「喂输入 -> 收输出」，输出超过 buffer 容量
 *   时返回实际写入量，调用方按需再次调用。这与 AudioProcessor 的 queue/
 *   getOutput 两段式不同，但更简单且不会丢样本：Kotlin 侧自己维护待处理
 *   队列，每次把整段可用输入交进来。
 */
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sp_atempo.h"


/* 句柄表：只在 JNI 入口加锁，C 核心本身不感知线程。
 * AudioProcessor 的 queue/getOutput 可能在不同线程调用，句柄必须可见且
 * 释放与使用不能交叉。 */
#define MAX_HANDLES 32

static struct sp_atempo *g_handles[MAX_HANDLES];
static int g_handle_used[MAX_HANDLES];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static int alloc_handle(struct sp_atempo *ctx) {
    for (int i = 1; i < MAX_HANDLES; i++) {
        if (!g_handle_used[i]) {
            g_handle_used[i] = 1;
            g_handles[i] = ctx;
            return i;
        }
    }
    return 0;
}

static struct sp_atempo *get_handle(jint handle) {
    if (handle <= 0 || handle >= MAX_HANDLES) return NULL;
    if (!g_handle_used[handle]) return NULL;
    return g_handles[handle];
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeCreate(
    JNIEnv *env, jclass clazz, jint sample_rate, jint channels, jdouble tempo) {
    (void)env;
    (void)clazz;
    struct sp_atempo *ctx = sp_atempo_create(sample_rate, channels, tempo);
    if (!ctx) return 0;
    pthread_mutex_lock(&g_lock);
    int handle = alloc_handle(ctx);
    pthread_mutex_unlock(&g_lock);
    if (!handle) {
        sp_atempo_destroy(ctx);
        return 0;
    }
    return handle;
}

JNIEXPORT void JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeDestroy(
    JNIEnv *env, jclass clazz, jint handle) {
    (void)env;
    (void)clazz;
    if (handle <= 0 || handle >= MAX_HANDLES) return;
    pthread_mutex_lock(&g_lock);
    struct sp_atempo *ctx = g_handle_used[handle] ? g_handles[handle] : NULL;
    g_handle_used[handle] = 0;
    g_handles[handle] = NULL;
    pthread_mutex_unlock(&g_lock);
    sp_atempo_destroy(ctx);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeSetTempo(
    JNIEnv *env, jclass clazz, jint handle, jdouble tempo) {
    (void)env;
    (void)clazz;
    struct sp_atempo *ctx = get_handle(handle);
    if (!ctx) return -1;
    return sp_atempo_set_tempo(ctx, tempo);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeWindow(
    JNIEnv *env, jclass clazz, jint handle) {
    (void)env;
    (void)clazz;
    struct sp_atempo *ctx = get_handle(handle);
    if (!ctx) return 0;
    return sp_atempo_window(ctx);
}

/*
 * 处理一段输入。
 *
 * 返回值打包了两个 16-bit 量：高 16 位 = 写入 dst 的字节数，
 * 低 16 位 = 本次消费掉的输入字节数。返回 -1 表示句柄失效。
 *
 * 之所以打包：一次调用不一定能吃完输入（WSOLA 要攒够一个窗口才出帧），
 * 调用方必须知道推进量才能把剩余部分重新交进来。用一个返回值而不是
 * 回调/静态字段，避免跨线程可见性问题（AudioProcessor 的 queueInput 与
 * getOutput 可能在不同线程）。
 *
 * 两个量都限制在 65535 以内，调用方按 CHUNK_BYTES=32KiB 分块即可满足。
 */
JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeProcess(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray src, jbyteArray dst) {
    (void)clazz;
    struct sp_atempo *ctx = get_handle(handle);
    if (!ctx) return -1;

    const jsize src_len = (*env)->GetArrayLength(env, src);
    const jsize dst_cap = (*env)->GetArrayLength(env, dst);
    if (src_len <= 0 || dst_cap <= 0) return 0;

    jbyte *src_buf = (*env)->GetByteArrayElements(env, src, NULL);
    if (!src_buf) return -1;
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!dst_buf) {
        (*env)->ReleaseByteArrayElements(env, src, src_buf, JNI_ABORT);
        return -1;
    }

    size_t used = 0, written = 0;
    const int rc = sp_atempo_process(ctx, src_buf, (size_t)src_len, dst_buf,
                                     (size_t)dst_cap, &used, &written);

    (*env)->ReleaseByteArrayElements(env, src, src_buf, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);

    if (rc != 0) return -1;
    if (written > 0xFFFFu || used > 0xFFFFu) return -1;
    return (jint)((written << 16) | (jint)used);
}

/* 冲出尾部残留；返回写入字节数。 */
JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeFlush(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray dst) {
    (void)clazz;
    struct sp_atempo *ctx = get_handle(handle);
    if (!ctx) return -1;

    const jsize dst_cap = (*env)->GetArrayLength(env, dst);
    if (dst_cap <= 0) return 0;

    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!dst_buf) return -1;

    size_t written = 0;
    const int rc = sp_atempo_flush(ctx, dst_buf, (size_t)dst_cap, &written);

    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);

    if (rc != 0) return -1;
    return (jint)written;
}
