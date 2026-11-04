package com.kcham01.pdftopng;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.view.View;
import android.widget.Button;
import android.widget.ProgressBar;
import android.widget.RadioGroup;
import android.widget.TextView;
import android.widget.Toast;

public final class MainActivity extends Activity {

    private static final int REQ_INPUT = 10;
    private static final int REQ_OUTPUT = 11;
    private static final int REQ_NOTIFY = 12;

    private static final String PREF_INPUT = "input";
    private static final String PREF_OUTPUT = "output";
    private static final String PREF_FORMAT = "format";
    private static final String PREF_SIZE = "size";

    private SharedPreferences prefs;
    private TextView inputLabel, outputLabel, statusText, fileText, countsText, errorsText;
    private RadioGroup formatGroup, sizeGroup;
    private Button startButton, stopButton;
    private ProgressBar progress;

    private final ConvertState.Listener listener = new ConvertState.Listener() {
        @Override
        public void onChange(ConvertState.Snapshot s) {
            render(s);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        prefs = getSharedPreferences("settings", MODE_PRIVATE);

        inputLabel = findViewById(R.id.inputLabel);
        outputLabel = findViewById(R.id.outputLabel);
        formatGroup = findViewById(R.id.formatGroup);
        sizeGroup = findViewById(R.id.sizeGroup);
        startButton = findViewById(R.id.startButton);
        stopButton = findViewById(R.id.stopButton);
        statusText = findViewById(R.id.statusText);
        fileText = findViewById(R.id.fileText);
        countsText = findViewById(R.id.countsText);
        errorsText = findViewById(R.id.errorsText);
        progress = findViewById(R.id.progress);

        findViewById(R.id.pickInput).setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pickFolder(REQ_INPUT);
            }
        });
        findViewById(R.id.pickOutput).setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pickFolder(REQ_OUTPUT);
            }
        });
        startButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startConversion();
            }
        });
        stopButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                ConvertService.stop(MainActivity.this);
            }
        });

        formatGroup.check("JPEG".equals(prefs.getString(PREF_FORMAT, "PNG")) ? R.id.formatJpeg : R.id.formatPng);
        int size = prefs.getInt(PREF_SIZE, 2400);
        sizeGroup.check(size == 1600 ? R.id.size1600 : size == 3200 ? R.id.size3200 : R.id.size2400);
        formatGroup.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(RadioGroup group, int checkedId) {
                prefs.edit().putString(PREF_FORMAT, selectedFormat().name()).apply();
            }
        });
        sizeGroup.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(RadioGroup group, int checkedId) {
                prefs.edit().putInt(PREF_SIZE, selectedSize()).apply();
            }
        });

        refreshFolderLabels();
    }

    @Override
    protected void onStart() {
        super.onStart();
        ConvertState.addListener(listener);
    }

    @Override
    protected void onStop() {
        ConvertState.removeListener(listener);
        super.onStop();
    }

    private void pickFolder(int request) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION
                        | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        startActivityForResult(intent, request);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        Uri uri = data != null ? data.getData() : null;
        if (resultCode != RESULT_OK || uri == null) return;

        int wanted = requestCode == REQ_OUTPUT
                ? Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                : Intent.FLAG_GRANT_READ_URI_PERMISSION;
        try {
            getContentResolver().takePersistableUriPermission(uri, wanted);
        } catch (SecurityException e) {
            Toast.makeText(this, R.string.permission_failed, Toast.LENGTH_LONG).show();
            return;
        }

        prefs.edit().putString(requestCode == REQ_INPUT ? PREF_INPUT : PREF_OUTPUT, uri.toString()).apply();
        refreshFolderLabels();
    }

    private void startConversion() {
        String in = prefs.getString(PREF_INPUT, null);
        String out = prefs.getString(PREF_OUTPUT, null);
        if (in == null || out == null) {
            Toast.makeText(this, R.string.pick_both, Toast.LENGTH_LONG).show();
            return;
        }

        // Ask once for notification permission so progress shows in the shade (Android 13+).
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                && !prefs.getBoolean("askedNotify", false)) {
            prefs.edit().putBoolean("askedNotify", true).apply();
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
            return; // continues in onRequestPermissionsResult
        }

        ConvertService.start(this, Uri.parse(in), Uri.parse(out), selectedFormat(), selectedSize());
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_NOTIFY) startConversion();
    }

    private Converter.ImageFormat selectedFormat() {
        return formatGroup.getCheckedRadioButtonId() == R.id.formatJpeg
                ? Converter.ImageFormat.JPEG : Converter.ImageFormat.PNG;
    }

    private int selectedSize() {
        int id = sizeGroup.getCheckedRadioButtonId();
        if (id == R.id.size1600) return 1600;
        if (id == R.id.size3200) return 3200;
        return 2400;
    }

    private void refreshFolderLabels() {
        String in = describe(prefs.getString(PREF_INPUT, null));
        String out = describe(prefs.getString(PREF_OUTPUT, null));
        inputLabel.setText(in != null ? in : getString(R.string.none_chosen));
        outputLabel.setText(out != null ? out : getString(R.string.none_chosen));
    }

    /** Turns "primary:Download/Trial Flash" into "Download/Trial Flash". */
    private String describe(String uriString) {
        if (uriString == null) return null;
        Uri uri = Uri.parse(uriString);
        try {
            String id = DocumentsContract.getTreeDocumentId(uri);
            int colon = id.indexOf(':');
            String path = colon >= 0 ? id.substring(colon + 1) : id;
            return path.isEmpty() ? getString(R.string.storage_root) : path;
        } catch (Exception e) {
            return uri.getLastPathSegment();
        }
    }

    private void render(ConvertState.Snapshot s) {
        statusText.setText(s.status);
        startButton.setEnabled(!s.running);
        stopButton.setEnabled(s.running);
        startButton.setText(s.finished && s.pagesSkipped + s.pagesWritten > 0
                ? R.string.start_again : R.string.start);
        for (int i = 0; i < formatGroup.getChildCount(); i++) formatGroup.getChildAt(i).setEnabled(!s.running);
        for (int i = 0; i < sizeGroup.getChildCount(); i++) sizeGroup.getChildAt(i).setEnabled(!s.running);

        if (s.fileCount > 0) {
            fileText.setVisibility(View.VISIBLE);
            fileText.setText(getString(R.string.file_progress, s.fileIndex, s.fileCount, s.fileName, s.page, s.pageCount));
            progress.setVisibility(View.VISIBLE);
            progress.setMax(Math.max(1, s.pageCount));
            progress.setProgress(s.page);
        } else {
            fileText.setVisibility(View.GONE);
            progress.setVisibility(View.GONE);
        }

        if (s.running || s.finished) {
            countsText.setVisibility(View.VISIBLE);
            countsText.setText(getString(R.string.counts, s.pagesWritten, s.pagesSkipped));
        } else {
            countsText.setVisibility(View.GONE);
        }

        if (s.errors.isEmpty()) {
            errorsText.setVisibility(View.GONE);
        } else {
            StringBuilder sb = new StringBuilder();
            for (String e : s.errors) {
                if (sb.length() > 0) sb.append('\n');
                sb.append("• ").append(e);
            }
            errorsText.setVisibility(View.VISIBLE);
            errorsText.setText(sb);
        }
    }
}
