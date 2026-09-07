package com.example.shortplay;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/** Linux test entry point with exactly the production class name and JNI declarations. */
public final class CryptoNative {
    private static final CryptoNative INSTANCE = new CryptoNative();
    private static final String URL = "memory://independently-encrypted-cenc.mp4";
    private static final int BUFFER_LIMIT = 64 * 1024;
    private static final int DEADLINE_SECONDS = 5;
    private static byte[] expected;
    private static String key;
    private static int mediaPosition;

    private native boolean nativeInit(Class<?> bridge) throws IOException;
    private native int nativePrewarm(String url, String keyHex) throws IOException;
    private native int nativePrewarmHeaderOnly(String url, String keyHex) throws IOException;
    public static native long nativePlayerStreamOpen(String url, String keyHex) throws IOException;
    public static native int nativePlayerStreamRead(long handle, byte[] bytes, int length) throws IOException;
    public static native long nativePlayerStreamSeek(long handle, long position) throws IOException;
    public static native long nativePlayerStreamSize(long handle) throws IOException;
    public static native void nativePlayerStreamClose(long handle);

    private CryptoNative() {}

    @FunctionalInterface
    private interface CheckedAction { void run() throws Exception; }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void expectIo(String name, CheckedAction action) throws Exception {
        try {
            action.run();
        } catch (IOException expectedError) {
            check(expectedError.getMessage() != null && !expectedError.getMessage().isEmpty(), name + ": missing error message");
            return;
        }
        throw new AssertionError(name + ": expected IOException");
    }

    private static ExecutorService workers(int count) {
        return Executors.newFixedThreadPool(count, action -> {
            Thread worker = new Thread(action, "jni-regression-worker");
            // A broken native wait must fail the bounded test, not keep the
            // Java process alive after main reports its failed assertion.
            worker.setDaemon(true);
            return worker;
        });
    }

    private static void await(CountDownLatch latch, String name) throws InterruptedException {
        check(latch.await(DEADLINE_SECONDS, TimeUnit.SECONDS), name + " timed out");
    }

    private static void complete(Future<?> future) throws Exception {
        future.get(DEADLINE_SECONDS, TimeUnit.SECONDS);
    }

    private static long open() throws IOException {
        long handle = nativePlayerStreamOpen(URL, key);
        check(handle > 0, "open returned a nonpositive handle");
        check(nativePlayerStreamSize(handle) == expected.length, "wrong 64-bit JNI stream size");
        return handle;
    }

    private static void compare(byte[] actual, int length, int position) {
        check(length >= 0 && position >= 0 && length <= expected.length - position, "comparison bounds");
        for (int i = 0; i < length; ++i) {
            if (actual[i] != expected[position + i]) {
                throw new AssertionError("plaintext differs at absolute byte " + (position + i));
            }
        }
    }

    private static void readRange(long handle, int position, int length) throws IOException {
        check(nativePlayerStreamSeek(handle, position) == position, "seek returned the wrong position");
        byte[] bytes = new byte[Math.max(1, Math.min(length, 100003))];
        int end = Math.min(expected.length, position + length);
        while (position < end) {
            int requested = Math.min(bytes.length, end - position);
            int count = nativePlayerStreamRead(handle, bytes, requested);
            check(count > 0 && count <= requested && count <= BUFFER_LIMIT, "invalid non-EOF read count");
            compare(bytes, count, position);
            position += count;
        }
    }

    private static void noRequests() {
        check(MemoryBridge.sessions.isEmpty(), "leaked Java network requests: " + MemoryBridge.sessions.keySet());
        check(MemoryBridge.created.get() == MemoryBridge.closed.get(), "request creation/close counts differ");
        check(MemoryBridge.maximumRead.get() <= BUFFER_LIMIT, "JNI exceeded the 64 KiB bridge buffer");
    }

    private static void abi() throws Exception {
        long handle = open();
        try {
            readRange(handle, 0, expected.length);
            check(nativePlayerStreamRead(handle, new byte[1], 1) == 0, "EOF must be zero");
            check(nativePlayerStreamRead(handle, new byte[0], 0) == 0, "empty read must be zero");
            check(nativePlayerStreamSeek(handle, expected.length) == expected.length, "seek exactly to EOF");
            check(nativePlayerStreamRead(handle, new byte[8], 8) == 0, "EOF after seek");
            check(nativePlayerStreamSeek(handle, mediaPosition) == mediaPosition, "seek to media payload");
            byte[] large = new byte[200000];
            Arrays.fill(large, (byte) 0x5a);
            int count = nativePlayerStreamRead(handle, large, 150000);
            check(count == BUFFER_LIMIT, "large media read must be capped at 64 KiB");
            compare(large, count, mediaPosition);
            for (int i = count; i < large.length; ++i) check(large[i] == (byte) 0x5a, "JNI overwrote destination suffix");
            MemoryBridge.maxChunk = 997;
            Random random = new Random(31684);
            for (int i = 0; i < 80; ++i) {
                int position = random.nextInt(expected.length);
                readRange(handle, position, Math.min(4097, expected.length - position));
            }
        } finally {
            nativePlayerStreamClose(handle);
        }
        noRequests();
    }

    private static void errors() throws Exception {
        for (String bad : new String[] {null, "", "00", key.substring(1), key + "0", "gg" + key.substring(2)}) {
            expectIo("malformed key", () -> nativePlayerStreamOpen(URL, bad));
            noRequests();
        }
        expectIo("null URL", () -> nativePlayerStreamOpen(null, key));
        expectIo("empty URL", () -> nativePlayerStreamOpen("", key));
        expectIo("unavailable URL", () -> nativePlayerStreamOpen("memory://absent", key));
        for (long bad : new long[] {0, -1, Long.MAX_VALUE}) {
            expectIo("invalid read handle", () -> nativePlayerStreamRead(bad, new byte[1], 1));
            expectIo("invalid empty-read handle", () -> nativePlayerStreamRead(bad, new byte[0], 0));
            expectIo("invalid seek handle", () -> nativePlayerStreamSeek(bad, 0));
            expectIo("invalid size handle", () -> nativePlayerStreamSize(bad));
            nativePlayerStreamClose(bad);
            nativePlayerStreamClose(bad);
        }
        long handle = open();
        try {
            expectIo("null destination", () -> nativePlayerStreamRead(handle, null, 0));
            expectIo("negative length", () -> nativePlayerStreamRead(handle, new byte[8], -1));
            expectIo("oversized length", () -> nativePlayerStreamRead(handle, new byte[8], 9));
            expectIo("negative seek", () -> nativePlayerStreamSeek(handle, -1));
            expectIo("seek past EOF", () -> nativePlayerStreamSeek(handle, expected.length + 1L));
            expectIo("overflow-sized seek", () -> nativePlayerStreamSeek(handle, Long.MAX_VALUE));
            readRange(handle, mediaPosition + 17, 1025);
        } finally {
            nativePlayerStreamClose(handle);
            nativePlayerStreamClose(handle);
        }
        expectIo("stale read handle", () -> nativePlayerStreamRead(handle, new byte[1], 1));
        expectIo("stale size handle", () -> nativePlayerStreamSize(handle));
        expectIo("stale seek handle", () -> nativePlayerStreamSeek(handle, 0));
        noRequests();
    }

    private static void prewarm() throws Exception {
        check(INSTANCE.nativePrewarm(URL, key) == 0, "prewarm failed");
        noRequests();
        check(INSTANCE.nativePrewarmHeaderOnly(URL, key.toUpperCase(java.util.Locale.ROOT)) == 0, "header prewarm failed");
        noRequests();
        byte[] original = MemoryBridge.data;
        try {
            MemoryBridge.data = new byte[] {0, 0, 0, 4, 'b', 'a', 'd', '!'};
            expectIo("malformed MP4 open", () -> nativePlayerStreamOpen(URL, key));
            noRequests();
            expectIo("malformed MP4 prewarm", () -> INSTANCE.nativePrewarm(URL, key));
            noRequests();
        } finally {
            MemoryBridge.data = original;
        }
        long handle = open();
        nativePlayerStreamClose(handle);
        noRequests();
    }

    private static void callbacks() throws Exception {
        MemoryBridge.failSize.set(true);
        expectIo("Java size exception", () -> nativePlayerStreamOpen(URL, key));
        noRequests();
        MemoryBridge.failConnect.set(true);
        expectIo("Java connect exception during open", () -> nativePlayerStreamOpen(URL, key));
        noRequests();
        MemoryBridge.failRead.set(true);
        expectIo("Java read exception during open", () -> nativePlayerStreamOpen(URL, key));
        noRequests();
        long handle = open();
        try {
            nativePlayerStreamSeek(handle, mediaPosition);
            MemoryBridge.failRead.set(true);
            expectIo("Java payload read exception", () -> nativePlayerStreamRead(handle, new byte[32], 32));
            readRange(handle, mediaPosition, 8193);
            nativePlayerStreamSeek(handle, 1);
            MemoryBridge.failConnect.set(true);
            expectIo("Java reconnect exception", () -> nativePlayerStreamRead(handle, new byte[32], 32));
            readRange(handle, 1, 257);
        } finally {
            nativePlayerStreamClose(handle);
        }
        noRequests();
    }

    private static void parallel() throws Exception {
        MemoryBridge.maxChunk = 113;
        ExecutorService pool = workers(4);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<?>> results = new ArrayList<>();
        try {
            for (int index = 0; index < 4; ++index) {
                final int seed = index;
                results.add(pool.submit(() -> {
                    await(start, "parallel start");
                    long handle = open();
                    try {
                        Random random = new Random(42 + seed);
                        for (int i = 0; i < 40; ++i) {
                            int position = random.nextInt(expected.length);
                            readRange(handle, position, Math.min(1025, expected.length - position));
                        }
                    } finally {
                        nativePlayerStreamClose(handle);
                    }
                    return null;
                }));
            }
            start.countDown();
            for (Future<?> result : results) complete(result);
        } finally {
            MemoryBridge.cancelAll();
            pool.shutdownNow();
        }
        noRequests();
    }

    private static void cancelBlocked(GateKind kind) throws Exception {
        long handle = open();
        long other = open();
        ExecutorService pool = workers(5);
        Gate gate = new Gate(kind);
        MemoryBridge.nextGate.set(gate);
        CountDownLatch queued = new CountDownLatch(2);
        try {
            nativePlayerStreamSeek(handle, mediaPosition);
            Future<?> blocked = pool.submit(() -> {
                expectIo("cancelled " + kind, () -> nativePlayerStreamRead(handle, new byte[32], 32));
                return null;
            });
            await(gate.entered, "native " + kind + " callback entry");
            check(!blocked.isDone(), "callback did not remain blocked before close");
            // Proves neither the global registry mutex nor another handle is
            // held hostage by this handle's network call.
            Future<?> independent = pool.submit(() -> {
                readRange(other, mediaPosition + 123, 511);
                nativePlayerStreamClose(other);
                return null;
            });
            complete(independent);
            List<Future<?>> waiting = new ArrayList<>();
            for (int i = 0; i < 2; ++i) {
                waiting.add(pool.submit(() -> {
                    queued.countDown();
                    expectIo("queued operation on closing handle", () -> nativePlayerStreamRead(handle, new byte[8], 8));
                    return null;
                }));
            }
            await(queued, "queued native operations");
            Future<?> closing = pool.submit(() -> nativePlayerStreamClose(handle));
            complete(closing);
            complete(blocked);
            for (Future<?> waiter : waiting) complete(waiter);
            check(gate.cancelled.getCount() == 0, "close never released the blocking request");
            expectIo("closed handle after cancellation", () -> nativePlayerStreamSize(handle));
        } finally {
            MemoryBridge.nextGate.set(null);
            MemoryBridge.cancelAll();
            nativePlayerStreamClose(handle);
            nativePlayerStreamClose(other);
            pool.shutdownNow();
        }
        noRequests();
    }

    private static void closeRaces() throws Exception {
        ExecutorService pool = workers(4);
        MemoryBridge.maxChunk = 37;
        try {
            for (int iteration = 0; iteration < 80; ++iteration) {
                long handle = open();
                CountDownLatch start = new CountDownLatch(1);
                List<Future<?>> results = new ArrayList<>();
                for (int i = 0; i < 3; ++i) {
                    final int worker = i;
                    results.add(pool.submit(() -> {
                        await(start, "close race start");
                        try {
                            if (worker == 0) nativePlayerStreamSeek(handle, mediaPosition + 5);
                            else nativePlayerStreamRead(handle, new byte[128], 128);
                        } catch (IOException closed) {
                            check(closed.getMessage() != null, "missing closing error");
                        }
                        return null;
                    }));
                }
                results.add(pool.submit(() -> {
                    await(start, "close race start");
                    nativePlayerStreamClose(handle);
                    nativePlayerStreamClose(handle);
                    return null;
                }));
                start.countDown();
                for (Future<?> result : results) complete(result);
                expectIo("handle after close race", () -> nativePlayerStreamSize(handle));
                noRequests();
            }
        } finally {
            MemoryBridge.cancelAll();
            pool.shutdownNow();
        }
    }

    public static void main(String[] args) throws Exception {
        check(args.length == 6, "scenario, library, encrypted, expected, key, media offset required");
        MemoryBridge.data = Files.readAllBytes(Path.of(args[2]));
        expected = Files.readAllBytes(Path.of(args[3]));
        key = args[4];
        mediaPosition = Integer.parseInt(args[5]);
        check(expected.length == MemoryBridge.data.length && mediaPosition > 0, "invalid fixture");
        System.load(Path.of(args[1]).toAbsolutePath().toString());
        expectIo("open without initialization", () -> nativePlayerStreamOpen(URL, key));
        expectIo("null bridge", () -> INSTANCE.nativeInit(null));
        expectIo("incomplete bridge class", () -> INSTANCE.nativeInit(Object.class));
        check(INSTANCE.nativeInit(MemoryBridge.class), "nativeInit failed");
        check(INSTANCE.nativeInit(MemoryBridge.class), "nativeInit must be idempotent");
        try {
            switch (args[0]) {
                case "abi": abi(); break;
                case "errors": errors(); break;
                case "prewarm": prewarm(); break;
                case "callbacks": callbacks(); break;
                case "parallel": parallel(); break;
                case "cancel_connect": cancelBlocked(GateKind.CONNECT); break;
                case "cancel_read": cancelBlocked(GateKind.READ); break;
                case "close_races": closeRaces(); break;
                default: throw new AssertionError("unknown scenario " + args[0]);
            }
            noRequests();
            System.out.println("JNI TEST OK: " + args[0]);
        } finally {
            MemoryBridge.cancelAll();
        }
    }

    private enum GateKind { CONNECT, READ }

    private static final class Gate {
        final GateKind kind;
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch cancelled = new CountDownLatch(1);

        Gate(GateKind kind) { this.kind = kind; }

        void block(Session session) throws IOException {
            session.gate = this;
            entered.countDown();
            if (session.closed) cancelled.countDown();
            try {
                if (!cancelled.await(DEADLINE_SECONDS * 2L, TimeUnit.SECONDS)) {
                    throw new IOException("test request was never cancelled");
                }
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException("test callback interrupted", error);
            }
        }
    }

    private static final class Session {
        int position;
        volatile boolean closed;
        volatile Gate gate;

        Session(int position) { this.position = position; }
    }

    /** The real JNI implementation calls these exact production callback signatures. */
    public static final class MemoryBridge {
        static volatile byte[] data;
        static volatile int maxChunk = Integer.MAX_VALUE;
        static final AtomicLong nextId = new AtomicLong(1);
        static final AtomicInteger created = new AtomicInteger();
        static final AtomicInteger closed = new AtomicInteger();
        static final AtomicInteger maximumRead = new AtomicInteger();
        static final ConcurrentHashMap<Long, Session> sessions = new ConcurrentHashMap<>();
        static final AtomicReference<Gate> nextGate = new AtomicReference<>();
        static final AtomicBoolean failSize = new AtomicBoolean();
        static final AtomicBoolean failConnect = new AtomicBoolean();
        static final AtomicBoolean failRead = new AtomicBoolean();

        private MemoryBridge() {}

        public static long httpSize(String url) throws IOException {
            if (!URL.equals(url) || failSize.getAndSet(false)) throw new IOException("fixture size unavailable");
            return data.length;
        }

        public static long streamPrepare(String url, long start, long expectedSize) throws IOException {
            if (!URL.equals(url) || start < 0 || start >= data.length || expectedSize != data.length) {
                throw new IOException("fixture request bounds");
            }
            long id = nextId.getAndIncrement();
            sessions.put(id, new Session((int) start));
            created.incrementAndGet();
            return id;
        }

        private static void maybeBlock(Session session, GateKind kind) throws IOException {
            Gate gate = nextGate.get();
            if (gate != null && gate.kind == kind && nextGate.compareAndSet(gate, null)) gate.block(session);
        }

        public static boolean streamConnect(long id) throws IOException {
            Session session = sessions.get(id);
            if (session == null) return false;
            if (failConnect.getAndSet(false)) throw new IOException("fixture connect failed");
            maybeBlock(session, GateKind.CONNECT);
            return !session.closed;
        }

        public static int streamRead(long id, byte[] bytes, int length) throws IOException {
            Session session = sessions.get(id);
            if (session == null) return -1;
            if (bytes == null || length < 0 || length > bytes.length) throw new IOException("JNI buffer bounds");
            maximumRead.accumulateAndGet(length, Math::max);
            if (failRead.getAndSet(false)) throw new IOException("fixture read failed");
            maybeBlock(session, GateKind.READ);
            synchronized (session) {
                if (session.closed) return -1;
                int count = Math.min(Math.min(length, maxChunk), data.length - session.position);
                System.arraycopy(data, session.position, bytes, 0, count);
                session.position += count;
                return count;
            }
        }

        public static void streamClose(long id) {
            Session session = sessions.remove(id);
            if (session == null) return;
            synchronized (session) { session.closed = true; }
            closed.incrementAndGet();
            Gate gate = session.gate;
            if (gate != null) gate.cancelled.countDown();
        }

        static void cancelAll() {
            for (Long id : sessions.keySet()) streamClose(id);
        }
    }
}
