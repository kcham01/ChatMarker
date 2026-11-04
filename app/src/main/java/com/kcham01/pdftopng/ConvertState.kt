package com.kcham01.pdftopng

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet

/** Shared progress between the background service and the screen. */
object ConvertState {

    data class Snapshot(
        val running: Boolean = false,
        val finished: Boolean = false,
        val status: String = "Pick an input and output folder, then press Start.",
        val fileIndex: Int = 0,
        val fileCount: Int = 0,
        val fileName: String = "",
        val page: Int = 0,
        val pageCount: Int = 0,
        val pagesWritten: Int = 0,
        val pagesSkipped: Int = 0,
        val errors: List<String> = emptyList(),
    )

    @Volatile
    var cancelRequested: Boolean = false

    @Volatile
    var snapshot: Snapshot = Snapshot()
        private set

    private val listeners = CopyOnWriteArraySet<(Snapshot) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun update(change: (Snapshot) -> Snapshot) {
        val next = synchronized(this) {
            snapshot = change(snapshot)
            snapshot
        }
        main.post { listeners.forEach { it(next) } }
    }

    fun addListener(listener: (Snapshot) -> Unit) {
        listeners.add(listener)
        listener(snapshot)
    }

    fun removeListener(listener: (Snapshot) -> Unit) {
        listeners.remove(listener)
    }
}
