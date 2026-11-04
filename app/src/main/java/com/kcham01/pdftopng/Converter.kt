package com.kcham01.pdftopng

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.BufferedOutputStream
import java.io.IOException
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Renders every page of every PDF directly inside [inputTree] to an image file.
 * Output layout: <outputTree>/<pdf name>/page_0001.png, page_0002.png, ...
 *
 * Re-running the same job resumes: pages that already exist are skipped, except the
 * last one found for each PDF, which is re-rendered in case it was cut off mid-write.
 */
class Converter(
    private val resolver: ContentResolver,
    private val inputTree: Uri,
    private val outputTree: Uri,
    private val format: ImageFormat,
    private val longSidePx: Int,
    private val onPageDone: () -> Unit,
) {

    enum class ImageFormat(val ext: String, val mime: String, val compress: Bitmap.CompressFormat, val quality: Int) {
        PNG("png", "image/png", Bitmap.CompressFormat.PNG, 100),
        JPEG("jpg", "image/jpeg", Bitmap.CompressFormat.JPEG, 90),
    }

    private data class Doc(val uri: Uri, val id: String, val name: String, val mime: String, val size: Long) {
        val isDir: Boolean get() = mime == Document.MIME_TYPE_DIR
    }

    fun run() {
        ConvertState.update {
            ConvertState.Snapshot(running = true, status = "Looking for PDFs…")
        }

        val inputRootId = DocumentsContract.getTreeDocumentId(inputTree)
        val pdfs = listChildren(inputTree, inputRootId)
            .filter { !it.isDir && (it.mime == "application/pdf" || it.name.endsWith(".pdf", ignoreCase = true)) }
            .sortedBy { it.name.lowercase() }

        if (pdfs.isEmpty()) {
            ConvertState.update {
                it.copy(running = false, finished = true, status = "No PDF files found directly inside the input folder.")
            }
            return
        }

        val outputRootId = DocumentsContract.getTreeDocumentId(outputTree)
        val outputRootUri = DocumentsContract.buildDocumentUriUsingTree(outputTree, outputRootId)

        for ((index, pdf) in pdfs.withIndex()) {
            if (ConvertState.cancelRequested) break
            ConvertState.update {
                it.copy(
                    fileIndex = index + 1, fileCount = pdfs.size, fileName = pdf.name,
                    page = 0, pageCount = 0, status = "Opening ${pdf.name}…",
                )
            }
            try {
                convertOne(pdf, outputRootId, outputRootUri)
            } catch (t: Throwable) {
                // Keep going with the other files; report this one at the end.
                val reason = if (t is OutOfMemoryError) "ran out of memory (try a smaller page size)" else (t.message ?: t.javaClass.simpleName)
                ConvertState.update { it.copy(errors = it.errors + "${pdf.name}: $reason") }
            }
        }

        val cancelled = ConvertState.cancelRequested
        ConvertState.update {
            val errorNote = if (it.errors.isEmpty()) "" else " ${it.errors.size} file(s) had problems — see below."
            it.copy(
                running = false,
                finished = true,
                status = (if (cancelled) "Stopped. Press Start again to pick up where it left off." else "Done.") + errorNote,
            )
        }
    }

    private fun convertOne(pdf: Doc, outputRootId: String, outputRootUri: Uri) {
        val folderName = sanitize(pdf.name.substringBeforeLast('.'))
        val dirUri = findOrCreateDir(outputRootId, outputRootUri, folderName)
        val dirId = DocumentsContract.getDocumentId(dirUri)
        val existing = listChildren(outputTree, dirId).filter { !it.isDir }.associateBy { it.name }

        val pfd = resolver.openFileDescriptor(pdf.uri, "r")
            ?: throw IOException("could not open the file")

        pfd.use {
            PdfRenderer(pfd).use { renderer ->
                val pageCount = renderer.pageCount
                val donePages = (0 until pageCount).filter { (existing[pageName(it)]?.size ?: 0L) > 0L }
                val redoPage = donePages.maxOrNull()

                for (p in 0 until pageCount) {
                    if (ConvertState.cancelRequested) return
                    ConvertState.update {
                        it.copy(page = p + 1, pageCount = pageCount, status = "Converting ${pdf.name}")
                    }

                    val name = pageName(p)
                    val old = existing[name]
                    if (old != null && old.size > 0 && p != redoPage) {
                        ConvertState.update { it.copy(pagesSkipped = it.pagesSkipped + 1) }
                        continue
                    }

                    val bitmap = renderPage(renderer, p)
                    try {
                        writeImage(bitmap, dirUri, name, old)
                    } finally {
                        bitmap.recycle()
                    }
                    ConvertState.update { it.copy(pagesWritten = it.pagesWritten + 1) }
                    onPageDone()
                }
            }
        }
    }

    private fun renderPage(renderer: PdfRenderer, index: Int): Bitmap {
        renderer.openPage(index).use { page ->
            val pageW = max(1, page.width).toFloat()
            val pageH = max(1, page.height).toFloat()

            // Scale so the longest side matches the chosen size…
            val scale = longSidePx / max(pageW, pageH)
            var w = pageW * scale
            var h = pageH * scale

            // …but never allocate a huge bitmap (~25 MP, ~100 MB) on a phone.
            val maxPixels = 25_000_000f
            if (w * h > maxPixels) {
                val shrink = sqrt(maxPixels / (w * h))
                w *= shrink
                h *= shrink
            }

            val bitmap = Bitmap.createBitmap(max(1, w.roundToInt()), max(1, h.roundToInt()), Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE) // PDFs have transparent backgrounds
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            return bitmap
        }
    }

    private fun writeImage(bitmap: Bitmap, dirUri: Uri, name: String, old: Doc?) {
        // Overwrite an existing file in place when possible; otherwise create a new one.
        if (old != null) {
            val overwritten = try {
                resolver.openOutputStream(old.uri, "wt")?.use { compress(bitmap, it) } != null
            } catch (e: Exception) {
                false
            }
            if (overwritten) return
            try {
                DocumentsContract.deleteDocument(resolver, old.uri)
            } catch (_: Exception) {
            }
        }

        val target = DocumentsContract.createDocument(resolver, dirUri, format.mime, name)
            ?: throw IOException("could not create $name in the output folder")
        val stream = resolver.openOutputStream(target, "w")
            ?: throw IOException("could not write $name")
        stream.use { compress(bitmap, it) }
    }

    private fun compress(bitmap: Bitmap, out: java.io.OutputStream) {
        BufferedOutputStream(out, 1 shl 16).use { buffered ->
            if (!bitmap.compress(format.compress, format.quality, buffered)) {
                throw IOException("could not encode image")
            }
        }
    }

    private fun pageName(index: Int) = "page_%04d.%s".format(index + 1, format.ext)

    private fun findOrCreateDir(parentId: String, parentUri: Uri, name: String): Uri {
        listChildren(outputTree, parentId).firstOrNull { it.isDir && it.name == name }?.let { return it.uri }
        return DocumentsContract.createDocument(resolver, parentUri, Document.MIME_TYPE_DIR, name)
            ?: throw IOException("could not create folder \"$name\" in the output folder")
    }

    private fun listChildren(tree: Uri, parentId: String): List<Doc> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
        )
        val result = mutableListOf<Doc>()
        resolver.query(childrenUri, columns, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                result += Doc(
                    uri = DocumentsContract.buildDocumentUriUsingTree(tree, id),
                    id = id,
                    name = c.getString(1) ?: id,
                    mime = c.getString(2) ?: "",
                    size = if (c.isNull(3)) 0L else c.getLong(3),
                )
            }
        }
        return result
    }

    private fun sanitize(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim().ifEmpty { "pdf" }
}
