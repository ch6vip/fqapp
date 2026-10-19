package com.example.shortplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong

class OfflineFileBridgeTest {
    private fun tempRoot(): File = Files.createTempDirectory("offline-bridge").toFile()

    private fun fileUrl(file: File, host: String = ""): String {
        val path = file.absolutePath.replace('\\', '/').let {
            if (it.startsWith('/')) it else "/$it"
        }
        return "file://$host$path"
    }

    private fun fileUnder(root: File, relative: String): File {
        val file = File(root, relative)
        file.parentFile.mkdirs()
        file.writeBytes(byteArrayOf(1, 2, 3))
        return file
    }

    @Test fun fileInsideAllowedRootIsResolved() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        val resolved = resolveOfflineFile(fileUrl(file), listOf(root))
        assertNotNull(resolved)
        assertEquals(file.canonicalFile, resolved!!.canonicalFile)
    }

    @Test fun pathTraversalOutOfRootIsRejected() {
        val root = tempRoot()
        val secret = fileUnder(root.parentFile, "secret.txt")
        val traversal = fileUrl(File("${root.absolutePath}/offline-video/../../secret.txt"))
        assertNull(resolveOfflineFile(traversal, listOf(root)))
        // Sanity: the traversal really does point at the secret file.
        assertEquals(secret.canonicalFile, File("${root.absolutePath}/offline-video/../../secret.txt").canonicalFile)
    }

    @Test fun encodedTraversalOutOfRootIsRejected() {
        val root = tempRoot()
        fileUnder(root.parentFile, "secret.txt")
        val encoded = "${fileUrl(root)}/offline-video/%2e%2e%2f%2e%2e%2fsecret.txt"
        assertNull(resolveOfflineFile(encoded, listOf(root)))
    }

    @Test fun symlinkHopOutOfRootIsRejected() {
        val root = tempRoot()
        val outside = fileUnder(tempRoot(), "secret.txt")
        val link = File(root, "link.mp4")
        runCatching { Files.createSymbolicLink(link.toPath(), outside.toPath()) }
        if (!Files.isSymbolicLink(link.toPath())) return // FS without symlink support: nothing to test.
        assumeTrue(
            "This platform's File.canonicalFile does not resolve symlinks",
            link.canonicalFile == outside.canonicalFile,
        )
        assertNull(resolveOfflineFile(fileUrl(link), listOf(root)))
    }

    @Test fun absolutePathOutsideRootsIsRejected() {
        val root = tempRoot()
        assertNull(resolveOfflineFile("file:///etc/passwd", listOf(root)))
        assertNull(resolveOfflineFile("file:///data/data/com.other.app/files/x.mp4", listOf(root)))
    }

    @Test fun nonLocalhostHostIsRejected() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        assertNull(resolveOfflineFile(fileUrl(file, "evil.example"), listOf(root)))
    }

    @Test fun localhostHostIsAccepted() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        assertNotNull(resolveOfflineFile(fileUrl(file, "localhost"), listOf(root)))
    }

    @Test fun failedStreamConnectReleasesPreparedHandle() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        val bridge = OfflineFileBridge(AtomicLong(1L)) { }
        bridge.setAllowedRoots(listOf(root))
        val id = bridge.streamPrepare(fileUrl(file), 0L, -1L)
        assertEquals(1L, id)

        // Make the canonical file disappear between prepare and connect. The
        // failed connect must not leave an unreachable entry in the stream map.
        assertTrue(file.delete())
        assertFalse(bridge.streamConnect(id))
        assertFalse(bridge.owns(id))
    }

    @Test fun nonFileSchemeIsRejected() {
        val root = tempRoot()
        assertNull(resolveOfflineFile("https://${root.absolutePath}/x.mp4", listOf(root)))
    }

    @Test fun missingFileIsRejected() {
        val root = tempRoot()
        assertNull(resolveOfflineFile("file://${root.absolutePath}/offline-video/nope.mp4", listOf(root)))
    }

    @Test fun emptyAllowedRootsRejectEverything() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        assertNull(resolveOfflineFile(fileUrl(file), emptyList()))
    }

    @Test fun siblingPrefixDoesNotMatchRoot() {
        val root = tempRoot()
        val sibling = File(root.parentFile, "${root.name}-sibling")
        val file = fileUnder(sibling, "ep1.mp4")
        assertNull(resolveOfflineFile(fileUrl(file), listOf(root)))
    }
}
