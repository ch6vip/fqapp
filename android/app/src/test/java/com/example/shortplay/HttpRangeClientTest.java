package com.example.shortplay;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import kotlin.Unit;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.Buffer;
import okio.BufferedSource;
import okio.ForwardingSource;
import okio.Okio;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

public class HttpRangeClientTest {
    private static final String URL = "https://example.invalid/video.mp4";
    private OkHttpClient client;
    private HttpRangeClient bridge;
    private final List<Request> requests = new ArrayList<>();
    private TrackingBody body;
    private int status;
    private String range;
    private String encoding;

    @Before
    public void setUp() {
        client = new OkHttpClient.Builder().addInterceptor(chain -> {
            requests.add(chain.request());
            Response.Builder response = new Response.Builder()
                    .request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(status).message("fixture").body(body);
            if (range != null) response.header("Content-Range", range);
            if (encoding != null) response.header("Content-Encoding", encoding);
            return response.build();
        }).build();
        bridge = new HttpRangeClient(client, message -> Unit.INSTANCE);
    }

    @After
    public void tearDown() {
        client.connectionPool().evictAll();
        client.dispatcher().executorService().shutdownNow();
    }

    private void respond(int code, String contentRange, String content, long length) {
        status = code;
        range = contentRange;
        body = new TrackingBody(content, length);
    }

    @Test
    public void readsTheExactInclusiveRangeAndDisablesContentEncoding() {
        respond(206, "bytes 2-4/6", "cde", 3);
        assertArrayEquals(bytes("cde"), bridge.httpRange(URL, 2, 4));
        assertEquals("bytes=2-4", requests.get(0).header("Range"));
        assertEquals("identity", requests.get(0).header("Accept-Encoding"));
        assertTrue(body.closed);
    }

    @Test
    public void sizeUsesAOneByteProbeAndKeepsTheFull64BitTotal() {
        respond(206, "bytes 0-0/5000000000", "x", 1);
        assertEquals(5000000000L, bridge.httpSize(URL));
        assertEquals("bytes=0-0", requests.get(0).header("Range"));
        assertEquals("identity", requests.get(0).header("Accept-Encoding"));
        assertTrue(body.closed);
    }

    @Test
    public void sizeRejectsIgnoredRangesUnknownTotalsAndTruncation() {
        respond(200, null, "abcdef", 6);
        assertEquals(-1L, bridge.httpSize(URL));
        assertTrue(body.closed);
        for (String invalid : new String[] {
                null, "bytes 0-0/*", "bytes 1-1/6", "bytes 0-1/6", "bytes 0-0/0",
                "bytes 0-0/9223372036854775808"
        }) {
            respond(206, invalid, "x", 1);
            assertEquals(-1L, bridge.httpSize(URL));
            assertTrue(body.closed);
        }
        respond(206, "bytes 0-0/6", "", -1);
        assertEquals(-1L, bridge.httpSize(URL));
        assertTrue(body.closed);
        respond(206, "bytes 0-0/6", "x", 1);
        encoding = "gzip";
        assertEquals(-1L, bridge.httpSize(URL));
        assertTrue(body.closed);
    }

    @Test
    public void aPreparedRequestCanBeCancelledBeforeAnyNetworkIo() {
        long id = bridge.streamPrepare(URL, 2, 6);
        assertTrue(id > 0L);
        assertTrue(requests.isEmpty());
        bridge.streamClose(id);
        bridge.streamClose(id);
        assertFalse(bridge.streamConnect(id));
        assertEquals(-1, bridge.streamRead(id, new byte[1]));
        assertTrue(requests.isEmpty());
    }

    @Test
    public void nativeStreamsRejectAChangedOrUnknownResourceSize() {
        for (String changed : new String[] {"bytes 2-5/6", "bytes 2-5/*"}) {
            respond(206, changed, "cdef", 4);
            long id = bridge.streamPrepare(URL, 2, 7);
            assertTrue(id > 0L);
            assertFalse(bridge.streamConnect(id));
            assertEquals(-1, bridge.streamRead(id, new byte[1]));
            assertTrue(body.closed);
        }
        respond(206, "bytes 2-5/6", "cdef", 4);
        long id = bridge.streamPrepare(URL, 2, 6);
        try {
            assertTrue(bridge.streamConnect(id));
            assertTrue(bridge.streamConnect(id));
            assertEquals(4, bridge.streamRead(id, new byte[4]));
        } finally {
            bridge.streamClose(id);
        }
    }

    @Test
    public void aBoundedReadDoesNotConsumeTheRestOfTheReusableBuffer() {
        respond(206, "bytes 2-5/6", "cdef", 4);
        long id = bridge.streamOpen(URL, 2);
        byte[] buffer = new byte[32];
        try {
            assertEquals(-1, bridge.streamRead(id, buffer, -1));
            assertEquals(-1, bridge.streamRead(id, buffer, 33));
            assertEquals(1, bridge.streamRead(id, buffer, 1));
            assertEquals('c', buffer[0]);
            assertEquals(0, buffer[1]);
            assertEquals(3, bridge.streamRead(id, buffer, buffer.length));
            assertEquals('d', buffer[0]);
            assertEquals('f', buffer[2]);
            assertEquals(0, bridge.streamRead(id, buffer, buffer.length));
        } finally {
            bridge.streamClose(id);
        }
    }

    @Test
    public void rangeIgnoredAtANonzeroOffsetIsRejectedAndClosed() {
        respond(200, null, "abcdef", 6);
        assertNull(bridge.httpRange(URL, 2, 4));
        assertTrue(body.closed);
        respond(200, null, "abcdef", 6);
        assertEquals(0, bridge.streamOpen(URL, 2));
        assertTrue(body.closed);
    }

    @Test
    public void incorrectOrMissingPartialResponseOffsetsAreRejected() {
        for (String invalid : new String[] {
                null, "bytes 1-3/6", "bytes 2-4/4", "items 2-4/6", "bytes 2-3/6"
        }) {
            respond(206, invalid, "cde", 3);
            assertNull(bridge.httpRange(URL, 2, 4));
            assertTrue(body.closed);
        }
    }

    @Test
    public void aFullResponseAtZeroIsLimitedToTheRequestedPrefix() {
        for (long length : new long[] {10, -1}) {
            respond(200, null, "abcdefghij", length);
            assertArrayEquals(bytes("abc"), bridge.httpRange(URL, 0, 2));
            assertTrue(body.closed);
        }
    }

    @Test
    public void aRangeExtendingPastEofCanReturnTheAvailableSuffix() {
        respond(206, "bytes 2-5/6", "cdef", 4);
        assertArrayEquals(bytes("cdef"), bridge.httpRange(URL, 2, 20));
    }

    @Test
    public void unknownTotalSizeCanStillValidateTheRequestedInterval() {
        respond(206, "bytes 2-4/*", "cde", 3);
        assertArrayEquals(bytes("cde"), bridge.httpRange(URL, 2, 4));
    }

    @Test
    public void invalidBoundsNeverIssueARequest() {
        assertNull(bridge.httpRange(URL, -1, 4));
        assertNull(bridge.httpRange(URL, 4, 3));
        assertNull(bridge.httpRange(URL, 0, Long.MAX_VALUE));
        assertEquals(0, bridge.streamOpen(URL, -1));
        assertEquals(0, bridge.streamPrepare(URL, -1, 6));
        assertEquals(0, bridge.streamPrepare(URL, 0, -2));
        assertEquals(0, bridge.streamPrepare(URL, 6, 6));
        assertEquals(0, bridge.streamPrepare(URL, 0, 0));
        assertTrue(requests.isEmpty());
    }

    @Test
    public void encodedAndInconsistentResponsesAreNotPassedToTheCryptoCore() {
        respond(206, "bytes 2-4/6", "cde", 3);
        encoding = "gzip";
        assertNull(bridge.httpRange(URL, 2, 4));
        assertTrue(body.closed);
        encoding = null;
        respond(206, "bytes 2-4/6", "cdef", 4);
        assertNull(bridge.httpRange(URL, 2, 4));
        assertTrue(body.closed);
    }

    @Test
    public void truncatedRangeFetchIsAFailureAndClosesTheBody() {
        respond(206, "bytes 2-4/6", "cd", -1);
        assertNull(bridge.httpRange(URL, 2, 4));
        assertTrue(body.closed);
    }

    @Test
    public void streamingReadsStopAtTheDeclaredRangeAndCloseIsIdempotent() {
        respond(206, "bytes 2-5/6", "cdef", -1);
        long id = bridge.streamOpen(URL, 2);
        assertTrue(id > 0);
        byte[] bytes = new byte[4];
        try {
            assertEquals(4, bridge.streamRead(id, bytes));
            assertArrayEquals(bytes("cdef"), bytes);
            assertEquals(0, bridge.streamRead(id, bytes));
        } finally {
            bridge.streamClose(id);
            bridge.streamClose(id);
        }
        assertTrue(body.closed);
    }

    @Test
    public void truncatedStreamReturnsAnErrorAndReleasesItsResponse() {
        respond(206, "bytes 2-5/6", "cd", -1);
        long id = bridge.streamOpen(URL, 2);
        assertTrue(id > 0);
        try {
            assertEquals(2, bridge.streamRead(id, new byte[4]));
            assertEquals(-1, bridge.streamRead(id, new byte[4]));
            assertTrue(body.closed);
        } finally {
            bridge.streamClose(id);
        }
    }

    @Test(timeout = 4000)
    public void streamingHeadersHaveABoundedReadTimeout() throws Exception {
        assertStalledSocketTimesOut(false);
    }

    @Test(timeout = 4000)
    public void streamingBodyReadsHaveABoundedReadTimeout() throws Exception {
        assertStalledSocketTimesOut(true);
    }

    @Test(timeout = 5000)
    public void closeInterruptsPendingResponseHeaders() throws Exception {
        assertCloseInterruptsStalledSocket(false);
    }

    @Test(timeout = 5000)
    public void closeInterruptsAPendingBodyRead() throws Exception {
        assertCloseInterruptsStalledSocket(true);
    }

    private void assertCloseInterruptsStalledSocket(boolean sendHeaders) throws Exception {
        ExecutorService workers = Executors.newFixedThreadPool(2);
        CountDownLatch accepted = new CountDownLatch(1);
        CountDownLatch readingBody = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        OkHttpClient cancellableClient = new OkHttpClient.Builder()
                .proxy(Proxy.NO_PROXY).retryOnConnectionFailure(false)
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(10, TimeUnit.SECONDS)
                .addNetworkInterceptor(chain -> {
                    Response response = chain.proceed(chain.request());
                    ResponseBody delegate = response.body();
                    // OkHttp's responseBodyStart event fires only after the
                    // first read returns. Observe entry into the actual body
                    // read instead, while the socket still has no payload.
                    ResponseBody tracked = new ResponseBody() {
                        private final BufferedSource source = Okio.buffer(
                                new ForwardingSource(delegate.source()) {
                                    @Override
                                    public long read(Buffer sink, long byteCount) throws IOException {
                                        readingBody.countDown();
                                        return super.read(sink, byteCount);
                                    }
                                });

                        @Override
                        public MediaType contentType() { return delegate.contentType(); }

                        @Override
                        public long contentLength() { return delegate.contentLength(); }

                        @Override
                        public BufferedSource source() { return source; }
                    };
                    return response.newBuilder().body(tracked).build();
                }).build();
        HttpRangeClient streaming = new HttpRangeClient(cancellableClient, message -> Unit.INSTANCE);
        long id = 0L;
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            workers.submit(() -> {
                try (Socket socket = server.accept()) {
                    if (sendHeaders) {
                        socket.getOutputStream().write(bytes(
                                "HTTP/1.1 206 Partial Content\r\n"
                                + "Content-Range: bytes 0-3/4\r\nContent-Length: 4\r\n\r\n"));
                        socket.getOutputStream().flush();
                    }
                    accepted.countDown();
                    release.await();
                } catch (Exception ignored) {
                }
            });
            id = streaming.streamPrepare("http://localhost:" + server.getLocalPort() + "/video.mp4", 0, 4);
            assertTrue(id > 0L);
            final long requestId = id;
            long started = System.nanoTime();
            Future<Integer> result = workers.submit(() -> {
                if (!streaming.streamConnect(requestId)) return -1;
                return streaming.streamRead(requestId, new byte[4]);
            });
            assertTrue(accepted.await(2, TimeUnit.SECONDS));
            if (sendHeaders) assertTrue(readingBody.await(2, TimeUnit.SECONDS));
            assertFalse(result.isDone());
            streaming.streamClose(id);
            assertEquals(-1, (int) result.get(2, TimeUnit.SECONDS));
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 4000);
            assertEquals(-1, streaming.streamRead(id, new byte[1]));
        } finally {
            streaming.streamClose(id);
            release.countDown();
            workers.shutdownNow();
            cancellableClient.connectionPool().evictAll();
            cancellableClient.dispatcher().executorService().shutdownNow();
        }
    }

    private void assertStalledSocketTimesOut(boolean sendHeaders) throws Exception {
        ExecutorService worker = Executors.newSingleThreadExecutor();
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch accepted = new CountDownLatch(1);
        OkHttpClient shortTimeout = new OkHttpClient.Builder()
                .proxy(Proxy.NO_PROXY).retryOnConnectionFailure(false)
                .connectTimeout(1, TimeUnit.SECONDS)
                .readTimeout(100, TimeUnit.MILLISECONDS).build();
        HttpRangeClient streaming = new HttpRangeClient(shortTimeout, message -> Unit.INSTANCE);
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            worker.submit(() -> {
                try (Socket socket = server.accept()) {
                    accepted.countDown();
                    if (sendHeaders) {
                        socket.getOutputStream().write(bytes(
                                "HTTP/1.1 206 Partial Content\r\n"
                                + "Content-Range: bytes 0-3/4\r\nContent-Length: 4\r\n\r\n"));
                        socket.getOutputStream().flush();
                    }
                    release.await();
                } catch (Exception ignored) {
                }
            });
            String address = "http://localhost:" + server.getLocalPort() + "/video.mp4";
            long started = System.nanoTime();
            long id = streaming.streamOpen(address, 0);
            if (sendHeaders) {
                assertTrue(id > 0);
                try {
                    assertEquals(-1, streaming.streamRead(id, new byte[4]));
                } finally {
                    streaming.streamClose(id);
                }
            } else {
                assertEquals(0, id);
            }
            assertTrue(accepted.await(1, TimeUnit.SECONDS));
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 2000);
        } finally {
            release.countDown();
            worker.shutdownNow();
            shortTimeout.connectionPool().evictAll();
            shortTimeout.dispatcher().executorService().shutdownNow();
        }
    }

    private static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    private static final class TrackingBody extends ResponseBody {
        private final long length;
        private final BufferedSource source;
        boolean closed;

        TrackingBody(String data, long length) {
            this.length = length;
            source = Okio.buffer(new ForwardingSource(new Buffer().writeUtf8(data)) {
                @Override
                public void close() throws IOException {
                    closed = true;
                    super.close();
                }
            });
        }

        @Override
        public MediaType contentType() {
            return MediaType.get("application/octet-stream");
        }

        @Override
        public long contentLength() {
            return length;
        }

        @Override
        public BufferedSource source() {
            return source;
        }
    }
}
