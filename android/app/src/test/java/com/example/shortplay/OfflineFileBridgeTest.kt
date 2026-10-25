package com.example.shortplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.io.File
import java.nio.file.Files

class OfflineFileBridgeTest {
    private fun tempRoot(): File = Files.createTempDirectory("offline-bridge").toFile()

    private fun fileUnder(root: File, relative: String): File {
        val file = File(root, relative)
        file.parentFile?.mkdirs()
        file.writeBytes(byteArrayOf(1, 2, 3))
        return file
    }

    /**
     * 平台无关的 file URL：`File.toURI().rawPath` 在 POSIX 与 Windows 上都是
     * 正斜杠绝对路径，拼成 `file:///...` 后与 Android 下发的 URL 同形，
     * 不会出现 `file://C:\...` 这种没有 `/`、被当成非法 URL 的形态。
     */
    private fun fileUrl(file: File): String = "file://${file.toURI().rawPath}"

    /** `file://` 之后的部分，用来替换 host 而不碰路径分隔符。 */
    private fun urlTail(file: File): String = fileUrl(file).removePrefix("file://")

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
        val traversalFile = File(root, "offline-video/../../secret.txt")
        val traversal = fileUrl(traversalFile)
        assertNull(resolveOfflineFile(traversal, listOf(root)))
        // Sanity: the traversal really does point at the secret file.
        assertEquals(
            secret.canonicalFile,
            File("${root.absolutePath}/offline-video/../../secret.txt").canonicalFile,
        )
    }

    @Test fun encodedTraversalOutOfRootIsRejected() {
        val root = tempRoot()
        fileUnder(root.parentFile, "secret.txt")
        val encoded =
            "${fileUrl(root).trimEnd('/')}/offline-video/%2e%2e%2f%2e%2e%2fsecret.txt"
        assertNull(resolveOfflineFile(encoded, listOf(root)))
    }

    @Test fun symlinkHopOutOfRootIsRejected() {
        val root = tempRoot()
        val outside = fileUnder(tempRoot(), "secret.txt")
        val link = File(root, "link.mp4")
        runCatching { Files.createSymbolicLink(link.toPath(), outside.toPath()) }
        if (!Files.isSymbolicLink(link.toPath())) return // FS without symlink support: nothing to test.
        assertNull(resolveOfflineFile(fileUrl(link), listOf(root)))
    }

    @Test fun absolutePathOutsideRootsIsRejected() {
        val root = tempRoot()
        val outside = fileUnder(tempRoot(), "x.mp4")
        assertNull(resolveOfflineFile(fileUrl(outside), listOf(root)))
        assertNull(resolveOfflineFile("file:///etc/passwd", listOf(root)))
        assertNull(resolveOfflineFile("file:///data/data/com.other.app/files/x.mp4", listOf(root)))
    }

    @Test fun nonLocalhostHostIsRejected() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        assertNull(resolveOfflineFile("file://evil.example${urlTail(file)}", listOf(root)))
    }

    @Test fun localhostHostIsAccepted() {
        val root = tempRoot()
        val file = fileUnder(root, "offline-video/ep1.mp4")
        assertNotNull(resolveOfflineFile("file://localhost${urlTail(file)}", listOf(root)))
    }

    @Test fun nonFileSchemeIsRejected() {
        val root = tempRoot()
        assertNull(resolveOfflineFile("https://example.com/x.mp4", listOf(root)))
    }

    @Test fun missingFileIsRejected() {
        val root = tempRoot()
        val missing = File(root, "offline-video/nope.mp4")
        assertNull(resolveOfflineFile(fileUrl(missing), listOf(root)))
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

    @Test fun windowsDriveSlashIsStrippedOnlyForDrivePaths() {
        // Windows 单测下 `/C:/...` 会被 File 当成「当前驱动器根 + C:」，
        // 只剥离盘符形态；POSIX 绝对路径与相对形状保持原样。
        assertEquals("C:/offline/ep1.mp4", stripWindowsDriveSlash("/C:/offline/ep1.mp4"))
        assertEquals("C:\\offline\\ep1.mp4", stripWindowsDriveSlash("/C:\\offline\\ep1.mp4"))
        assertEquals(
            "/data/user/0/app/files/ep1.mp4",
            stripWindowsDriveSlash("/data/user/0/app/files/ep1.mp4"),
        )
        assertEquals("/C:relative", stripWindowsDriveSlash("/C:relative"))
        assertEquals("/tmp/C:/x", stripWindowsDriveSlash("/tmp/C:/x"))
    }
}
