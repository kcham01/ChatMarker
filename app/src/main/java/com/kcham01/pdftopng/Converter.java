package com.kcham01.pdftopng;

import android.content.ContentResolver;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Renders every page of every PDF directly inside the input folder to an image file.
 * Output layout: <output>/<pdf name>/page_0001.png, page_0002.png, ...
 *
 * Re-running the same job resumes: pages that already exist are skipped, except the
 * last one found for each PDF, which is re-rendered in case it was cut off mid-write.
 */
public final class Converter {

    public enum ImageFormat {
        PNG("png", "image/png", Bitmap.CompressFormat.PNG, 100),
        JPEG("jpg", "image/jpeg", Bitmap.CompressFormat.JPEG, 90);

        final String ext;
        final String mime;
        final Bitmap.CompressFormat compress;
        final int quality;

        ImageFormat(String ext, String mime, Bitmap.CompressFormat compress, int quality) {
            this.ext = ext;
            this.mime = mime;
            this.compress = compress;
            this.quality = quality;
        }
    }

    public interface PageListener {
        void onPageDone();
    }

    private static final class Doc {
        final Uri uri;
        final String name;
        final String mime;
        final long size;

        Doc(Uri uri, String name, String mime, long size) {
            this.uri = uri;
            this.name = name;
            this.mime = mime;
            this.size = size;
        }

        boolean isDir() {
            return Document.MIME_TYPE_DIR.equals(mime);
        }
    }

    /** Thrown internally to stop work when the user presses Stop. */
    private static final class Cancelled extends Exception {
    }

    private static final float MAX_PIXELS = 25_000_000f; // ~100 MB bitmap

    private final ContentResolver resolver;
    private final Uri inputTree;
    private final Uri outputTree;
    private final ImageFormat format;
    private final int longSidePx;
    private final PageListener listener;

    public Converter(ContentResolver resolver, Uri inputTree, Uri outputTree,
                     ImageFormat format, int longSidePx, PageListener listener) {
        this.resolver = resolver;
        this.inputTree = inputTree;
        this.outputTree = outputTree;
        this.format = format;
        this.longSidePx = longSidePx;
        this.listener = listener;
    }

    public void run() {
        ConvertState.reset();

        String inputRootId = DocumentsContract.getTreeDocumentId(inputTree);
        List<Doc> pdfs = new ArrayList<>();
        for (Doc d : listChildren(inputTree, inputRootId)) {
            if (!d.isDir() && ("application/pdf".equals(d.mime)
                    || d.name.toLowerCase(Locale.ROOT).endsWith(".pdf"))) {
                pdfs.add(d);
            }
        }
        Collections.sort(pdfs, new Comparator<Doc>() {
            @Override
            public int compare(Doc a, Doc b) {
                return a.name.compareToIgnoreCase(b.name);
            }
        });

        if (pdfs.isEmpty()) {
            ConvertState.update(new ConvertState.Change() {
                @Override
                public void apply(ConvertState.Edit e) {
                    e.running = false;
                    e.finished = true;
                    e.status = "No PDF files found directly inside the input folder.";
                }
            });
            return;
        }

        String outputRootId = DocumentsContract.getTreeDocumentId(outputTree);
        Uri outputRootUri = DocumentsContract.buildDocumentUriUsingTree(outputTree, outputRootId);

        final int total = pdfs.size();
        for (int i = 0; i < total; i++) {
            if (ConvertState.cancelRequested) break;
            final Doc pdf = pdfs.get(i);
            final int index = i + 1;
            ConvertState.update(new ConvertState.Change() {
                @Override
                public void apply(ConvertState.Edit e) {
                    e.fileIndex = index;
                    e.fileCount = total;
                    e.fileName = pdf.name;
                    e.page = 0;
                    e.pageCount = 0;
                    e.status = "Opening " + pdf.name + "…";
                }
            });
            try {
                convertOne(pdf, outputRootId, outputRootUri);
            } catch (Cancelled c) {
                break;
            } catch (Throwable t) {
                // Keep going with the other files; report this one at the end.
                final String reason = (t instanceof OutOfMemoryError)
                        ? "ran out of memory (try a smaller page size)"
                        : (t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName());
                ConvertState.update(new ConvertState.Change() {
                    @Override
                    public void apply(ConvertState.Edit e) {
                        e.errors.add(pdf.name + ": " + reason);
                    }
                });
            }
        }

        final boolean cancelled = ConvertState.cancelRequested;
        ConvertState.update(new ConvertState.Change() {
            @Override
            public void apply(ConvertState.Edit e) {
                String errorNote = e.errors.isEmpty() ? ""
                        : " " + e.errors.size() + " file(s) had problems — see below.";
                e.running = false;
                e.finished = true;
                e.status = (cancelled
                        ? "Stopped. Press Start again to pick up where it left off."
                        : "Done.") + errorNote;
            }
        });
    }

    private void convertOne(final Doc pdf, String outputRootId, Uri outputRootUri) throws Exception {
        String folderName = sanitize(stripExtension(pdf.name));
        Uri dirUri = findOrCreateDir(outputRootId, outputRootUri, folderName);
        String dirId = DocumentsContract.getDocumentId(dirUri);

        Map<String, Doc> existing = new HashMap<>();
        for (Doc d : listChildren(outputTree, dirId)) {
            if (!d.isDir()) existing.put(d.name, d);
        }

        ParcelFileDescriptor pfd = resolver.openFileDescriptor(pdf.uri, "r");
        if (pfd == null) throw new IOException("could not open the file");

        try {
            PdfRenderer renderer = new PdfRenderer(pfd);
            try {
                final int pageCount = renderer.getPageCount();

                int redoPage = -1;
                for (int p = 0; p < pageCount; p++) {
                    Doc d = existing.get(pageName(p));
                    if (d != null && d.size > 0) redoPage = p;
                }

                for (int p = 0; p < pageCount; p++) {
                    if (ConvertState.cancelRequested) throw new Cancelled();
                    final int pageNum = p + 1;
                    ConvertState.update(new ConvertState.Change() {
                        @Override
                        public void apply(ConvertState.Edit e) {
                            e.page = pageNum;
                            e.pageCount = pageCount;
                            e.status = "Converting " + pdf.name;
                        }
                    });

                    String name = pageName(p);
                    Doc old = existing.get(name);
                    if (old != null && old.size > 0 && p != redoPage) {
                        ConvertState.update(new ConvertState.Change() {
                            @Override
                            public void apply(ConvertState.Edit e) {
                                e.pagesSkipped++;
                            }
                        });
                        continue;
                    }

                    Bitmap bitmap = renderPage(renderer, p);
                    try {
                        writeImage(bitmap, dirUri, name, old);
                    } finally {
                        bitmap.recycle();
                    }
                    ConvertState.update(new ConvertState.Change() {
                        @Override
                        public void apply(ConvertState.Edit e) {
                            e.pagesWritten++;
                        }
                    });
                    listener.onPageDone();
                }
            } finally {
                renderer.close();
            }
        } finally {
            try {
                pfd.close();
            } catch (IOException ignored) {
            }
        }
    }

    private Bitmap renderPage(PdfRenderer renderer, int index) {
        PdfRenderer.Page page = renderer.openPage(index);
        try {
            float pageW = Math.max(1, page.getWidth());
            float pageH = Math.max(1, page.getHeight());

            // Scale so the longest side matches the chosen size…
            float scale = longSidePx / Math.max(pageW, pageH);
            float w = pageW * scale;
            float h = pageH * scale;

            // …but never allocate a huge bitmap on a phone.
            if (w * h > MAX_PIXELS) {
                float shrink = (float) Math.sqrt(MAX_PIXELS / (w * h));
                w *= shrink;
                h *= shrink;
            }

            Bitmap bitmap = Bitmap.createBitmap(Math.max(1, Math.round(w)), Math.max(1, Math.round(h)),
                    Bitmap.Config.ARGB_8888);
            bitmap.eraseColor(Color.WHITE); // PDFs have transparent backgrounds
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
            return bitmap;
        } finally {
            page.close();
        }
    }

    private void writeImage(Bitmap bitmap, Uri dirUri, String name, Doc old) throws IOException {
        // Overwrite an existing file in place when possible; otherwise create a new one.
        if (old != null) {
            try {
                OutputStream os = resolver.openOutputStream(old.uri, "wt");
                if (os != null) {
                    compress(bitmap, os);
                    return;
                }
            } catch (Exception ignored) {
            }
            try {
                DocumentsContract.deleteDocument(resolver, old.uri);
            } catch (Exception ignored) {
            }
        }

        Uri target = DocumentsContract.createDocument(resolver, dirUri, format.mime, name);
        if (target == null) throw new IOException("could not create " + name + " in the output folder");
        OutputStream os = resolver.openOutputStream(target, "w");
        if (os == null) throw new IOException("could not write " + name);
        compress(bitmap, os);
    }

    private void compress(Bitmap bitmap, OutputStream out) throws IOException {
        BufferedOutputStream buffered = new BufferedOutputStream(out, 1 << 16);
        try {
            if (!bitmap.compress(format.compress, format.quality, buffered)) {
                throw new IOException("could not encode image");
            }
        } finally {
            buffered.close();
        }
    }

    private String pageName(int index) {
        return String.format(Locale.ROOT, "page_%04d.%s", index + 1, format.ext);
    }

    private Uri findOrCreateDir(String parentId, Uri parentUri, String name) throws IOException {
        for (Doc d : listChildren(outputTree, parentId)) {
            if (d.isDir() && d.name.equals(name)) return d.uri;
        }
        Uri created = DocumentsContract.createDocument(resolver, parentUri, Document.MIME_TYPE_DIR, name);
        if (created == null) throw new IOException("could not create folder \"" + name + "\" in the output folder");
        return created;
    }

    private List<Doc> listChildren(Uri tree, String parentId) {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId);
        String[] columns = {
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE,
        };
        List<Doc> result = new ArrayList<>();
        Cursor c = resolver.query(childrenUri, columns, null, null, null);
        if (c == null) return result;
        try {
            while (c.moveToNext()) {
                String id = c.getString(0);
                if (id == null) continue;
                String name = c.getString(1);
                String mime = c.getString(2);
                long size = c.isNull(3) ? 0L : c.getLong(3);
                result.add(new Doc(DocumentsContract.buildDocumentUriUsingTree(tree, id),
                        name != null ? name : id, mime != null ? mime : "", size));
            }
        } finally {
            c.close();
        }
        return result;
    }

    private static String stripExtension(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static String sanitize(String name) {
        String cleaned = name.replaceAll("[\\\\/:*?\"<>|]", "_").trim();
        return cleaned.isEmpty() ? "pdf" : cleaned;
    }
}
