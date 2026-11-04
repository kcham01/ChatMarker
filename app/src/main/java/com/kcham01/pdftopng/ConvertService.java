package com.kcham01.pdftopng;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;

/**
 * Runs the conversion as a foreground service so it keeps going with the screen off
 * or while you use other apps.
 */
public final class ConvertService extends Service {

    static final String ACTION_START = "com.kcham01.pdftopng.START";
    static final String ACTION_STOP = "com.kcham01.pdftopng.STOP";
    private static final String EXTRA_INPUT = "input";
    private static final String EXTRA_OUTPUT = "output";
    private static final String EXTRA_FORMAT = "format";
    private static final String EXTRA_LONG_SIDE = "longSide";

    private static final String CHANNEL_ID = "convert";
    private static final int PROGRESS_ID = 1;
    private static final int DONE_ID = 2;

    private Thread worker;
    private PowerManager.WakeLock wakeLock;
    private long lastNotify = 0L;

    public static void start(Context context, Uri input, Uri output, Converter.ImageFormat format, int longSide) {
        Intent intent = new Intent(context, ConvertService.class)
                .setAction(ACTION_START)
                .putExtra(EXTRA_INPUT, input.toString())
                .putExtra(EXTRA_OUTPUT, output.toString())
                .putExtra(EXTRA_FORMAT, format.name())
                .putExtra(EXTRA_LONG_SIDE, longSide);
        context.startForegroundService(intent);
    }

    public static void stop(Context context) {
        ConvertState.cancelRequested = true;
        context.startService(new Intent(context, ConvertService.class).setAction(ACTION_STOP));
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            ConvertState.cancelRequested = true;
            ConvertState.update(new ConvertState.Change() {
                @Override
                public void apply(ConvertState.Edit e) {
                    if (e.running) e.status = "Stopping after this page…";
                }
            });
            if (worker == null || !worker.isAlive()) stopSelf();
            return START_NOT_STICKY;
        }

        createChannel();
        // Must call startForeground promptly after startForegroundService, even if we bail.
        goForeground(buildProgress("Starting…", 0, 0));

        if (worker != null && worker.isAlive()) return START_NOT_STICKY;

        String in = intent != null ? intent.getStringExtra(EXTRA_INPUT) : null;
        String out = intent != null ? intent.getStringExtra(EXTRA_OUTPUT) : null;
        if (in == null || out == null) {
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        final Uri input = Uri.parse(in);
        final Uri output = Uri.parse(out);

        Converter.ImageFormat parsed = Converter.ImageFormat.PNG;
        try {
            String f = intent.getStringExtra(EXTRA_FORMAT);
            if (f != null) parsed = Converter.ImageFormat.valueOf(f);
        } catch (IllegalArgumentException ignored) {
        }
        final Converter.ImageFormat format = parsed;
        final int longSide = intent.getIntExtra(EXTRA_LONG_SIDE, 2400);

        ConvertState.cancelRequested = false;
        acquireWakeLock();

        worker = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    new Converter(getContentResolver(), input, output, format, longSide,
                            new Converter.PageListener() {
                                @Override
                                public void onPageDone() {
                                    maybeUpdateNotification();
                                }
                            }).run();
                } catch (final Throwable t) {
                    ConvertState.update(new ConvertState.Change() {
                        @Override
                        public void apply(ConvertState.Edit e) {
                            e.running = false;
                            e.finished = true;
                            e.status = "Stopped with an error: "
                                    + (t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName());
                        }
                    });
                } finally {
                    releaseWakeLock();
                    stopForeground(STOP_FOREGROUND_REMOVE);
                    showDoneNotification();
                    stopSelf();
                }
            }
        }, "pdf-convert");
        worker.start();

        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        ConvertState.cancelRequested = true;
        releaseWakeLock();
        super.onDestroy();
    }

    private void goForeground(Notification notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(PROGRESS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(PROGRESS_ID, notification);
        }
    }

    private void maybeUpdateNotification() {
        long now = SystemClock.elapsedRealtime();
        if (now - lastNotify < 1000) return;
        lastNotify = now;
        ConvertState.Snapshot s = ConvertState.get();
        String text = "File " + s.fileIndex + "/" + s.fileCount + " · page " + s.page + "/" + s.pageCount;
        notificationManager().notify(PROGRESS_ID, buildProgress(text, s.page, s.pageCount));
    }

    private Notification buildProgress(String text, int progress, int max) {
        PendingIntent stopIntent = PendingIntent.getService(this, 1,
                new Intent(this, ConvertService.class).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle(getString(R.string.converting))
                .setContentText(text)
                .setContentIntent(openAppIntent())
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setProgress(max, progress, max == 0)
                .addAction(new Notification.Action.Builder(null, getString(R.string.stop), stopIntent).build())
                .build();
    }

    private void showDoneNotification() {
        ConvertState.Snapshot s = ConvertState.get();
        String text = s.pagesWritten + " pages saved"
                + (s.pagesSkipped > 0 ? ", " + s.pagesSkipped + " already done" : "")
                + (!s.errors.isEmpty() ? ", " + s.errors.size() + " problem file(s)" : "");
        Notification n = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle(getString(ConvertState.cancelRequested ? R.string.stopped : R.string.finished))
                .setContentText(text)
                .setContentIntent(openAppIntent())
                .setAutoCancel(true)
                .build();
        notificationManager().notify(DONE_ID, n);
    }

    private PendingIntent openAppIntent() {
        return PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private void createChannel() {
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                getString(R.string.channel_name), NotificationManager.IMPORTANCE_LOW);
        notificationManager().createNotificationChannel(channel);
    }

    private NotificationManager notificationManager() {
        return getSystemService(NotificationManager.class);
    }

    private void acquireWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) return;
        PowerManager pm = getSystemService(PowerManager.class);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pdftopng:convert");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire(12L * 60 * 60 * 1000); // safety cap: 12 hours
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }
}
