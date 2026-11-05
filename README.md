# Kiln

Drop a file in, get the version you need out. A free Mac app for photos, videos, music, PDFs and Word files.
Everything happens on your Mac. Nothing is uploaded. Your original is never changed: Kiln always saves a new copy
next to it (for example `photo (smaller).jpg`).

## What it does

| Drop in | You can |
| --- | --- |
| Photos (HEIC, JPG, PNG, AVIF, TIFF, GIF...) | Convert, make smaller, resize (¾, ½, ¼), crop (Square, 4:5, 9:16, 16:9), rotate, remove background, get the text, remove location, combine into a PDF |
| Videos (MOV, MP4) | Convert to MP4/MOV/GIF/sound only, make smaller, crop, trim, rotate, remove sound, remove location |
| Music and voice notes | Convert to M4A/WAV/AIFF, trim |
| PDFs | Combine, split into pages, make smaller, pages to JPG/PNG, to Word or text, rotate, get the text (even from scans) |
| Word, RTF, text, web pages | Make PDF, Word, RTF or text |

Ways to get files in: drag onto the window, drop on Kiln in the Dock, **Choose Files...**, paste with ⌘V
(works for a copied screenshot too), or right-click files in Finder and pick **Quick Actions > Open in Kiln**
(on some Macs it is under **Services**). Photos dragged straight out of the Photos app are saved to Downloads.

When it's done, drag a result straight into Messages, WhatsApp or Mail, or press **Copy** and paste it there.
If you switch away during a long video, the Dock icon bounces when it finishes.

If she picks the wrong thing on a long video, **Stop** halts it. Kiln remembers the last format and size she chose.

New versions: about once a week Kiln quietly asks this GitHub page whether there's a newer release, and if so shows a
small "A new Kiln is ready" bar with a Download button. Nothing else is sent. **Kiln menu > Check for Updates...**
checks straight away.

## Install

Needs a Mac with Apple silicon (M1 or newer) and macOS 26 Tahoe or newer.

1. Download `Kiln.zip` from the Releases page and double-click it.
2. Drag **Kiln** into **Applications**.
3. The first time, macOS will say it can't check the app. Open **System Settings > Privacy & Security**, scroll
   down and click **Open Anyway** next to Kiln. You only do this once.

## Build it yourself

```sh
./build.sh          # makes build/Kiln.app and build/Kiln.zip (needs Xcode Command Line Tools)
Tests/run.sh        # checks every action on made-up sample files
```
