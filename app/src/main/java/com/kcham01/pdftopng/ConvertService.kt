package com.kcham01.pdftopng

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock

/**
 * Runs the conversion as a foreground service so it keeps going with the screen off
 * or while you use other apps.
 */
class ConvertService : Service() {

    companion object {
        const val ACTION_START = "com.kcham01.pdftopng.START"
        const val ACTION_STOP = "com.kcham01.pdftopng.STOP"
        const val EXTRA_INPUT = "input"
        const val EXTRA_OUTPUT = "output"
        const val EXTRA_FORMAT = "format"
        const val EXTRA_LONG_SIDE = "longSide"

        private const val CHANNEL_ID = "convert"
        private const val PROGRESS_ID = 1
        private const val DONE_ID = 2

        fun start(context: Context, input: Uri, output: Uri, format: Converter.ImageFormat, longSide: Int) {
            val intent = Intent(context, ConvertService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_INPUT, input.toString())
                .putExtra(EXTRA_OUTPUT, output.toString())
                .putExtra(EXTRA_FORMAT, format.name)
                .putExtra(EXTRA_LONG_SIDE, longSide)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            ConvertState.cancelRequested = true
            context.startService(Intent(context, ConvertService::class.java).setAction(ACTION_STOP))
        }
    }

    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotify = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            ConvertState.cancelRequested = true
            ConvertState.update { if (it.running) it.copy(status = "Stopping after this page…") else it }
            if (worker?.isAlive != true) stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        // Must call startForeground promptly after startForegroundService, even if we bail.
        goForeground(buildProgress("Starting…", 0, 0))

        if (worker?.isAlive == true) return START_NOT_STICKY

        val input = intent?.getStringExtra(EXTRA_INPUT)?.let(Uri::parse)
        val output = intent?.getStringExtra(EXTRA_OUTPUT)?.let(Uri::parse)
        val format = intent?.getStringExtra(EXTRA_FORMAT)
            ?.let { runCatching { Converter.ImageFormat.valueOf(it) }.getOrNull() }
            ?: Converter.ImageFormat.PNG
        val longSide = intent?.getIntExtra(EXTRA_LONG_SIDE, 2400) ?: 2400

        if (input == null || output == null) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        ConvertState.cancelRequested = false
        acquireWakeLock()

        worker = Thread({
            try {
                Converter(contentResolver, input, output, format, longSide) { maybeUpdateNotification() }.run()
            } catch (t: Throwable) {
                ConvertState.update {
                    it.copy(running = false, finished = true, status = "Stopped with an error: ${t.message ?: t.javaClass.simpleName}")
                }
            } finally {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                showDoneNotification()
                stopSelf()
            }
        }, "pdf-convert").apply { start() }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        ConvertState.cancelRequested = true
        releaseWakeLock()
        super.onDestroy()
    }

    private fun goForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(PROGRESS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(PROGRESS_ID, notification)
        }
    }

    private fun maybeUpdateNotification() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastNotify < 1000) return
        lastNotify = now
        val s = ConvertState.snapshot
        val text = "File ${s.fileIndex}/${s.fileCount} · page ${s.page}/${s.pageCount}"
        notificationManager().notify(PROGRESS_ID, buildProgress(text, s.page, s.pageCount))
    }

    private fun buildProgress(text: String, progress: Int, max: Int): Notification {
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, ConvertService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(getString(R.string.converting))
            .setContentText(text)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(max, progress, max == 0)
            .addAction(Notification.Action.Builder(null, getString(R.string.stop), stopIntent).build())
            .build()
    }

    private fun showDoneNotification() {
        val s = ConvertState.snapshot
        val text = "${s.pagesWritten} pages saved" +
            (if (s.pagesSkipped > 0) ", ${s.pagesSkipped} already done" else "") +
            (if (s.errors.isNotEmpty()) ", ${s.errors.size} problem file(s)" else "")
        val n = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(if (ConvertState.cancelRequested) getString(R.string.stopped) else getString(R.string.finished))
            .setContentText(text)
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
            .build()
        notificationManager().notify(DONE_ID, n)
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, getString(R.string.channel_name), NotificationManager.IMPORTANCE_LOW)
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager() = getSystemService(NotificationManager::class.java)

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pdftopng:convert").apply {
            setReferenceCounted(false)
            acquire(12 * 60 * 60 * 1000L) // safety cap: 12 hours
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }
}
