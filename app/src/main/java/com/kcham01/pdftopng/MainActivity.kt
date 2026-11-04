package com.kcham01.pdftopng

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {

    companion object {
        private const val REQ_INPUT = 10
        private const val REQ_OUTPUT = 11
        private const val REQ_NOTIFY = 12

        private const val PREF_INPUT = "input"
        private const val PREF_OUTPUT = "output"
        private const val PREF_FORMAT = "format"
        private const val PREF_SIZE = "size"
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var inputLabel: TextView
    private lateinit var outputLabel: TextView
    private lateinit var formatGroup: RadioGroup
    private lateinit var sizeGroup: RadioGroup
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private lateinit var statusText: TextView
    private lateinit var fileText: TextView
    private lateinit var countsText: TextView
    private lateinit var errorsText: TextView
    private lateinit var progress: ProgressBar

    private val listener: (ConvertState.Snapshot) -> Unit = { render(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = getSharedPreferences("settings", MODE_PRIVATE)

        inputLabel = findViewById(R.id.inputLabel)
        outputLabel = findViewById(R.id.outputLabel)
        formatGroup = findViewById(R.id.formatGroup)
        sizeGroup = findViewById(R.id.sizeGroup)
        startButton = findViewById(R.id.startButton)
        stopButton = findViewById(R.id.stopButton)
        statusText = findViewById(R.id.statusText)
        fileText = findViewById(R.id.fileText)
        countsText = findViewById(R.id.countsText)
        errorsText = findViewById(R.id.errorsText)
        progress = findViewById(R.id.progress)

        findViewById<Button>(R.id.pickInput).setOnClickListener { pickFolder(REQ_INPUT) }
        findViewById<Button>(R.id.pickOutput).setOnClickListener { pickFolder(REQ_OUTPUT) }
        startButton.setOnClickListener { startConversion() }
        stopButton.setOnClickListener { ConvertService.stop(this) }

        formatGroup.check(if (prefs.getString(PREF_FORMAT, "PNG") == "JPEG") R.id.formatJpeg else R.id.formatPng)
        sizeGroup.check(
            when (prefs.getInt(PREF_SIZE, 2400)) {
                1600 -> R.id.size1600
                3200 -> R.id.size3200
                else -> R.id.size2400
            }
        )
        formatGroup.setOnCheckedChangeListener { _, _ -> prefs.edit().putString(PREF_FORMAT, selectedFormat().name).apply() }
        sizeGroup.setOnCheckedChangeListener { _, _ -> prefs.edit().putInt(PREF_SIZE, selectedSize()).apply() }

        refreshFolderLabels()
    }

    override fun onStart() {
        super.onStart()
        ConvertState.addListener(listener)
    }

    override fun onStop() {
        ConvertState.removeListener(listener)
        super.onStop()
    }

    private fun pickFolder(request: Int) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        startActivityForResult(intent, request)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) return

        val wanted = if (requestCode == REQ_OUTPUT) {
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        } else {
            Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        try {
            contentResolver.takePersistableUriPermission(uri, wanted)
        } catch (e: SecurityException) {
            Toast.makeText(this, getString(R.string.permission_failed), Toast.LENGTH_LONG).show()
            return
        }

        val key = if (requestCode == REQ_INPUT) PREF_INPUT else PREF_OUTPUT
        prefs.edit().putString(key, uri.toString()).apply()
        refreshFolderLabels()
    }

    private fun startConversion() {
        val input = prefs.getString(PREF_INPUT, null)?.let(Uri::parse)
        val output = prefs.getString(PREF_OUTPUT, null)?.let(Uri::parse)
        if (input == null || output == null) {
            Toast.makeText(this, getString(R.string.pick_both), Toast.LENGTH_LONG).show()
            return
        }

        // Ask once for notification permission so progress shows in the shade (Android 13+).
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("askedNotify", false)
        ) {
            prefs.edit().putBoolean("askedNotify", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
            return // start continues in onRequestPermissionsResult
        }

        ConvertService.start(this, input, output, selectedFormat(), selectedSize())
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY) startConversion()
    }

    private fun selectedFormat() =
        if (formatGroup.checkedRadioButtonId == R.id.formatJpeg) Converter.ImageFormat.JPEG else Converter.ImageFormat.PNG

    private fun selectedSize() = when (sizeGroup.checkedRadioButtonId) {
        R.id.size1600 -> 1600
        R.id.size3200 -> 3200
        else -> 2400
    }

    private fun refreshFolderLabels() {
        inputLabel.text = describe(prefs.getString(PREF_INPUT, null)) ?: getString(R.string.none_chosen)
        outputLabel.text = describe(prefs.getString(PREF_OUTPUT, null)) ?: getString(R.string.none_chosen)
    }

    /** Turns "primary:Download/Trial Flash" into "Download/Trial Flash". */
    private fun describe(uriString: String?): String? {
        val uri = uriString?.let(Uri::parse) ?: return null
        return try {
            val id = DocumentsContract.getTreeDocumentId(uri)
            val path = id.substringAfter(':', id)
            path.ifEmpty { getString(R.string.storage_root) }
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }

    private fun render(s: ConvertState.Snapshot) {
        statusText.text = s.status
        startButton.isEnabled = !s.running
        stopButton.isEnabled = s.running
        startButton.text = getString(if (s.finished && s.pagesSkipped + s.pagesWritten > 0) R.string.start_again else R.string.start)
        formatGroup.isEnabled = !s.running
        for (i in 0 until formatGroup.childCount) formatGroup.getChildAt(i).isEnabled = !s.running
        for (i in 0 until sizeGroup.childCount) sizeGroup.getChildAt(i).isEnabled = !s.running

        if (s.fileCount > 0) {
            fileText.visibility = View.VISIBLE
            fileText.text = getString(R.string.file_progress, s.fileIndex, s.fileCount, s.fileName, s.page, s.pageCount)
            progress.visibility = View.VISIBLE
            progress.max = maxOf(1, s.pageCount)
            progress.progress = s.page
        } else {
            fileText.visibility = View.GONE
            progress.visibility = View.GONE
        }

        if (s.running || s.finished) {
            countsText.visibility = View.VISIBLE
            countsText.text = getString(R.string.counts, s.pagesWritten, s.pagesSkipped)
        } else {
            countsText.visibility = View.GONE
        }

        if (s.errors.isEmpty()) {
            errorsText.visibility = View.GONE
        } else {
            errorsText.visibility = View.VISIBLE
            errorsText.text = s.errors.joinToString("\n") { "• $it" }
        }
    }
}
