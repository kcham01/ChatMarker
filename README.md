# PDF to Images

An Android app that converts every page of every PDF in a folder into images, in bulk.

- Pick an **input folder** of PDFs and an **output folder** for the images.
- Choose **PNG** (best quality) or **JPEG** (much smaller), and the page size (1600 / 2400 / 3200 px on the longest side).
- Each PDF gets its own subfolder: `page_0001.png`, `page_0002.png`, …
- Runs in the background with the screen off, with progress and a Stop button in the notification.
- **Resumable:** press Start again with the same folders and it skips pages that are already done.

## Install

Grab the latest `PDF-to-Images.apk` from [Releases](../../releases/latest) on your phone and open it.
You may need to allow installs from your browser or file manager the first time.

Each build is signed with a fresh debug key, so to install a newer build you may need to uninstall the old one first.

## Notes

- The PDFs need to be stored on the phone (e.g. Downloads). Files that only live in Google Drive can't be read directly.
- Only PDFs directly inside the input folder are converted (not subfolders).
- Very large pages are capped at ~25 megapixels to avoid running out of memory.

## Build

Every push to `main` builds the APK with GitHub Actions and publishes it as a release.
Locally: `gradle :app:assembleDebug` (JDK 17, Android SDK 34).
