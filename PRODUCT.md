# Product

<!-- impeccable:product-schema 1 -->

> Written from Kritin's brief on 2026-11-06 ("you know it best, make me something similar combining all of them,
> so even my sis can use it"). He asked Claude to proceed without an interview, so facts marked *(inferred)* are
> Claude's reading of that brief, not answers he gave.

## Platform

macos (native SwiftUI app; Apple HIG governs structure, controls and materials)

## Stack

delegated: Swift + SwiftUI + AppKit, built with the Command Line Tools (no Xcode), Apple frameworks only
(ImageIO, AVFoundation, PDFKit, Vision, Core Image). Chosen so the app is one self-contained .app that can be
AirDropped to his sister's Mac with nothing else to install. Target macOS 26, Apple silicon (his Mac and his
sister's M5).

## Users

- Kritin: technical, runs many tools, wants the best of Clop, Permute, OpenShelf and Open Tangerine in one place.
- His younger sister (M5 Mac): non-technical *(inferred)*. She must be able to use it with no explanation.

## Product Purpose

Drop any everyday file (photo, screenshot, video, audio, PDF, Word document) onto one window and get back the
version you need: another format, smaller, cropped, trimmed, combined, or as text. Success: the common job takes
one drop and one click, and the result sits next to the original.

## Positioning

The competitors each cover a slice: Clop shrinks and crops media, Permute converts media but is paid and skips
documents, OpenShelf hides its tools behind key combinations mid-drag, Open Tangerine batches images. Kiln covers
images, video, audio, PDFs and documents in one window, shows only the actions that make sense for what was
dropped, never uploads anything, and never overwrites an original.

## Capabilities and Constraints

- Everything runs on the Mac; no network use at all.
- Originals are never changed. Results are saved beside them as "name (kiln).ext"-style copies *(naming inferred)*.
- No paid tier, no account, no telemetry.
- Must open without Gatekeeper friction on the sister's Mac as far as an unsigned personal build allows
  (ad-hoc signed; first open may need right-click > Open). *(No Apple Developer ID on hand: inferred.)*
- Undecided: whether a clipboard auto-shrink (Clop's signature) is wanted; left out of v1.

## Evidence on Hand

None: no users, reviews or metrics exist. Do not invent any.

## Product Principles

1. One drop, one click: the most likely action is the obvious button.
2. Show only what fits the file: a PDF never sees "trim", a video never sees "combine pages".
3. Originals are sacred: copies only, always beside the original, always findable.
4. Plain words, not formats-speak: "Make smaller", "Send-friendly", not "H.265 CRF 28".
5. Local and private by construction.

## Accessibility & Inclusion

Dynamic system text, full keyboard use, VoiceOver labels on every control, Dark and Light appearance.
