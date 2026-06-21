# streamlabs-sources — managing sources (esp. network cameras) in Streamlabs Desktop

Streamlabs Desktop (the rebranded "Streamlabs OBS" / SLOBS) organizes
everything you put on screen as **sources**, grouped into **scenes**. This note
is the mechanical "how do I see / edit / add / remove a source" reference, with
an emphasis on **network camera** sources (RTSP / IP cameras). For the RTSP
setup recipe, vendor URLs, Input Args, and "no video" triage, see the companion
[[streamlabs-cameras]].

**Scope:** Streamlabs Desktop on Windows 10 / 11. (No Linux build — on Linux
use OBS Studio; the concepts map 1:1, the menus are near-identical.)

## The mental model — scenes, sources, mixer

| Panel | Default location | What it holds |
| --- | --- | --- |
| **Scenes** | bottom-left | Named layouts you switch between live (e.g. "Single", "2x2 grid", "PiP"). |
| **Sources** | bottom-center | The things drawn in the **currently-selected** scene (camera, capture card, image, text, browser overlay). **Order matters:** top of the list = front-most on screen. |
| **Mixer** | bottom-right | Audio levels for any source that carries audio. |

**Key fact:** sources are **per-scene**, but a single source can be
**referenced** in multiple scenes ("Add Existing", below). The same camera feed
shown in three scenes is usually *one* source referenced three times — edit it
once, all three update. This matters a lot for edit/remove (below).

### Source types used for network cameras

| Type | Notes |
| --- | --- |
| **Media Source** | The default for RTSP / IP cameras. FFmpeg under the hood. Holds the `rtsp://` URL + Input Format + Input Args. ~99% of IP-camera sources are this. |
| **VLC Video Source** | libVLC under the hood. Fallback when Media Source won't negotiate RTSP/auth, and the better choice for MJPEG-over-HTTP cameras. Holds a playlist of URLs. |

> **Not** "Video Capture Device" — that's USB webcams / capture cards, not
> network cameras.

## Verify the current network camera sources

There is **no** global "list every source in the whole project" view in
Streamlabs — sources are shown per scene. So you walk the scenes:

1. Click through each entry in the **Scenes** panel (bottom-left). Camera
   sources may be split across scenes ("Cameras", "Grid", "PiP", …).
2. In the **Sources** panel, the camera sources are the ones typed **Media
   Source** or **VLC Video Source**. The icons on each row:
   - **eye** — visible / hidden in this scene (hidden ≠ removed)
   - **lock** — locked from being moved / resized on the canvas
3. To see **which camera / IP** a source actually points at, double-click it
   (or right-click → **Properties**) and read the **Input** field — that's the
   live `rtsp://USER:PASS@IP:554/...` URL. This is how you confirm each source
   is bound to the right camera IP.
4. **Health read at a glance:** a source whose preview is black with a red
   error, while *other* sources render, isolates the dead feed.

### Tie-in with the dual-NIC / "no video" problem

When cameras go black, step 3 is the high-value check: open Properties on each
camera source and confirm the Input URL's IP matches the camera's **current**
static IP. If the URLs are correct and the feeds are still black, the fault is
upstream (the streaming box reaching the camera subnet), **not** the Streamlabs
sources — see [[streamlabs-cameras]] "Livestream: no camera video — field
triage" and "The dual-NIC / wrong-subnet fault".

### Seeing a source's name → URL mapping quickly

Streamlabs has no export of "source name = URL". To audit them, double-click
each in turn. If you maintain many, keep an external crib sheet:

```
Left   -> rtsp://USER:PASS@10.0.220.51:554/...
Center -> rtsp://USER:PASS@10.0.220.52:554/...
Right  -> rtsp://USER:PASS@10.0.220.53:554/...
```

## Edit a source

**Open Properties:** double-click the source in the Sources panel (or
right-click → **Properties**). For a camera this is the Media Source dialog.
The fields you edit:

| Field | Purpose |
| --- | --- |
| **Input** | The `rtsp://` URL — change this if the camera's IP moved |
| **Input Format** | `rtsp` |
| **Input Args** | e.g. `-rtsp_transport tcp -fflags +nobuffer -flags low_delay` (full recommended string in [[streamlabs-cameras]]) |
| **Checkboxes** | "Close file when inactive", "Use hardware decoding when available", "Restart playback when source becomes active" |

Click **Done** to apply.

- **Rename:** right-click → **Rename** (some builds: double-click the name
  text).
- **Reposition / resize on the canvas:** click the source in the **preview**,
  drag the red corner handles. Right-click → **Transform** → **Edit Transform**
  for exact px values, or **Fit to Screen** / **Center** / **Stretch**. The
  lock icon prevents accidental moves.
- **Reorder (z-order):** drag the row up/down in the Sources panel, or
  right-click → **Order** → **Move Up** / **Move to Top**. Top of the list =
  front-most on screen.
- **Audio:** the embedded camera audio shows in the **Mixer**. Mute it there,
  or right-click the source → **Properties** for per-source audio, or use
  **Advanced Audio Properties** for sync offset (negative ms delays audio).

> **Remember:** if the source is **referenced** in multiple scenes, editing its
> Properties (URL, args) changes it **everywhere**. Transform (position/size)
> is per-scene, but the underlying feed/settings are shared.

## Add more sources

1. Select the **scene** you want the camera in (Scenes panel).
2. In the **Sources** panel, click the **`+`** (Add Source).
3. Pick the type:
   - **Media Source** — default for RTSP / IP cameras
   - **VLC Video Source** — fallback / MJPEG-over-HTTP cameras
4. Name it, and choose **Add New** vs **Add Existing**:

   | Choice | What it does |
   | --- | --- |
   | **Add New** | Creates a brand-new source with its own camera connection. Use for a camera not yet in the project. |
   | **Add Existing** | Re-uses a source already defined in another scene. **Same feed, one connection** to the camera, shown in multiple scenes. Use this to put the same camera in "Single", "Grid", and "PiP" **without** opening three separate RTSP sessions (cheap cameras cap concurrent clients — see [[streamlabs-cameras]]). |

5. In Properties: **uncheck "Local File"**, paste the `rtsp://` URL into
   **Input**, set Input Format = `rtsp` and the Input Args, click **Done**.

Full Input Args recipe + checkbox settings: [[streamlabs-cameras]] "Adding an
IP camera as a Streamlabs Media Source".

> **Add Existing is the right default for multi-scene camera setups.** If you
> want Left/Center/Right in several layouts, define each camera **once** (Add
> New in your first scene), then Add Existing into every other scene. One
> camera = one source = one RTSP session, regardless of how many scenes show
> it.

## Remove a source

### Hide vs remove — know the difference

| Action | Effect |
| --- | --- |
| **eye icon (hide)** | Removes it from view in **this scene only**. The source still exists and **keeps** its connection to the camera. Non-destructive, instantly reversible. |
| **Remove** | Deletes the source from **this scene**. Select it → press **Delete**, or right-click → **Remove**. |

### The reference gotcha

If a source is **referenced** in multiple scenes (Add Existing), removing it
from **one** scene only drops **that** reference — the source survives in the
other scenes. The underlying source (and its camera connection) is gone only
once it's removed from **every** scene that references it.

### No undo

Most builds do **not** undo a removed source. If you might want it back:

- **Hide** it (eye) instead of removing, or
- Copy its Input URL out of Properties first (so you can re-add it).

### Remove a whole scene

Right-click the scene in the Scenes panel → **Remove**. This deletes the scene
and the source **references** in it; sources also referenced elsewhere survive.
Exclusively-in-that-scene sources are gone.

## Scene collections (the bigger container)

A **scene collection** is the whole set of scenes + sources, saved as a unit.
Top menu: **Scene Collection** → manage / new / duplicate / import / export.
Use cases for a camera rig:

- **Duplicate** a working collection before re-cabling / re-IPing cameras, so
  you can roll back if the edits break it.
- **Export** to back up your entire camera layout (scenes, sources, URLs,
  transforms) to a file, or move it to another machine.
- Keep separate collections per event / room / camera count.

## Right-click source menu — quick reference

| Item | Does |
| --- | --- |
| **Properties** | Edit URL / Input Args / settings (cameras) |
| **Filters** | Add color correction, crop/pad, chroma key, etc. |
| **Rename** | Change the display name |
| **Remove** | Delete from this scene (mind references) |
| **Transform** | Position / size / fit / center / flip |
| **Order** | z-order (move up/down/top/bottom) |
| **Lock / Unlock** | Prevent canvas moves |
| **Hide / Show** | Same as the eye icon |
| **Create Source Shortcut** | (some builds) hotkey to toggle visibility |

## Cross-references

- **[[streamlabs-cameras]]** — IP cameras in Streamlabs: RTSP setup, Input Args
  recipe, vendor URL cheat sheet, "no video" field triage, dual-NIC /
  wrong-subnet fault, MediaMTX relay
- **[[ip-cameras]]** — the Linux companion: nmap discovery, ONVIF, vlc / mpv /
  ffmpeg, restreaming
- **[[windows_commands]]** — Windows CLI reference
- **[[powershell]]** — Test-NetConnection, Get-NetAdapter, Find-NetRoute
