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
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sp_atempo.h"
#include "sp_resample.h"

#define MAX_HANDLES 32

typedef struct {
    struct sp_resampler *resampler;   /* NULL：无需重采样 */
    struct sp_atempo *atempo;
    int channels;
    int out_rate;

    /* 已预处理、尚未被 WSOLA 消费的交错 int16。 */
    int16_t *pending;
    size_t pending_frames;
    size_t pending_capacity;

    /* 原始输入里还没预处理的部分（WSOLA 吃不动时留到下次）。 */
    int16_t *raw;
    size_t raw_frames;
    size_t raw_capacity;
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
    free(chain->raw);
    free(chain);
}

static int ensure_capacity(int16_t **buf, size_t *capacity, size_t frames,
                           int channels) {
    if (*capacity >= frames) return 0;
    const size_t grown = frames + frames / 2 + 1024;
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
    if (sample_rate <= 0 || channels <= 0) return 0;

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
    if (!chain) return 0;
    const size_t frames =
        (size_t)input_bytes / ((size_t)chain->channels * sizeof(int16_t));
    /* 重采样最多放大到 out/in，WSOLA 在 tempo>=0.5 时最多放大 2 倍。 */
    size_t bound = frames * 6 + 8192;
    return (jint)(bound * (size_t)chain->channels * sizeof(int16_t));
}

/*
 * 把 raw 里的数据预处理进 pending（只做一次）。
 * 返回 0 成功，-1 内存不足。
 */
static int preprocess(Chain *chain) {
    if (chain->raw_frames == 0) return 0;

    const size_t need =
        chain->resampler
            ? sp_resampler_output_bound(chain->resampler, chain->raw_frames)
            : chain->raw_frames;

    if (ensure_capacity(&chain->pending, &chain->pending_capacity,
                        chain->pending_frames + need, chain->channels) != 0) {
        return -1;
    }

    int16_t *dst = chain->pending + chain->pending_frames * (size_t)chain->channels;
    size_t produced;
    if (chain->resampler) {
        produced = sp_resampler_process(chain->resampler, chain->raw,
                                        chain->raw_frames, dst, need);
    } else {
        memcpy(dst, chain->raw, chain->raw_frames * (size_t)chain->channels *
                                    sizeof(int16_t));
        produced = chain->raw_frames;
    }

    chain->pending_frames += produced;
    chain->raw_frames = 0;
    return 0;
}

/*
 * 跑一整条链。
 *
 * 返回值打包两个 16-bit 量：高 16 位 = 写出 dst 的字节数，
 * 低 16 位 = 消费掉 src 的字节数。-1 表示句柄失效或参数越界。
 *
 * 语义：src 总是**整块**被接收（拷贝进 raw），所以低 16 位始终是 src_len。
 * 返回 0 产出时调用方应当继续交新数据——WSOLA 需要攒够一个窗口才出帧。
 */
JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeProcess(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray src, jbyteArray dst) {
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain) return -1;

    const jsize src_len = (*env)->GetArrayLength(env, src);
    const jsize dst_cap = (*env)->GetArrayLength(env, dst);
    if (src_len <= 0 || dst_cap <= 0) return 0;

    const size_t frame_bytes = (size_t)chain->channels * sizeof(int16_t);
    const size_t in_frames = (size_t)src_len / frame_bytes;
    if (in_frames == 0) return 0;

    /* 1) 取走原始输入 */
    jbyte *src_buf = (*env)->GetByteArrayElements(env, src, NULL);
    if (!src_buf) return -1;
    if (ensure_capacity(&chain->raw, &chain->raw_capacity,
                        chain->raw_frames + in_frames, chain->channels) != 0) {
        (*env)->ReleaseByteArrayElements(env, src, src_buf, JNI_ABORT);
        return -1;
    }
    memcpy(chain->raw + chain->raw_frames * (size_t)chain->channels, src_buf,
           in_frames * frame_bytes);
    chain->raw_frames += in_frames;
    (*env)->ReleaseByteArrayElements(env, src, src_buf, JNI_ABORT);

    /* 2) 预处理（有状态，只做一次） */
    if (preprocess(chain) != 0) return -1;

    /* 3) WSOLA 反复吃 pending，直到它要更多输入或输出写满 */
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!dst_buf) return -1;

    size_t written_total = 0;
    for (;;) {
        if (chain->pending_frames == 0) break;
        size_t used = 0;
        size_t written = 0;
        const int rc = sp_atempo_process(
            chain->atempo, chain->pending,
            chain->pending_frames * frame_bytes, dst_buf + written_total,
            (size_t)dst_cap - written_total, &used, &written);
        if (rc != 0) break;

        written_total += written;

        if (used > 0) {
            const size_t used_frames = used / frame_bytes;
            const size_t rest = chain->pending_frames - used_frames;
            if (rest > 0) {
                memmove(chain->pending,
                        chain->pending + used_frames * (size_t)chain->channels,
                        rest * frame_bytes);
            }
            chain->pending_frames = rest;
        }

        /* 没有推进或输出写满：本轮到此为止 */
        if (used == 0 || written_total >= (size_t)dst_cap) break;
    }

    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);

    /*
     * 输入整块已被接收（低 16 位只能是 src_len，超过 16 位说明单块过大，
     * 那是调用方的分块参数错了，按契约直接拒绝）。
     *
     * 输出超 16 位则不返回错误——已经写进 dst 的样本是有效的，丢掉等于
     * 丢音频。截断到 65535 并让调用方下一轮继续拉取剩余部分。
     */
    if (src_len > 0xFFFF) return -1;
    const size_t reported = written_total > 0xFFFFu ? 0xFFFFu : written_total;
    return (jint)((reported << 16) | (jint)src_len);
}

JNIEXPORT jint JNICALL Java_com_fqapp_fqapp_SpeechTempo_nativeFlush(
    JNIEnv *env, jclass clazz, jint handle, jbyteArray dst) {
    (void)clazz;
    Chain *chain = get_handle(handle);
    if (!chain) return -1;

    const jsize dst_cap = (*env)->GetArrayLength(env, dst);
    if (dst_cap <= 0) return 0;

    /* 先把残留的原始输入处理掉 */
    if (preprocess(chain) != 0) return -1;

    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    if (!dst_buf) return -1;

    const size_t frame_bytes = (size_t)chain->channels * sizeof(int16_t);
    size_t written_total = 0;

    /* 把 pending 全部推给 WSOLA（不给新输入，逼它出帧） */
    while (chain->pending_frames > 0 && written_total < (size_t)dst_cap) {
        size_t used = 0;
        size_t written = 0;
        const int rc = sp_atempo_process(
            chain->atempo, chain->pending,
            chain->pending_frames * frame_bytes, dst_buf + written_total,
            (size_t)dst_cap - written_total, &used, &written);
        if (rc != 0) break;
        written_total += written;
        if (used == 0) break;
        const size_t used_frames = used / frame_bytes;
        const size_t rest = chain->pending_frames - used_frames;
        if (rest > 0) {
            memmove(chain->pending,
                    chain->pending + used_frames * (size_t)chain->channels,
                    rest * frame_bytes);
        }
        chain->pending_frames = rest;
    }

    /* 再冲 WSOLA 内部的重叠区 */
    {
        size_t flushed = 0;
        if (sp_atempo_flush(chain->atempo, dst_buf + written_total,
                            (size_t)dst_cap - written_total, &flushed) == 0) {
            written_total += flushed;
        }
    }

    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);
    return (jint)written_total;
}
