package com.example.shortplay;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
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
