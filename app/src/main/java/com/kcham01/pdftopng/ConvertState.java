package com.kcham01.pdftopng;

import android.os.Handler;
import android.os.Looper;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArraySet;

/** Shared progress between the background service and the screen. */
public final class ConvertState {

    public interface Listener {
        void onChange(Snapshot s);
    }

    /** Immutable progress snapshot. */
    public static final class Snapshot {
        public final boolean running;
        public final boolean finished;
        public final String status;
        public final int fileIndex;
        public final int fileCount;
        public final String fileName;
        public final int page;
        public final int pageCount;
        public final int pagesWritten;
        public final int pagesSkipped;
        public final List<String> errors;

        Snapshot(boolean running, boolean finished, String status, int fileIndex, int fileCount,
                 String fileName, int page, int pageCount, int pagesWritten, int pagesSkipped,
                 List<String> errors) {
            this.running = running;
            this.finished = finished;
            this.status = status;
            this.fileIndex = fileIndex;
            this.fileCount = fileCount;
            this.fileName = fileName;
            this.page = page;
            this.pageCount = pageCount;
            this.pagesWritten = pagesWritten;
            this.pagesSkipped = pagesSkipped;
            this.errors = Collections.unmodifiableList(errors);
        }

        static Snapshot initial() {
            return new Snapshot(false, false, "Pick an input and output folder, then press Start.",
                    0, 0, "", 0, 0, 0, 0, new ArrayList<String>());
        }
    }

    /** Mutable builder used to change one or two fields at a time. */
    public static final class Edit {
        public boolean running, finished;
        public String status, fileName;
        public int fileIndex, fileCount, page, pageCount, pagesWritten, pagesSkipped;
        public List<String> errors;

        Edit(Snapshot s) {
            running = s.running; finished = s.finished; status = s.status;
            fileIndex = s.fileIndex; fileCount = s.fileCount; fileName = s.fileName;
            page = s.page; pageCount = s.pageCount;
            pagesWritten = s.pagesWritten; pagesSkipped = s.pagesSkipped;
            errors = new ArrayList<>(s.errors);
        }

        Snapshot build() {
            return new Snapshot(running, finished, status, fileIndex, fileCount, fileName,
                    page, pageCount, pagesWritten, pagesSkipped, errors);
        }
    }

    public interface Change {
        void apply(Edit e);
    }

    public static volatile boolean cancelRequested = false;

    private static volatile Snapshot snapshot = Snapshot.initial();
    private static final CopyOnWriteArraySet<Listener> listeners = new CopyOnWriteArraySet<>();
    private static final Handler main = new Handler(Looper.getMainLooper());

    private ConvertState() {
    }

    public static Snapshot get() {
        return snapshot;
    }

    public static void reset() {
        update(new Change() {
            @Override
            public void apply(Edit e) {
                Snapshot fresh = Snapshot.initial();
                e.running = true; e.finished = false; e.status = "Looking for PDFs…";
                e.fileIndex = 0; e.fileCount = 0; e.fileName = fresh.fileName;
                e.page = 0; e.pageCount = 0; e.pagesWritten = 0; e.pagesSkipped = 0;
                e.errors = new ArrayList<>();
            }
        });
    }

    public static void update(Change change) {
        final Snapshot next;
        synchronized (ConvertState.class) {
            Edit e = new Edit(snapshot);
            change.apply(e);
            snapshot = e.build();
            next = snapshot;
        }
        main.post(new Runnable() {
            @Override
            public void run() {
                for (Listener l : listeners) l.onChange(next);
            }
        });
    }

    public static void addListener(Listener l) {
        listeners.add(l);
        l.onChange(snapshot);
    }

    public static void removeListener(Listener l) {
        listeners.remove(l);
    }
}
