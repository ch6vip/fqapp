/*
 * 听书音频链的 JNI 桥：重采样 -> 响度压缩 -> WSOLA 时伸缩。
 *
 * 顺序与番茄官方一致（issue #129）：
 *   samplefilter(in→out rate)  ->  LoudnessProcessor  ->  atempo
 *
 * 数据流的关键约束：重采样器与压缩器都是**有状态**的，同一批输入不能被
 * 处理两次（相位会错、增益包络会重复推进）。WSOLA 又是一次吃不完整块、
 * 需要调用方把剩余部分重新交进来的。
 *
 * 解法：句柄内保留「已预处理但 WSOLA 还没吃完」的中间缓冲。
 * 调用方每次交进来的原始输入只做一次预处理，之后反复从中间缓冲喂 WSOLA，
 * 直到它吃干净。这样两级的状态都只前进一次。
 */
#include <jni.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sp_atempo.h"
#include "sp_resample.h"

#define MAX_HANDLES 32

enum ChainStage { RECEIVING, RESAMPLER_TAIL, PENDING_AT_TEMPO, WSOLA_TAIL, EXHAUSTED, FAILED };

typedef struct {
    struct sp_resampler *resampler;   /* NULL：无需重采样 */
    struct sp_atempo *atempo;
    int channels;
    int out_rate;

    /* 已预处理、尚未被 WSOLA 消费的交错 int16。 */
    int16_t *pending;
    size_t pending_frames;
    size_t pending_capacity;

    enum ChainStage stage;
} Chain;

static Chain *g_handles[MAX_HANDLES];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static int alloc_handle(Chain *chain) {
    for (int i = 1; i < MAX_HANDLES; i++) {
        if (!g_handles[i]) {
            g_handles[i] = chain;
            return i;
        }
    }
    return 0;
}

static Chain *get_handle(jint handle) {
    if (handle <= 0 || handle >= MAX_HANDLES) return NULL;
    return g_handles[handle];
}

static void destroy_chain(Chain *chain) {
    if (!chain) return;
    sp_resampler_destroy(chain->resampler);
    sp_atempo_destroy(chain->atempo);
    free(chain->pending);
    free(chain);
}

static int ensure_capacity(int16_t **buf, size_t *capacity, size_t frames,
                           int channels) {
    if (*capacity >= frames) return 0;
    const size_t maximum = SIZE_MAX / (size_t)channels / sizeof(int16_t);
    if (frames > maximum) return -1;
    size_t grown = frames;
    if (frames <= maximum - frames / 2 &&
        maximum - frames - frames / 2 >= 1024) grown += frames / 2 + 1024;
    int16_t *next =
        (int16_t *)realloc(*buf, grown * (size_t)channels * sizeof(int16_t));
    if (!next) return -1;
    *buf = next;
    *capacity = grown;
    return 0;
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeCreateChain(
    JNIEnv *env, jclass clazz, jint sample_rate, jint channels, jdouble tempo,
    jint target_rate) {
    (void)env;
    (void)clazz;
    if (sample_rate <= 0 || channels <= 0 || channels > INT_MAX / 2) return 0;

    const int out_rate = target_rate > 0 ? target_rate : sample_rate;

    Chain *chain = (Chain *)calloc(1, sizeof(Chain));
    if (!chain) return 0;
    chain->channels = channels;
    chain->out_rate = out_rate;

    chain->atempo = sp_atempo_create(out_rate, channels, tempo);
    if (!chain->atempo) goto fail;

    if (out_rate != sample_rate) {
        chain->resampler = sp_resampler_create(sample_rate, out_rate, channels);
        if (!chain->resampler) goto fail;
    }

    pthread_mutex_lock(&g_lock);
    const int handle = alloc_handle(chain);
    pthread_mutex_unlock(&g_lock);
    if (!handle) goto fail;
    return handle;

fail:
    destroy_chain(chain);
    return 0;
}

JNIEXPORT void JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeDestroy(
    JNIEnv *env, jclass clazz, jint handle) {
    (void)env;
    (void)clazz;
    if (handle <= 0 || handle >= MAX_HANDLES) return;
    pthread_mutex_lock(&g_lock);
    Chain *chain = g_handles[handle];
    g_handles[handle] = NULL;
    pthread_mutex_unlock(&g_lock);
    destroy_chain(chain);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeSetTempo(
    JNIEnv *env, jclass clazz, jint handle, jdouble tempo) {
    (void)env;
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain) return -1;
    return sp_atempo_set_tempo(chain->atempo, tempo);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeWindow(
    JNIEnv *env, jclass clazz, jint handle) {
    (void)env;
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain) return 0;
    return sp_atempo_window(chain->atempo);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeOutputBound(
    JNIEnv *env, jclass clazz, jint handle, jint input_bytes) {
    (void)env;
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain || input_bytes < 0) return -1;
    const size_t stride = (size_t)chain->channels * sizeof(int16_t);
    if ((size_t)input_bytes % stride) return -1;
    const size_t frames = (size_t)input_bytes / stride;
    const size_t resampled = chain->resampler
        ? sp_resampler_output_bound(chain->resampler, frames) : frames;
    const size_t maximum = (size_t)INT_MAX / stride;
    if (resampled == SIZE_MAX || maximum < 8192 || resampled > (maximum - 8192) / 2) return -1;
    return (jint)((resampled * 2 + 8192) * stride);
}

static int preprocess(Chain *chain, const int16_t *src, size_t frames, size_t bound) {
    size_t produced = frames;
    if (chain->resampler) {
        int16_t dummy = 0;
        produced = sp_resampler_process(chain->resampler, src, frames,
            chain->pending ? chain->pending : &dummy, bound);
        if (produced == SIZE_MAX) return -1;
    } else {
        memcpy(chain->pending, src, frames * (size_t)chain->channels * sizeof(int16_t));
    }
    chain->pending_frames = produced;
    return 0;
}

/* Also call with zero pending input: WSOLA can still own ready overlap output. */
static int drain_pending(Chain *chain, jbyte *dst, size_t capacity, size_t *written_total) {
    const size_t stride = (size_t)chain->channels * sizeof(int16_t);
    int16_t dummy = 0;
    while (*written_total < capacity) {
        size_t used = 0, written = 0;
        const size_t source_bytes = chain->pending_frames * stride;
        const size_t room = capacity - *written_total;
        if (sp_atempo_process(chain->atempo,
                chain->pending ? chain->pending : &dummy, source_bytes,
                dst + *written_total, room, &used, &written) != 0 ||
            used > source_bytes || written > room || used % stride || written % stride) return -1;
        *written_total += written;
        if (used) {
            chain->pending_frames -= used / stride;
            if (chain->pending_frames) memmove(chain->pending,
                chain->pending + used / sizeof(int16_t), chain->pending_frames * stride);
        }
        if (!used && !written) break;
    }
    return 0;
}

/* Packed unsigned16 byte counts; exactly -1 is the error sentinel. */
JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeProcess(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray src, jbyteArray dst) {
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain || !src || !dst || chain->stage != RECEIVING) return -1;
    const jsize source_length = (*env)->GetArrayLength(env, src);
    const jsize destination_length = (*env)->GetArrayLength(env, dst);
    const size_t stride = (size_t)chain->channels * sizeof(int16_t);
    if (source_length < 0 || source_length > 65535 || destination_length < 0 ||
        (size_t)source_length % stride) return -1;
    size_t capacity = (size_t)destination_length;
    if (capacity > 65535) capacity = 65535;
    capacity -= capacity % stride;
    if (!capacity) return -1;
    const size_t frames = (size_t)source_length / stride;
    const size_t bound = chain->resampler
        ? sp_resampler_output_bound(chain->resampler, frames) : frames;
    if (bound == SIZE_MAX || ensure_capacity(&chain->pending, &chain->pending_capacity,
            bound, chain->channels) != 0) return -1;
    jbyte *source = source_length ? (*env)->GetByteArrayElements(env, src, NULL) : NULL;
    if (source_length && !source) return -1;
    jbyte *destination = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!destination) {
        if (source) (*env)->ReleaseByteArrayElements(env, src, source, JNI_ABORT);
        return -1;
    }
    size_t written = 0, consumed = 0;
    int rc = drain_pending(chain, destination, capacity, &written);
    if (!rc && source_length && !chain->pending_frames && written < capacity) {
        rc = preprocess(chain, (const int16_t *)source, frames, bound);
        if (!rc) {
            consumed = (size_t)source_length;
            rc = drain_pending(chain, destination, capacity, &written);
        }
    }
    if (!rc && chain->pending_frames && written < capacity) rc = -1;
    if (source) (*env)->ReleaseByteArrayElements(env, src, source, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, dst, destination, 0);
    if (rc) {
        chain->stage = FAILED;
        return -1;
    }
    return (jint)(uint32_t)(((uint32_t)written << 16) | (uint32_t)consumed);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeFlush(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray dst) {
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain || !dst || chain->stage == FAILED) return -1;
    const jsize length = (*env)->GetArrayLength(env, dst);
    const size_t stride = (size_t)chain->channels * sizeof(int16_t);
    if (length < 0) return -1;
    const size_t capacity = (size_t)length - (size_t)length % stride;
    if (!capacity) return -1;
    if (chain->stage == EXHAUSTED) return 0;
    const size_t tail = chain->resampler ? sp_resampler_flush_bound(chain->resampler) : 0;
    if (tail == SIZE_MAX || chain->pending_frames > SIZE_MAX - tail ||
        ensure_capacity(&chain->pending, &chain->pending_capacity,
            chain->pending_frames + tail, chain->channels) != 0) return -1;
    jbyte *destination = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!destination) return -1;
    if (chain->stage == RECEIVING) chain->stage = RESAMPLER_TAIL;
    size_t written = 0;
    int rc = 0;
    if (chain->stage == RESAMPLER_TAIL) {
        if (chain->resampler && tail) {
            const size_t produced = sp_resampler_flush(chain->resampler,
                chain->pending + chain->pending_frames * (size_t)chain->channels, tail);
            if (produced == SIZE_MAX || produced != tail) rc = -1;
            else chain->pending_frames += produced;
        }
        if (!rc) chain->stage = PENDING_AT_TEMPO;
    }
    if (!rc && chain->stage == PENDING_AT_TEMPO) {
        rc = drain_pending(chain, destination, capacity, &written);
        if (!rc && written < capacity) {
            if (chain->pending_frames) rc = -1;
            else chain->stage = WSOLA_TAIL;
        }
    }
    if (!rc && chain->stage == WSOLA_TAIL && written < capacity) {
        size_t flushed = 0;
        const size_t room = capacity - written;
        rc = sp_atempo_flush(chain->atempo, destination + written, room, &flushed);
        if (flushed > room || flushed % stride) rc = -1;
        written += flushed;
        if (!rc && !flushed) chain->stage = EXHAUSTED;
    }
    (*env)->ReleaseByteArrayElements(env, dst, destination, 0);
    if (rc) {
        chain->stage = FAILED;
        return -1;
    }
    if (!written && chain->stage != EXHAUSTED) {
        chain->stage = FAILED;
        return -1;
    }
    return (jint)written;
}
