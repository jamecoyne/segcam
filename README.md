# segcam

Real-time webcam segmentation on macOS, shown two ways: green boxes over the video, or
the whole desktop as the canvas with every segment living in its own window.

Three segmenters, one active at a time:

| key | segmenter | segments | IDs |
| --- | --- | --- | --- |
| `1` | **eyes + mouth** | eye and mouth boxes from Vision's face landmarks | `eye.L#412`, `eye.R#412`, `mouth#412` |
| `2` | **threshold** | connected regions brighter (or darker) than a level | `blob#1`, `blob#2`, … |
| `3` | **motion** | connected regions that changed against an adapting background | `motion#1`, … |

In motion mode the HUD grows a **sensitivity slider** — in the overlay bar and in the desktop
mode's control strip, so it is reachable even while the video is hidden. Dragging right makes
it twitchier; `[` and `]` move the same value in the same direction, and the two stay in step.
Under the hood it is a difference threshold where smaller means twitchier, but nothing
user-facing says so — the slider, the keys and the `sens 86%` readout all read the same way.

**Nothing is tracked between frames.** Every frame is a fresh set of instances: a face that
sits perfectly still produces a new numbered segment — and a new window — on every single
frame. That is what makes the desktop pile up. Within one frame the numbers do group, so
`eye.L#412`, `eye.R#412` and `mouth#412` are one face at one instant, and `#413` is the next
frame. `eye.L` / `eye.R` are named for which side of the raw camera frame the eye falls on,
so with mirroring on (the default) `eye.L` appears on the right of your screen.

Faces are detected only for their landmarks — the face box is not a segment — and bodies are
not detected at all. Blob and motion IDs are assigned by a tracker that matches
each frame's boxes to the previous frame's by overlap, so a thing keeps its number as long
as it keeps existing — it does not get renumbered every frame.

## The two displays — `h` switches

1. **Overlay.** The whole camera feed with each segment stroked as a green rectangle and
   labelled with its ID.
2. **Desktop swarm.** The video disappears and the entire display becomes the frame. Each
   segment gets its own real macOS window — native title bar, titled with the segment's ID —
   positioned proportionally to where it sits in the hidden frame.

   Each window shows **the single frame it was cut from** and never changes again — a
   snapshot of one instant, pinned where it was detected. Since every frame mints new
   instances, windows arrive continuously and never move: the desktop fills with a churning
   collage of everything the camera is seeing. Up to **100** are kept and the oldest is
   recycled, so at ~30 frames a second the whole pile turns over in a second or two. Raise
   `--max-blobs` for a deeper pile.

   The windows never take focus and clicks pass through them to whatever is underneath, so
   the title bars are decorative. A small control strip at the bottom of the screen keeps
   the keys working: `c` clears the collage, `h` (or Esc) goes back to the overlay.

## Build & run

```bash
~/segcam/build.sh && open ~/segcam/segcam.app
```

Command Line Tools only — no Xcode project. macOS asks for camera access on first launch.
Always launch the `.app`; running the bare binary from a terminal hands the camera grant to
the terminal instead.

The build is ad-hoc signed, and an ad-hoc signature changes identity every time the binary
changes — so macOS asks for the camera again after each rebuild. To stop that, make a
self-signed code-signing certificate in Keychain Access and build with
`SIGN_IDENTITY="Your Cert Name" ./build.sh`.

`open segcam.app --args --swarm --mode 3 --max-blobs 40` starts straight in desktop mode on
the motion segmenter with a 40-window collage — handy for scripting, for measuring, and for
tuning how big the pile-up gets.

## Controls

| key | |
| --- | --- |
| `h` | switch display (overlay ↔ desktop swarm), Esc returns |
| `1` `2` `3` | face+body / threshold / motion |
| `tab` | cycle segmenters |
| `[` `]` | threshold level, or motion sensitivity (`]` = more sensitive) |
| `-` `=` | minimum segment size |
| `i` | invert threshold (segment darks) |
| `a` | auto threshold level (Otsu) |
| `c` | clear the desktop collage |
| `esc` | back to the overlay |
| `m` | mirror · `l` overlay labels |
| `d` | next camera · ⌘1…⌘9 pick a camera or Syphon feed from the Camera menu |
| ⌘Q | quit |

## How it works

Capture is BGRA at 1280×720 with late frames discarded, so a slow frame is dropped rather
than queued. Everything downstream speaks one coordinate convention — `NormRect`, normalized
to the frame with the origin at the **top left**, un-mirrored — and the two display modes are
the only code that knows about mirroring or screens (`FrameMap.fit` for the overlay,
`FrameMap.spread` for the desktop). Vision's bottom-left rects are flipped in exactly one
place, and landmark points in one other.

The threshold and motion segmenters don't work on the full frame: each frame is box-averaged
down to a 192-column luminance grid once, and both binarize that, clean it up (motion erodes
away sensor speckle, then dilates twice so one moving arm isn't five blobs), and run the
shared connected-component labeller. In swarm mode one full-frame `CGImage` is made per frame
and each window's content is a free `cropping(to:)` view of it, rather than one render per
window.

## Syphon (TouchDesigner, Resolume, OBS…)

segcam can take its frames from a **Syphon** feed instead of a camera, so anything publishing
one — a Syphon Spout Out TOP in TouchDesigner, Resolume, OBS — can be segmented and scattered
across the desktop. Published feeds appear in the **Camera** menu below the cameras, and
picking one releases the webcam so whatever is producing the feed can have it. Feeds appear
and disappear in the menu live, and if the one being read stops publishing, segcam says so
rather than sitting on a stale frame.

```bash
open ~/segcam/segcam.app --args --syphon "TouchDesigner"
```

`--syphon` never touches the webcam at all — no camera permission prompt. Any fragment of the
feed's name works, and since Syphon servers announce themselves a moment after launch, segcam
waits a few seconds for the feed before falling back to a camera.

Frames arrive as the shared `IOSurface` and are wrapped as a pixel buffer with **no copy** —
the same memory TouchDesigner rendered into. (`CVPixelBufferCreateWithIOSurface` is the
obvious call for that and does not work: Syphon's surfaces declare no pixel format, so
CoreVideo rejects them. Syphon guarantees BGRA8, so segcam wraps the surface's bytes and says
so.)

Frames are taken at whatever rate the publisher pushes them (TouchDesigner at 60 fps means
60 fps of segmenting), unlike cameras, which are capped at 30. Slow frames are dropped rather
than queued, so it degrades by skipping rather than lagging behind.

Syphon itself is not part of macOS. `build.sh` copies `Syphon.framework` out of
TouchDesigner.app or OBS.app (whichever is installed) into the app bundle — it's BSD-licensed,
by Tom Butterworth and Anton Marini.

To test the input without TouchDesigner running, publish a feed of a moving white square:

```bash
~/segcam/tools/run-syphonpub.sh segtest
```

## Cameras

The **Camera** menu lists every camera macOS offers — built-in, USB, virtual (OBS and
friends), and an **iPhone over Continuity Camera** — with the active one checked. Pick one
from the menu, hit ⌘1…⌘9, or press `d` to cycle. The list is live: an iPhone appears in the
menu when it wakes and disappears when it walks away, and if the camera currently in use is
the one that vanished, segcam falls back to whatever is left rather than freezing on a dead
session.

Cameras differ in ways that matter, so switching re-negotiates rather than assuming: the
session preset falls back from 720p to `.high` if a device doesn't offer it, and the 30 fps
cap is only applied if the device's active format actually supports it (an iPhone's formats
are not the built-in camera's).

To open straight onto a particular camera — no visible switch on launch:

```bash
open ~/segcam/segcam.app --args --camera iphone
```

Any case-insensitive fragment of the name works. The active camera is shown in the window
title and in the HUD, and logged where you can read it back without a screenshot:

```bash
log show --last 5m --predicate 'subsystem == "com.jamecoyne.segcam"' --style compact
```

## Cost

Measured on this Mac (M-series, 10 cores), as a share of **one** core:

| | overlay | desktop swarm |
| --- | --- | --- |
| eyes + mouth | 26% | 34% |
| threshold | 14% | 27% |
| motion | 12% | 9% |

Three things got it there, in order of how much they mattered. The camera happily delivers
**47 fps**, so it is capped to 30 (`activeVideoMinFrameDuration`) — that alone took swarm
face+body from 44% to 24%. Vision runs every other frame rather than every frame. And the
swarm cuts a small standalone image per segment instead of handing each window a
`cropping(to:)` view of the whole frame: a cropped CGImage still references the full 3.5 MB
backing, so CoreAnimation re-prepared the entire frame for every window on every commit —
`CA::Render::prepare_image` was the hottest frame in the profile before that change.

The swarm also **recycles** its windows rather than closing and creating them: with a new
instance on every frame it hands out roughly a hundred windows a second, and re-dressing an
existing panel (new title, new snapshot, new position) is far cheaper than making a real one.

## Verification

```bash
~/segcam/tools/run-segtest.sh
```

Compiles the segmenter sources with a throwaway `main()` into a CLI and runs them over
synthetic frames — a square crossing the frame, two squares merging, a moving object that
stops — printing ASCII maps and asserting the things that are easy to get silently wrong:
every frame mints fresh IDs and never reuses one, a painted top-left square really lands at
`y≈0.13`, the swarm's image crops match `NormRect`, and mirroring maps to the opposite side
of the screen. No camera,
no window, no permissions.

Point it at a photo to check the Vision path numerically:

```bash
~/segcam/tools/run-segtest.sh --image ~/Pictures/somebody.jpg
```
