# ip-cameras — discovering, viewing, and recording RTSP/ONVIF streams on Linux

This primer covers the open-source toolkit for working with IP cameras on
Linux: `nmap` to find them, ONVIF probes to identify them, `vlc` and `mpv` to
view them, and `ffmpeg` to record and re-stream them. It works for the
universe of "real" IP cameras (Hikvision, Dahua, Amcrest, Reolink, Axis,
Foscam, generic Chinese OEM, etc.) — **not** the cloud-only consumer junk
(Ring, Wyze v3 without RTSPS firmware, Arlo, Nest) which deliberately blocks
direct LAN access. If your camera streams RTSP, MJPEG-over-HTTP, or implements
ONVIF Profile S, the tools below will work with it.

## The tools at a glance

| Tool | Role |
| --- | --- |
| `nmap` | Find cameras on the LAN, fingerprint open ports |
| `onvif` | Vendor-neutral discovery + control protocol (WS-Discovery over UDP 3702, SOAP over HTTP) |
| `vlc` | The everything-and-the-kitchen-sink GUI / CLI player; first thing to try when you just want a picture on screen |
| `mpv` | Leaner, scriptable, far better for low-latency tuning and multi-camera tiling via lua / IPC |
| `ffmpeg` | The recording, transcoding, restreaming swiss-army knife; also `ffprobe` for "what codec is this stream actually?" |
| `ffplay` | Ships with ffmpeg, useful when you want to sanity-check a URL using the same library that will later record it |

## The protocols you'll actually see

| Protocol | Details |
| --- | --- |
| RTSP | TCP/554 control channel, RTP over UDP (or interleaved over the same TCP socket). The dominant protocol for IP cameras |
| ONVIF | WS-Discovery on UDP 3702 + SOAP over HTTP (usually port 80 or 8080, sometimes 8000); the "find me your RTSP URL" protocol |
| MJPEG over HTTP | Older / cheaper cameras; a multipart HTTP response, trivially viewable in a browser |
| HTTP snapshot | Single JPEG, polled. `/cgi-bin/snapshot.cgi` and friends |
| RTSPS / SRTP | TLS-wrapped RTSP. Rare on cheap cameras, normal on enterprise Axis / Bosch |
| WebRTC / HLS / DASH | Cloud-only consumer cameras and Reolink's NVR web UI; not what we deal with here |

## TCP vs UDP — what's actually going over each

"IP camera" only means the camera speaks IP (layer 3) instead of analog
coax. IP is agnostic about whether the bits ride TCP or UDP — both are used
heavily, often in the same session. Understanding which goes where is the
single most-leveraged piece of background knowledge for debugging "no video"
/ "buffering forever" / "works on LAN, fails on wifi" symptoms.

### The RTSP/RTP split (the one that matters most)

- **RTSP control channel — TCP/554.**
  DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN. Small, infrequent,
  reliable. Always TCP.
- **RTP video/audio — UDP, by default.**
  Two ephemeral high ports negotiated in the SETUP step (one for RTP data,
  one for RTCP feedback). This is the actual stream. Fast, no handshake per
  packet, no retransmission — so a single dropped packet shows up as a green
  smear or a stutter, not a pause.
- **RTCP feedback — UDP, paired with the RTP port (RTP_port + 1).**

This is why a vanilla `rtsp://host/path` URL opens its control session on
TCP/554, then the actual video arrives via UDP from a different port.
Firewalls that allow TCP/554 but not UDP back will give you a clean RTSP
handshake followed by a permanently black picture.

### What `-rtsp_transport tcp` actually does

It tells the camera "don't open separate UDP ports — interleave the RTP
packets back over the same TCP/554 socket, prefixed with a `$` byte +
channel id + length header" (RFC 2326 §10.12).

**Pros:**
- One socket, NAT-friendly, VPN-friendly, firewall-friendly
- TCP retransmits dropped packets → no green-smear corruption

**Cons:**
- Higher latency floor (TCP head-of-line blocking — a single lost packet
  stalls the whole stream until it's recovered)
- More CPU on the camera

**Net:** TCP wins for reliability on wifi / NAT / VPN. UDP wins for absolute
minimum latency on a wired LAN with zero packet loss. For 99% of IP camera
work, force TCP.

### Other UDP in the IP-camera ecosystem

| Port | Use |
| --- | --- |
| UDP/3702 | ONVIF WS-Discovery multicast (the `broadcast-wsdd-discover` nmap script lives here) |
| UDP/5353 | mDNS / Bonjour / Avahi (cameras advertising `camera-front.local`) |
| UDP/123 | NTP (cameras syncing their clock — important, because a clock skew > 5 min breaks RTSP digest auth) |
| UDP/161 | SNMP (Axis / Bosch / enterprise monitoring) |
| UDP/5000, 5543 | Reolink P2P punch-through to vendor cloud |
| UDP/37777-ish | Dahua P2P / DH-IPC (proprietary, varies) |
| UDP varying | Hikvision Hik-Connect P2P |
| UDP varying | STUN / TURN for WebRTC (Ring / Wyze stock fw — these refuse RTSP entirely, they only speak WebRTC to the vendor cloud) |

**Practical implication:** if your camera works on the vendor's phone app from
outside the LAN, but not via LAN RTSP, the vendor app is using its UDP P2P
channel and routing through cloud relays — not RTSP at all. RTSP works ONLY
if (a) the camera supports it natively and (b) you have direct IP
reachability.

### Quick port reference (for firewall / VPN debugging)

| Port | Use |
| --- | --- |
| TCP/80, 443, 8080 | Camera web UI, ONVIF SOAP, HTTP snapshots |
| TCP/554 | RTSP control (every RTSP-capable camera) |
| TCP/8000, 8443 | Alt web UI, ONVIF (Dahua/Hikvision variants) |
| UDP ephemeral | RTP video stream (unless you forced TCP) |
| UDP/3702 | ONVIF discovery |
| UDP/5353 | mDNS |

### When UDP transport is fine

- Wired ethernet, single switch, no VLAN hops
- Same subnet as the camera
- No VPN in the path
- No aggressive firewall doing stateful UDP filtering

If any one of those is false, force TCP.

## Install

### Ubuntu (22.04, 24.04, 26.04)

```bash
sudo apt update
sudo apt install -y nmap vlc mpv ffmpeg
```

The codec story on Ubuntu: `vlc` and `ffmpeg` ship with H.264 / H.265 / AAC
baked in. Nothing extra needed for IP camera streams.

### Fedora (44)

```bash
sudo dnf install -y nmap vlc mpv ffmpeg
```

On Fedora, `ffmpeg` from the official repo is `ffmpeg-free` (no H.264 / H.265
/ AAC). IP cameras OVERWHELMINGLY send H.264 or H.265, so you need the full
ffmpeg from RPM Fusion:

```bash
sudo dnf install -y \
  https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing
```

Verify ffmpeg can actually decode H.264 / H.265:

```bash
ffmpeg -hide_banner -decoders 2>/dev/null | grep -E '^ V.+(h264|hevc)'
```

Expect lines like:

```
V..... h264                 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
V..... hevc                 HEVC (High Efficiency Video Coding)
```

### Optional but useful add-ons (both distros — same package names)

- `tcpdump` — packet capture (great for debugging RTSP handshakes)
- `wireshark` — GUI version of same; understands RTSP/RTP natively
- `curl` — hit HTTP endpoints (snapshots, ONVIF SOAP, vendor APIs)
- `python3-onvif-zeep` / `python-onvif-zeep` — ONVIF client library
- `v4l2loopback-dkms` (ubuntu) / `akmod-v4l2loopback` (fedora) — expose an IP
  camera as a `/dev/video*` device for apps that only speak v4l2
- `gstreamer` + `plugins-good/bad/ugly` — pipeline-based alternative to
  ffmpeg; useful when you outgrow CLI

## Discovery with nmap

### Step 1: find your subnet

```bash
ip -4 -br addr show | grep -v UNKNOWN
# example output: enp3s0  UP  192.168.1.42/24
# so the subnet is 192.168.1.0/24
```

### A note on scan types (worth understanding before you run anything)

| Command | What it does |
| --- | --- |
| `nmap -sn ...` | ARP on local LAN (layer 2), ICMP off-LAN. NOT TCP. Host discovery only. |
| `nmap -p ...` | Default = TCP only. `-sS` SYN scan if root, `-sT` connect scan if not. UDP is never probed unless you ask for it explicitly. |
| `nmap -sU -p ...` | UDP scan. Needs root. MUCH slower (UDP gives no positive ACK; nmap waits for ICMP "port unreachable" or a protocol reply, both rate-limited by the target). |
| `nmap --script ...` | NSE scripts run independently of the port scan layer; `broadcast-*` scripts send raw multicast packets directly. |

**Practical implication:** ONVIF discovery (UDP/3702) and mDNS (UDP/5353) will
NEVER appear in a TCP port scan. They require `-sU`, or — better — a targeted
NSE broadcast script that doesn't care about port state.

### Step 2: ping sweep for live hosts (fast, no port scan)

```bash
sudo nmap -sn 192.168.1.0/24
```

`-sn` = "no port scan", just host discovery via ARP on the local LAN (sudo
because raw ARP needs CAP_NET_RAW).

### Step 3a: TCP port scan for the camera control / web / proprietary ports

```bash
sudo nmap -p 80,443,554,1935,2020,8000,8080,8081,8443,8888,9000,34567,37777 \
  -T4 --open 192.168.1.0/24
```

All TCP. Port cheat-sheet:

| Port | Meaning |
| --- | --- |
| 80 / 8080 / 8000 | Web UI (Hikvision uses 80, Dahua uses 80, some ONVIF stacks live on 8000/8080) |
| 443 / 8443 | TLS web UI |
| 554 | RTSP control channel. The BIG signal |
| 1935 | RTMP (some cameras still expose it) |
| 2020 | Dahua ONVIF over HTTP |
| 8081 | Reolink HTTP snapshot port |
| 34567 | Xiongmai / "Sricam" / generic Chinese OEM |
| 37777 | Dahua proprietary DH-IPC |

### Step 3b: UDP port scan for the discovery / P2P protocols

Separate run — different scan type, much slower, requires root.

```bash
sudo nmap -sU -p 3702,5353,5000,5543 -T4 --open 192.168.1.0/24
```

All UDP. Port cheat-sheet:

| Port | Meaning |
| --- | --- |
| 3702 | WS-Discovery (ONVIF Profile S discovery) |
| 5353 | mDNS / Bonjour (cameras advertising `.local`) |
| 5000 / 5543 | Reolink P2P data channel |

REMEMBER: UDP scans take a long time and are noisier than TCP. On a /24
expect minutes per port. For ONVIF specifically you almost always want the
NSE script instead — it gets you the answer in one packet:

```bash
nmap --script broadcast-wsdd-discover
```

### Step 3c: combined TCP+UDP scan in a single command

When you want it all in one report, at the cost of much longer runtime:

```bash
sudo nmap -sS -sU \
  -p T:80,443,554,1935,2020,8000,8080,8081,8443,8888,9000,34567,37777,U:3702,5353,5000,5543 \
  -T4 --open 192.168.1.0/24
```

### Step 4: fingerprint a candidate

```bash
sudo nmap -sV -p 80,443,554,8000,8080 -A 192.168.1.50
# -sV  probe service versions (RTSP banners are very chatty)
# -A   OS + traceroute + scripts
```

RTSP servers happily disclose make/model in the OPTIONS response:

```
Server: GStreamer RTSP server
Server: H264DVR 1.0
Server: Hipcam RealServer/V1.0
Server: Dahua Rtsp Server
Server: Hikvision-Webs
```

nmap script for RTSP URL brute-forcing (built in, no extra install):

```bash
sudo nmap -p 554 --script rtsp-url-brute,rtsp-methods 192.168.1.50
# rtsp-methods    lists what verbs the server supports (OPTIONS, DESCRIBE,
#                 SETUP, PLAY, ...)
# rtsp-url-brute  tries ~600 known stream paths from vendor manuals. great
#                 for unbranded / OEM cameras with no public docs.
```

nmap script for HTTP — pulls titles, may reveal vendor / model:

```bash
sudo nmap -sV --script http-title,http-headers,http-auth -p 80,8080 192.168.1.50
```

**Honest tradeoff:** nmap is loud. On a corporate / managed network it WILL
trip an IDS. On your own LAN this doesn't matter. If you are auditing someone
else's network, get authorization in writing first.

## Identifying the camera and its stream URL

Once nmap has flagged 192.168.1.50 as having TCP/554 open, you need the actual
stream URL. Options, in order of effort:

### Option A — read the vendor's docs / sticker

Most cameras print a default URL on a sticker, in the box, or in a
`/cgi-bin/` endpoint accessible via the web UI. Cheap, fast, boring.

### Option B — ONVIF probe

If the camera implements ONVIF (Profile S is the relevant one for video
streaming), you can ASK it for its stream URL. WS-Discovery multicast on 3702:

```bash
nmap --script broadcast-wsdd-discover
```

Alternatively, with the `python-onvif-zeep` library:

```bash
python3 -c "
from onvif import ONVIFCamera
cam = ONVIFCamera('192.168.1.50', 80, 'admin', 'password')
media = cam.create_media_service()
profile = media.GetProfiles()[0]
req = media.create_type('GetStreamUri')
req.ProfileToken = profile.token
req.StreamSetup = {'Stream': 'RTP-Unicast',
                   'Transport': {'Protocol': 'RTSP'}}
print(media.GetStreamUri(req).Uri)
"
```

This is THE WAY for unknown / generic cameras. ONVIF was designed for exactly
this question.

### Option C — known vendor URL patterns

**Hikvision:**
```
rtsp://USER:PASS@HOST:554/Streaming/Channels/101         (main)
rtsp://USER:PASS@HOST:554/Streaming/Channels/102         (sub)
http://USER:PASS@HOST/ISAPI/Streaming/channels/101/picture   (snapshot)
```

**Dahua / Amcrest:**
```
rtsp://USER:PASS@HOST:554/cam/realmonitor?channel=1&subtype=0
rtsp://USER:PASS@HOST:554/cam/realmonitor?channel=1&subtype=1
http://USER:PASS@HOST/cgi-bin/snapshot.cgi?channel=1
```

**Reolink:**
```
rtsp://USER:PASS@HOST:554/h264Preview_01_main
rtsp://USER:PASS@HOST:554/h264Preview_01_sub
rtsp://USER:PASS@HOST:554/h265Preview_01_main             (newer fw)
http://HOST/cgi-bin/api.cgi?cmd=Snap&channel=0&user=...&password=...
```

**Axis:**
```
rtsp://USER:PASS@HOST/axis-media/media.amp
http://HOST/axis-cgi/jpg/image.cgi
```

**Foscam:**
```
rtsp://USER:PASS@HOST:88/videoMain
```

**Wyze** (only if you flashed the "RTSP firmware" — official builds DO NOT
support RTSP):
```
rtsp://USER:PASS@HOST/live
```

**Generic Xiongmai / 34567 boxes:**
```
rtsp://USER:PASS@HOST:554/user=USER&password=PASS&channel=1&stream=0.sdp
```

### Option D — packet-sniff the official app

Point the vendor's phone app at the camera while running:

```bash
sudo tcpdump -i any -A -s 0 'tcp port 554' -w /tmp/cam.pcap
```

Open the pcap in wireshark, follow the RTSP stream, read the URL the app
used. Works when nothing else does.

## vlc — the "just show me the picture" player

**GUI:** Media → Open Network Stream → paste `rtsp://USER:PASS@HOST:554/...`

CLI (this is the form you actually want):

```bash
vlc rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Force TCP transport (use this if you get garbled video / packet loss — RTSP
over UDP across wifi is unreliable):

```bash
vlc --rtsp-tcp rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Minimize VLC's caching for near-real-time view (default is 1000 ms; 200 ms is
a good IP-camera value, 0 stalls):

```bash
vlc --network-caching=200 --rtsp-tcp rtsp://...
```

Headless / kiosk:

```bash
vlc --intf dummy --fullscreen --no-osd --no-video-title-show \
    --network-caching=200 --rtsp-tcp \
    rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Loop a multi-camera playlist:

```bash
cat > ~/cams.m3u <<'EOF'
#EXTM3U
#EXTINF:-1,Front door
rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
#EXTINF:-1,Driveway
rtsp://admin:password@192.168.1.51:554/cam/realmonitor?channel=1&subtype=0
EOF
vlc --loop --random ~/cams.m3u
```

Snapshot key in the GUI: `Shift+S` (saves to `~/Pictures/vlcsnap-*.png`).

**Honest tradeoff:** VLC is forgiving and pretty. It's also a CPU pig (extra
layer of decode + render) and its latency floor (~150-250 ms even tuned) is
worse than mpv. Use it for one-off viewing, not for 16-camera grids.

## mpv — low-latency, scriptable, grid-friendly

Basic:

```bash
mpv rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

The low-latency recipe — copy these flags verbatim, they matter:

```bash
mpv \
  --rtsp-transport=tcp \
  --profile=low-latency \
  --no-cache \
  --untimed \
  --vd-lavc-threads=1 \
  --demuxer-lavf-o=fflags=+nobuffer+flush_packets \
  rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Notes:
- `--profile=low-latency` — built-in profile, sets a sane baseline
- `--rtsp-transport=tcp` — same reasoning as VLC; lossless over wifi
- `--no-cache --untimed` — skip mpv's playback cache, render as frames arrive
- `--vd-lavc-threads=1` — multi-thread decode adds 1-2 frames of latency;
  single-thread is faster for 1080p H.264 from a camera

Multi-camera tile via a script (put this in `~/bin/cam-grid`):

```bash
#!/usr/bin/env bash
geom=(1280x720+0+0 1280x720+1280+0 1280x720+0+720 1280x720+1280+720)
urls=(
  rtsp://admin:p@192.168.1.50:554/Streaming/Channels/101
  rtsp://admin:p@192.168.1.51:554/cam/realmonitor?channel=1
  rtsp://admin:p@192.168.1.52:554/h264Preview_01_main
  rtsp://admin:p@192.168.1.53:554/Streaming/Channels/101
)
for i in 0 1 2 3; do
  mpv --no-border --no-osc --geometry=${geom[$i]} \
      --rtsp-transport=tcp --profile=low-latency \
      "${urls[$i]}" &
done
wait
```

IPC mode (drive mpv from another program — keystroke into a grid, cycle
through cameras, etc.):

```bash
mpv --input-ipc-server=/tmp/mpv-cam1.sock rtsp://...
# then from another shell:
echo '{ "command": ["screenshot", "subtitles"] }' | socat - /tmp/mpv-cam1.sock
```

**Honest tradeoff:** mpv has zero GUI for "find a camera, type a URL". You
script it. For a kiosk wall this is a feature; for casual viewing it's
friction.

## ffprobe — "what is actually in this stream?"

Before you record, know what you're recording:

```bash
ffprobe -v error -show_streams -show_format \
  -rtsp_transport tcp \
  rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Concise one-liner — codec, resolution, fps, audio codec:

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 \
  -rtsp_transport tcp \
  rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101
```

Common surprises this catches:
- "1080p" camera actually streaming 1920x1072 (some Hikvision)
- `r_frame_rate=15/1` when the web UI promised 25
- `codec_name=hevc` when you assumed h264
- No audio stream at all — many cameras drop audio in the sub-stream

## ffmpeg — recording, remuxing, restreaming

### Record as-is

No transcode — this is what you want 99% of the time; CPU = ~0, quality
lossless because the bits are not re-encoded:

```bash
ffmpeg -rtsp_transport tcp \
  -i rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101 \
  -c copy \
  -movflags +frag_keyframe+empty_moov \
  /tmp/cam_$(date +%Y%m%d_%H%M%S).mp4
# -c copy                         stream-copy, no decode/encode
# -movflags +frag_keyframe...     fragmented MP4 so the file is playable
#                                 even if you SIGKILL ffmpeg
```

### Record with a time limit (30 seconds)

```bash
ffmpeg -rtsp_transport tcp -i rtsp://... -c copy -t 30 /tmp/out.mp4
```

### Record until a file size (1 GB)

```bash
ffmpeg -rtsp_transport tcp -i rtsp://... -c copy -fs 1G /tmp/out.mp4
```

### Continuous recording, segmented into 10-minute files

Great for an always-on "dashcam-style" archive on a NAS:

```bash
ffmpeg -rtsp_transport tcp -i rtsp://... \
  -c copy -f segment -segment_time 600 -segment_format mp4 \
  -strftime 1 /srv/cam-archive/front_door_%Y%m%d_%H%M%S.mp4
# -strftime 1 lets the filename pattern use strftime() tokens
```

### Snapshot — pull a single still frame from a live stream

```bash
ffmpeg -y -rtsp_transport tcp \
  -i rtsp://admin:password@192.168.1.50:554/Streaming/Channels/101 \
  -frames:v 1 -q:v 2 /tmp/snap.jpg
# -frames:v 1   exactly one video frame, then quit
# -q:v 2        high-quality JPEG (range 2-31, lower = better)
# add -ss 1.0 BEFORE -i to seek to the first keyframe and skip garbled
# leading frames on some Reolink streams
```

### Motion-triggered snapshots (one frame every 5 seconds)

```bash
ffmpeg -y -rtsp_transport tcp -i rtsp://... \
  -vf fps=1/5 -q:v 3 /tmp/cam_%05d.jpg
```

### Recode for size

Browser-friendly H.264, sane bitrate. Only do this if the camera is shipping
you 20 Mbps you don't need:

```bash
ffmpeg -rtsp_transport tcp -i rtsp://... \
  -c:v libx264 -preset veryfast -crf 24 -g 50 \
  -c:a aac -b:a 64k \
  -movflags +faststart \
  /tmp/recoded.mp4
```

### Hardware-accelerated recode

Intel QuickSync — much lower CPU:

```bash
ffmpeg -hwaccel qsv -rtsp_transport tcp -i rtsp://... \
  -c:v h264_qsv -b:v 4M -c:a aac /tmp/qsv.mp4
```

VAAPI version (Intel/AMD on Linux, see [[fedora]] HARDWARE-ACCELERATED VIDEO
for the codec-freedom story):

```bash
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -rtsp_transport tcp -i rtsp://... \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 4M /tmp/vaapi.mp4
```

### Restream to RTMP

E.g. into a local nginx-rtmp / SRS / MediaMTX server so multiple viewers can
watch without each hitting the camera, which many cheap cameras can't handle:

```bash
ffmpeg -rtsp_transport tcp -i rtsp://camera/... \
  -c copy -f flv rtmp://localhost/live/front_door
```

### Restream to HLS (browser-watchable from a static web server)

```bash
mkdir -p /var/www/cam/front
ffmpeg -rtsp_transport tcp -i rtsp://camera/... \
  -c:v copy -c:a aac -f hls \
  -hls_time 2 -hls_list_size 6 -hls_flags delete_segments \
  /var/www/cam/front/index.m3u8
```

### Expose as a V4L2 loopback device

So meet.google.com, OBS, etc. see the camera as a normal webcam:

```bash
sudo modprobe v4l2loopback devices=1 video_nr=42 card_label=ip_cam exclusive_caps=1
ffmpeg -rtsp_transport tcp -i rtsp://... \
  -f v4l2 -vcodec rawvideo -pix_fmt yuv420p /dev/video42
# now /dev/video42 is selectable in any v4l2-aware app
```

## Common gotchas — in order of how often they bite

1. **RTSP over UDP across wifi == garbage.** ALWAYS use TCP transport for IP
   cameras unless you've measured zero packet loss on the path:
   - `vlc --rtsp-tcp`
   - `mpv --rtsp-transport=tcp`
   - `ffmpeg -rtsp_transport tcp` (BEFORE `-i`)

2. **Authentication:** most cameras still default to basic auth and ship with
   default creds. These are the famous ones — change them:
   - `admin / admin`
   - `admin / (blank)`
   - `admin / 12345`
   - `admin / 888888` (Dahua)
   - `root / pass`

   Special characters in passwords MUST be URL-encoded in the `rtsp://` URL,
   or the parse will break. Example: pass `p@ss!word` → `p%40ss%21word`:

   ```bash
   python3 -c "import urllib.parse; print(urllib.parse.quote('p@ss!word', safe=''))"
   ```

3. **Clock skew.** Some cameras refuse digest auth if their internal clock is
   more than 5 minutes off yours. Either set NTP on the camera or pull the
   audio/video without auth on the "anonymous" sub-stream (vendor specific).

4. **The camera ONLY accepts one or two concurrent RTSP clients.** If VLC is
   open, mpv may get refused; if a recording is running, the GUI is locked
   out. This is a firmware limit, not a Linux problem. Solution: restream
   through ffmpeg → MediaMTX / nginx-rtmp / rtsp-simple-server, point
   everything else at the local restream.

5. **Substream vs mainstream.** Cameras almost always offer a high-bitrate
   "main" stream (e.g. 1080p/4K, 4-20 Mbps) and a low-bitrate "sub" stream
   (e.g. 640x360, 200-500 Kbps). Use sub for grids and motion detection, main
   for forensics / recording.

6. **Audio.** Many IP cameras ship audio as G.711 (PCMU / PCMA) or G.726.
   ffmpeg handles these fine; some hardware players don't, and audio mismatch
   is the #1 reason "the video plays but the file won't open in QuickTime" —
   transcode to AAC if you need cross-platform playback.

7. **firewalld / ufw zones.** If you're restreaming, open the listening port.

   Fedora:
   ```bash
   sudo firewall-cmd --add-port=1935/tcp --permanent && sudo firewall-cmd --reload
   ```
   Ubuntu:
   ```bash
   sudo ufw allow 1935/tcp
   ```

8. **NAT.** RTSP-over-UDP needs the SETUP-negotiated RTP ports forwarded
   back. If you're behind NAT, force TCP. If you're using `rtsps://` across
   the internet, also force TCP — UDP+TLS is not what RTSPS means.

9. **Keyframe interval.** If the camera's GOP is 50 frames at 25 fps,
   segmented recording will produce files starting on the next I-frame (up to
   2 sec lag). Set the camera's keyframe interval to 1-2 sec for clean
   segments.

10. **The SELinux gotcha on Fedora.** Recording into a custom path under
    `/srv` or `/var` that doesn't carry the right label will silently get
    denied:
    ```bash
    sudo semanage fcontext -a -t var_log_t '/srv/cam-archive(/.*)?'
    sudo restorecon -Rv /srv/cam-archive
    ```
    See [[fedora]] SELINUX for the broader story.

## Honest tradeoffs — which tool for which job

| Goal | Tool |
| --- | --- |
| "I need to know what's on the network" | `nmap` |
| "I need to know what kind of camera it is" | `nmap -sV`, then ONVIF |
| "I just want a window with the picture" | `vlc` |
| "I want a 4x4 wall of camera feeds" | `mpv` (scripted) |
| "I want the lowest latency possible" | `mpv` with the low-latency profile |
| "I want to record 24/7 to a NAS" | `ffmpeg` segment muxer with `-c copy` |
| "I want a still image every minute" | `ffmpeg -frames:v 1` in cron |
| "I want a browser to play it" | `ffmpeg` → HLS |
| "I want OBS / Google Meet to see the camera" | `ffmpeg` → v4l2loopback |
| "I want multiple viewers without overloading the camera" | `ffmpeg` → MediaMTX / nginx-rtmp restream |
| "I want motion detection + clip storage + web UI + push notifications" | Stop reinventing the wheel; install Frigate, MotionEye, Shinobi, or ZoneMinder |

## Quick reference

```bash
# find cameras on LAN (TCP — web, RTSP, vendor proprietary)
sudo nmap -sn 192.168.1.0/24
sudo nmap -p 80,443,554,8080 -sV --open 192.168.1.0/24

# find cameras on LAN (UDP — discovery / P2P; slow, needs root)
sudo nmap -sU -p 3702,5353 --open 192.168.1.0/24

# brute-force RTSP path
sudo nmap -p 554 --script rtsp-url-brute 192.168.1.50

# ask camera for its URL (ONVIF)
nmap --script broadcast-wsdd-discover

# view in vlc
vlc --rtsp-tcp --network-caching=200 rtsp://U:P@HOST:554/PATH

# view in mpv (low latency)
mpv --rtsp-transport=tcp --profile=low-latency \
    --no-cache --untimed rtsp://U:P@HOST:554/PATH

# inspect with ffprobe
ffprobe -v error -rtsp_transport tcp -show_streams rtsp://U:P@HOST:554/PATH

# record (stream copy)
ffmpeg -rtsp_transport tcp -i rtsp://... -c copy out.mp4

# snapshot
ffmpeg -y -rtsp_transport tcp -i rtsp://... -frames:v 1 snap.jpg

# segmented 24/7 archive
ffmpeg -rtsp_transport tcp -i rtsp://... -c copy \
  -f segment -segment_time 600 -strftime 1 cam_%Y%m%d_%H%M%S.mp4

# restream to HLS
ffmpeg -rtsp_transport tcp -i rtsp://... -c copy -f hls \
  -hls_time 2 -hls_flags delete_segments index.m3u8

# expose as /dev/video42
sudo modprobe v4l2loopback video_nr=42 exclusive_caps=1
ffmpeg -rtsp_transport tcp -i rtsp://... \
  -f v4l2 -pix_fmt yuv420p /dev/video42
```

## Cross-references

- **[[fedora]]** — HARDWARE-ACCELERATED VIDEO (mesa-va-drivers-freeworld,
  libva-nvidia-driver), SELINUX (semanage fcontext), firewalld zones
- **[[ubuntu]]** — package install patterns
- **[[ufw]]** — firewall rule patterns when restreaming
- **[[curl]]** — HTTP snapshot / vendor-API patterns
- **[[openssl]]** — RTSPS / TLS debugging (s_client)
- **[[docker]]** — Frigate / MediaMTX / nginx-rtmp containers
- **[[dd]]** — moving footage off the camera's SD card image
