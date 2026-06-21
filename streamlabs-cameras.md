# streamlabs-cameras — IP cameras in Streamlabs Desktop on Windows

Streamlabs Desktop (the rebranded "Streamlabs OBS", or SLOBS) is a fork of OBS
Studio with extra streamer-focused widgets baked in. Under the hood the source
plumbing is OBS's — so when "no video" hits, it's almost always one of: wrong
URL, wrong transport, wrong codec, or something blocking the RTSP socket
between you and the camera. This primer is the Windows-side companion to
[[ip-cameras]] (the Linux-side toolkit primer). Same protocols, different UI
and different diagnostic tools.

**Scope:** Streamlabs Desktop on Windows 10 / 11. RTSP and MJPEG cameras. If
you're on Linux, use OBS Studio with the same source settings (see
[[ip-cameras]]) — Streamlabs Desktop has no Linux build.

## No video — 60-second triage

Do these IN ORDER. ~90% of "no video" cases die at one of the first four
steps.

1. **Can VLC on the SAME Windows box open the URL?** (This isolates
   "Streamlabs problem" from "network/URL/auth problem".)
   File → Open Network Stream → paste the URL → Play.
   If VLC also fails: STOP. Fix the URL/auth/network first. Nothing in
   Streamlabs will help until VLC works.

2. **Is the URL using TCP transport?** "IP camera" does not mean "TCP camera"
   — RTSP's control channel is TCP/554, but the actual video packets ride
   RTP-over-UDP by default on two ephemeral ports negotiated during the
   handshake. Streamlabs' Media Source inherits this UDP default. UDP drops
   half its packets on wifi / busy LANs / across VPNs / through stateful
   firewalls, which is exactly what produces "handshake succeeds, picture
   stays black". The FFmpeg input arg `-rtsp_transport tcp` switches RTP to
   interleave back over the same TCP/554 socket — the single most important
   flag in this primer. Set it FIRST. (Deeper protocol layering in
   [[ip-cameras]] "TCP VS UDP" section.)

3. **Is the camera maxed on concurrent clients?** Cheap cameras (Hikvision
   OEM, generic Xiongmai, Wyze RTSP firmware) cap at 1-2 simultaneous RTSP
   sessions. Close the vendor app on your phone, close any browser tabs
   viewing the camera, close every other Streamlabs/OBS instance, and retry.

4. **Is Windows Defender Firewall / a corporate VPN blocking outbound to
   TCP/554?** From PowerShell:
   ```powershell
   Test-NetConnection -ComputerName 192.168.1.50 -Port 554
   ```
   `TcpTestSucceeded : True` = clear. `False` = firewall or routing.
   NOTE: `Test-NetConnection` defaults to TCP, which is exactly what you want
   here — TCP/554 is the RTSP control channel. You can't usefully pre-probe
   the RTP data port because it's UDP and the port number is negotiated
   dynamically per session in the SETUP handshake. Forcing `-rtsp_transport
   tcp` in the Input Args (step 6 below) makes the UDP question moot —
   everything rides the single TCP/554 socket you just verified.
   If you're on a VPN, RTSP traffic may be getting dropped by the VPN's
   split-tunnel policy. Disconnect VPN, retest.

5. **Is the camera's RTSP service enabled at all?** Many vendors ship with
   RTSP off by default in newer firmware (Reolink especially). Check the
   camera's web UI: usually under "Network → Advanced" or "System → RTSP".

6. **The actual setting that makes Streamlabs' Media Source work for IP
   cameras EVERY time** — set Input Format and Input Args:
   - Input Format: `rtsp`
   - Input Args: `-rtsp_transport tcp -fflags +nobuffer -flags low_delay -strict experimental -avioflags direct`

   (Full step-by-step in the next section.)

## Validating the URL outside Streamlabs first

Always do this before touching Streamlabs. On Windows, install both VLC and
ffmpeg (ffmpeg includes ffprobe). Via winget:

```powershell
winget install --id VideoLAN.VLC
winget install --id Gyan.FFmpeg
# (FFmpeg may need a new PowerShell window so PATH picks it up)
```

### (A) VLC visual test

- File → Open Network Stream
- URL: `rtsp://user:password@192.168.1.50:554/Streaming/Channels/101`
- Show more options → Caching: 200 ms
- Tools → Preferences → Show settings: All → Input/Codecs → Demuxers →
  RTP/RTSP → check "Use RTP over RTSP (TCP)"
- Click Play

If you see picture: URL is good, auth is good, codec is supported, the problem
is in Streamlabs config. Proceed to next section.

### (B) ffprobe CLI test (faster, more diagnostic)

```powershell
ffprobe -rtsp_transport tcp -v error -show_streams -show_format `
  "rtsp://user:password@192.168.1.50:554/Streaming/Channels/101"
```

What you want to see:
- `codec_name=h264` (or hevc — see codec gotcha below)
- `width=1920, height=1080`
- `r_frame_rate=25/1` or `30/1`

What kills Streamlabs:
- `codec_name=hevc` — older Streamlabs builds choke on H.265. Update
  Streamlabs to current, or change camera to H.264 in its web UI (Video →
  Encoding)
- `codec_name=mjpeg` — works, but use the "VLC Video Source" plugin instead,
  not Media Source
- `No streams found` — wrong URL or auth fail. Read stderr carefully:
  - `401 Unauthorized` → password is wrong, or special chars not URL-encoded
  - `404 Not Found` → path is wrong; consult vendor cheat sheet
  - `Connection refused` → RTSP service is off on the camera
  - `Connection timed out` → firewall / wrong IP / VPN / different VLAN

### (C) URL-encode special characters in passwords

`#` `@` `/` `:` `!` `&` `?` all break RTSP URL parsing. From PowerShell:

```powershell
Add-Type -AssemblyName System.Web
[System.Web.HttpUtility]::UrlEncode("p@ss!word")
# returns: p%40ss%21word
```

## Adding an IP camera as a Streamlabs Media Source

This is the canonical path that works for 99% of RTSP cameras.

1. In the scene where you want the camera:
   - Sources panel → "+" → Media Source → "Add new"
   - Give it a name like "Front door cam"

2. In the Media Source properties dialog:
   - `[ ] Local File` ← **UNCHECK THIS**
   - Input: `rtsp://user:password@192.168.1.50:554/Streaming/Channels/101`
   - Input Format: `rtsp`
   - Input Args: `-rtsp_transport tcp -fflags +nobuffer -flags low_delay -avioflags direct -strict experimental`
   - `[x] Restart playback when source becomes active`
   - `[x] Use hardware decoding when available`
   - `[ ] Show nothing when playback ends` (keep showing last frame)
   - `[ ] Close file when inactive` (keep RTSP session alive)
   - Speed: 100%
   - YUV Color Range: Partial

3. Click Done. You should see picture within ~1-2 seconds. If you don't, check
   the Streamlabs log: File → Show Log Files, look for `[ffmpeg]` lines
   matching the camera name.

### What the Input Args actually do

| Arg | Effect |
| --- | --- |
| `-rtsp_transport tcp` | Force TCP for the RTP stream (the single most important flag for IP cameras) |
| `-fflags +nobuffer` | Don't buffer demuxed packets — render now |
| `-flags low_delay` | Tell the H.264 decoder it's a low-latency stream (skip B-frame reordering tricks) |
| `-avioflags direct` | Bypass FFmpeg's internal I/O buffer |
| `-strict experimental` | Permits a couple of less-common codecs (G.711 audio, some HEVC profiles) |

### Always-on reconnect

Streamlabs' Media Source will NOT reconnect on its own if the camera drops.
Workaround in the input args:

```
-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5
```

Add these to the existing Input Args string.

## RTSP URL cheat sheet — by vendor

**Hikvision** (and most OEM rebrands):
```
rtsp://user:pass@IP:554/Streaming/Channels/101    (main, channel 1)
rtsp://user:pass@IP:554/Streaming/Channels/102    (sub, channel 1)
rtsp://user:pass@IP:554/Streaming/Channels/201    (channel 2 main)
http://user:pass@IP/ISAPI/Streaming/channels/101/picture   (snapshot)
```

**Dahua / Amcrest / Lorex** (Dahua OEM):
```
rtsp://user:pass@IP:554/cam/realmonitor?channel=1&subtype=0   (main)
rtsp://user:pass@IP:554/cam/realmonitor?channel=1&subtype=1   (sub)
http://user:pass@IP/cgi-bin/snapshot.cgi?channel=1            (snapshot)
```

**Reolink** (port varies by firmware):
```
rtsp://user:pass@IP:554/h264Preview_01_main
rtsp://user:pass@IP:554/h264Preview_01_sub
rtsp://user:pass@IP:554/h265Preview_01_main   (newer fw, H.265)
```
NOTE: Reolink doorbells & battery cams use RTSPS / WebRTC and do not expose
RTSP — for those you need Reolink's NVR or the "Reolink Restream" project as a
bridge.

**Axis:**
```
rtsp://user:pass@IP/axis-media/media.amp
rtsp://user:pass@IP/axis-media/media.amp?resolution=1920x1080&fps=15
http://IP/axis-cgi/jpg/image.cgi                  (snapshot)
```

**Foscam** (port often 88):
```
rtsp://user:pass@IP:88/videoMain
rtsp://user:pass@IP:88/videoSub
```

**Ubiquiti UniFi Protect:**
```
rtsps://IP:7441/<stream-key>?enableSrtp     (key comes from Protect web UI →
                                             Cameras → click camera →
                                             Settings → RTSP)
```

**Wyze** (ONLY with the official "RTSP firmware" flashed via the web tool;
stock firmware does NOT do RTSP):
```
rtsp://user:pass@IP/live
```

**Generic Xiongmai / Sricam / no-name:**
```
rtsp://user:pass@IP:554/user=USER&password=PASS&channel=1&stream=0.sdp
```

### Default credentials worth trying if you've lost them

```
admin / admin       admin / (blank)       admin / 12345
admin / 888888 (Dahua)         root / pass          admin / password
```

## The 12 common failure modes (and their fix)

1. **Black preview, no error**
   - Cause: UDP transport (default) dropping packets
   - Fix: add `-rtsp_transport tcp` to Input Args

2. **"Failed to open media" / red error banner**
   - Cause: wrong URL, wrong credentials, or camera refusing connection
   - Fix: verify with ffprobe first (above). Read the error.

3. **Preview loads but constantly buffers / green artifacts**
   - Cause: UDP loss, or hardware decode failing on a codec the GPU doesn't
     support
   - Fix: switch to TCP transport, AND uncheck "Use hardware decoding" to
     force software decode as a test. If it works, your GPU driver / codec
     combo is bad — update GPU driver.

4. **Audio/video out of sync or echoing**
   - Cause: the camera's audio is G.711 PCMU/PCMA and Streamlabs is resampling
     oddly, or it's a 2-second stream while the camera's mic is live in the
     room
   - Fix: Edit Sources → Advanced Audio Properties → set Sync Offset on the
     camera source (negative ms delays audio). Or just mute the camera audio
     if you don't need it.

5. **"401 Unauthorized" in logs**
   - Cause: password contains `@`, `#`, `/`, `:`, `?`, or `&` and is not
     URL-encoded; OR the camera requires digest (not basic) auth and the clock
     skew is > 5 min
   - Fix: URL-encode the password (see PowerShell snippet above); set NTP on
     the camera

6. **"404 Not Found" / "Invalid path"**
   - Cause: wrong stream path — Hikvision URL on a Dahua, etc.
   - Fix: consult vendor cheat sheet above; or run `nmap -p 554 --script
     rtsp-url-brute IP` from WSL or a Linux box (see [[ip-cameras]])

7. **Camera works, then dies after ~30 seconds**
   - Cause: RTSP keepalive missing; some cameras drop sessions if no
     GET_PARAMETER ping arrives
   - Fix: relay through MediaMTX (below). Streamlabs' Media Source does not
     send keepalives reliably.

8. **"Too many clients" / can't get picture while phone app is open**
   - Cause: camera limits concurrent RTSP sessions (often 1 or 2)
   - Fix: close all other clients, OR relay through MediaMTX which pulls ONCE
     from the camera and serves N viewers

9. **HEVC (H.265) does not render**
   - Cause: older Streamlabs builds bundle an FFmpeg without HEVC RTSP
     handling, or your CPU/GPU lacks HEVC decode
   - Fix: update Streamlabs to current; OR switch the camera to H.264 in its
     web UI (Video → Encode → Main Stream → H.264); OR relay through MediaMTX
     with a transcode to H.264

10. **Works on LAN, fails over VPN**
    - Cause: VPN split-tunnel routing RTSP traffic wrong, or MTU mismatch
      fragmenting RTP packets
    - Fix: check VPN client's "include/exclude IPs" rules; force TCP (helps
      with MTU); if still failing, lower camera bitrate in its web UI

11. **Preview shows, but going live tanks the CPU**
    - Cause: camera sends 4K @ 20 Mbps and Streamlabs is software-scaling AND
      re-encoding for the stream
    - Fix: use the SUB stream (lower-res) in Streamlabs for preview/
      monitoring; OR set camera to 1080p in its web UI; OR enable
      NVENC/QuickSync in Streamlabs Settings → Output

12. **First frame takes 5-15 seconds to appear on scene switch**
    - Cause: Streamlabs is closing the RTSP session when source goes inactive,
      and a new SETUP+PLAY handshake takes time
    - Fix: uncheck "Close file when inactive" in source properties; also helps
      to uncheck "Restart playback when source becomes active" if you want a
      continuous always-on stream

## Alternate paths when Media Source won't cooperate

### (A) VLC Video Source plugin

Streamlabs ships a "VLC Video Source" type. It uses libVLC under the hood,
which sometimes negotiates RTSP/auth more permissively than FFmpeg-based Media
Source. Especially useful for MJPEG-over-HTTP cameras.

- Sources → "+" → VLC Video Source
- Playlist → "+" → Add Path/URL → paste `rtsp://` URL
- Network Caching: 200 ms
- In advanced → `:rtsp-tcp` as an option

### (B) Browser Source (for HTTP MJPEG / HLS cameras)

If the camera's web UI exposes a snapshot or MJPEG feed at a URL like
`http://CAM/cgi-bin/mjpg/video.cgi?channel=1&subtype=1` you can drop that
directly into a Browser Source. Cheap and reliable when it works.

### (C) NDI bridge (for cameras on a different LAN/VLAN segment)

Install the NDI runtime, run a small ffmpeg→NDI bridge on a machine that CAN
see both networks, then add "NDI Source" in Streamlabs. Zero config in
Streamlabs itself once the bridge is up.

### (D) MediaMTX restream relay (the production answer)

MediaMTX (formerly rtsp-simple-server) is a tiny Go binary you run locally. It
connects ONCE to each camera and serves the stream to N viewers. Solves the
concurrent-client limit, lets you transcode HEVC→H.264, lets you offer the
camera as RTSP/RTMP/HLS/WebRTC. On Windows:

```powershell
winget install --id bluenviron.mediamtx
```

Minimal config (`C:\ProgramData\mediamtx\mediamtx.yml`):

```yaml
paths:
  front_door:
    source: rtsp://user:pass@192.168.1.50:554/Streaming/Channels/101
    sourceProtocol: tcp
  driveway:
    source: rtsp://user:pass@192.168.1.51:554/cam/realmonitor?channel=1&subtype=0
    sourceProtocol: tcp
```

Then in Streamlabs Media Source:
```
Input: rtsp://127.0.0.1:8554/front_door
```
(No auth, local loopback, the relay handles the camera side.)

### (E) ffmpeg → NDI / screen-capture fallback

Pin VLC to a portion of the screen and use a Display/Window Capture in
Streamlabs. Ugly but never fails. Last resort.

## Multi-camera scene patterns

The way you organize cameras in Streamlabs matters for both CPU and
usability:

- One MEDIA SOURCE per camera, kept in a "Cameras" scene
- Use Streamlabs SCENE COLLECTIONS to switch between layouts (single camera
  fullscreen, 2x2 grid, picture-in-picture)
- In grid scenes, use the SUB stream (low-res) — never main
- For PiP, the inset camera should be main stream (high-res) and the
  background can be sub
- Turn OFF "Close file when inactive" on every camera source if you want fast
  scene switches
- Turn ON "Restart playback when source becomes active" for cameras that idle
  for hours between use — keeps RTP timestamps fresh

### Audio hygiene

Right-click each camera source → Properties → uncheck audio if you don't need
it. Live RTSP audio + the room mic = echo. You want either the camera mic
(rare) or the room mic, not both.

## Performance notes

CPU sinks specific to IP cameras in Streamlabs:
- HEVC software decode is 3-5x more expensive than H.264. Force H.264 at the
  camera, or enable NVENC/QSV hardware decode
- 4K @ 30 fps software-decoded is 30-50% of one modern CPU per stream. With 6
  cameras you have eaten your CPU budget before encoding for stream.
- Many cheap cameras send variable-framerate H.264 — Streamlabs handles this
  poorly, dropping frames at scene boundaries. Set the camera to CBR fixed-fps
  in its web UI.

In Streamlabs Settings → Output:

| Setting | Value |
| --- | --- |
| Output Mode | Advanced |
| Encoder | NVENC H.264 (or QuickSync, or AMD VCE) — NOT x264 when you have cameras. You need CPU for decode. |
| Rate Control | CBR |
| Bitrate | Depends on platform; 6000 kbps Twitch / 4500 kbps YouTube 720p |
| Keyframe interval | 2 s |

## Honest tradeoffs

### Direct Media Source vs MediaMTX relay

- **Direct** — zero infrastructure, instant setup. Fails on concurrent-client
  limits, no failover, no transcode.
- **MediaMTX** — extra moving part to run/monitor. But: single connection to
  camera, transcodes, multiple viewers, keeps working when Streamlabs crashes.
  CORRECT choice for anything beyond casual use.

### Streamlabs Desktop vs vanilla OBS Studio

- **Streamlabs** — alerts, donations, themes, widgets baked in. UI is
  friendlier for streamers. Heavier (Electron-based shell). Occasionally lags
  on adopting upstream OBS fixes (HEVC, AV1, plugin ABI changes).
- **OBS Studio** — leaner, faster source updates, plugin ecosystem is larger.
  You wire up alerts via the StreamElements or Streamlabs browser overlay URLs
  as Browser Sources. If "no video" is a persistent problem in Streamlabs,
  testing the same URL in OBS Studio tells you if it's a Streamlabs-fork bug.

## Quick reference

```powershell
# validate the URL OUTSIDE Streamlabs first
ffprobe -rtsp_transport tcp -v error -show_streams "rtsp://U:P@HOST:554/PATH"

# test connectivity
Test-NetConnection -ComputerName 192.168.1.50 -Port 554

# URL-encode a password with specials
[System.Web.HttpUtility]::UrlEncode("p@ss!word")
```

Streamlabs Media Source — Input Args (paste this verbatim):
```
-rtsp_transport tcp -fflags +nobuffer -flags low_delay -avioflags direct -strict experimental -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5
```

MediaMTX relay (Windows):
```powershell
winget install --id bluenviron.mediamtx
# edit C:\ProgramData\mediamtx\mediamtx.yml; restart service
```

Default credentials worth a try:
```
admin/admin    admin/(blank)    admin/12345    admin/888888 (Dahua)
```

Vendor URL paths:

| Vendor | Path |
| --- | --- |
| Hikvision | `rtsp://U:P@H:554/Streaming/Channels/101` |
| Dahua | `rtsp://U:P@H:554/cam/realmonitor?channel=1&subtype=0` |
| Reolink | `rtsp://U:P@H:554/h264Preview_01_main` |
| Axis | `rtsp://U:P@H/axis-media/media.amp` |
| Foscam | `rtsp://U:P@H:88/videoMain` |
| UniFi | `rtsps://H:7441/<stream-key>?enableSrtp` |

## Cross-references

- **[[ip-cameras]]** — the Linux companion: nmap discovery, ONVIF probing, mpv
  low-latency, ffmpeg recording, MediaMTX restream, v4l2loopback
- **[[windows_commands]]** — Windows CLI reference
- **[[winget]]** — installing VLC / FFmpeg / MediaMTX
- **[[powershell]]** — Test-NetConnection, URL encoding
- **[[curl]]** — hitting HTTP snapshot endpoints
- **[[docker]]** — running MediaMTX / Frigate as containers on a separate host
