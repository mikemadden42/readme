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

### Quick TCP reachability check (Linux equiv of Windows Test-NetConnection)

The Windows-side companion [[streamlabs-cameras]] uses PowerShell's
`Test-NetConnection -ComputerName 192.168.1.50 -Port 554` to confirm the RTSP
control channel is reachable. On Linux, same idea:

```bash
nc -zv -w 3 192.168.1.50 554        # netcat: -z scan only, -w 3 = 3s timeout
ncat -zv 192.168.1.50 554           # nmap-project netcat (Fedora/RHEL default)
timeout 3 bash -c '</dev/tcp/192.168.1.50/554' && echo open || echo closed
nmap -p 554 192.168.1.50            # if you want service detection too
```

All four test the TCP/554 control channel ONLY — like `Test-NetConnection`,
they say nothing about the UDP RTP data path. That's exactly why you force
`-rtsp_transport tcp`: it moves the video onto the single TCP socket you just
verified. For UDP, add `nc -u` (but UDP gives no clean ACK, so the result is
unreliable — prefer the `nmap -sU` approach in DISCOVERY).

### When UDP transport is fine

- Wired ethernet, single switch, no VLAN hops
- Same subnet as the camera
- No VPN in the path
- No aggressive firewall doing stateful UDP filtering

If any one of those is false, force TCP.

## Verify a camera from a Linux host — the ladder

Four layers, each proving strictly more than the one before. Run them in order; stop when one fails — that layer names the fault. (This is the exact sequence used to exonerate three cameras during a real "no video on the livestream box" incident: all four layers passed from a Linux host, which isolated the fault to the **streaming box's** path to the camera subnet — see [field triage](#livestream--nvr-no-camera-video--field-triage) and [the dual-NIC fault](#the-dual-nic--wrong-subnet-fault-the-silent-killer) below.)

> **"Passes from this host" only proves the camera is healthy and reachable _from this host_.** If a different box (the streamer / NVR) is the one showing black, run the ladder **from that box** — a routed / dual-NIC host can pass every layer while the streaming box reaches nothing.

**Layer 1 — is it up and routable? (ICMP, layer 3)**

```bash
ping -c4 10.0.220.51
```

- reply + `ttl=64` → camera on the same L2 segment as you
- reply + `ttl<64` → N hops away; you're **routing** to it (`ttl=63` = 1 hop). Routing works, but you're **not** on the camera's subnet.
- no reply → camera down, wrong IP, or no route. Stop here.

*Proves: powered + IP-reachable. Proves nothing about RTSP.*

**Layer 2 — is the RTSP port actually open? (TCP/554, layer 4)**

```bash
nc -vz -w 3 10.0.220.51 554        # "succeeded!" = service is listening
```

(See [Quick TCP reachability check](#quick-tcp-reachability-check-linux-equiv-of-windows-test-netconnection) above for `ncat` / `/dev/tcp` / `nmap` variants.)

*Proves: the RTSP control channel is open end-to-end. Does not prove a valid stream, correct path, or that auth will pass.*

**Layer 3 — is it serving a real, decodable stream? (application layer)**

```bash
ffprobe -rtsp_transport tcp -loglevel verbose rtsp://USER:PASS@10.0.220.51:554/stream1
```

- prints SDP + a `Stream #0:0: Video: h264 ... 1920x1080 ... 30 fps` line → **conclusive**: the camera is delivering a valid, decodable stream.
- `401 Unauthorized` → creds problem; add/fix `USER:PASS`
- `404` / `Stream Not Found` / `method DESCRIBE failed` → wrong path; discover it

The path (`/stream1` here) and creds are vendor-specific — see [Identifying the camera and its stream URL](#identifying-the-camera-and-its-stream-url), or brute it:

```bash
nmap -p 554 --script rtsp-url-brute 10.0.220.51
```

*Proves: the stream is genuinely there and decodable. This is the test that actually settles "is the camera working".*

**Layer 4 — eyes-on (optional, confirms the picture)**

```bash
ffplay -rtsp_transport tcp rtsp://USER:PASS@10.0.220.51:554/stream1
mpv --rtsp-transport=tcp --profile=low-latency rtsp://USER:PASS@10.0.220.51:554/stream1
```

> If ffprobe (layer 3) succeeds but **VLC** fails to open the MRL, that's a VLC quirk, **not** a camera fault — VLC 3.0.x can choke on a forced-TCP option combined with an SDP that advertises `c=IN IP4 0.0.0.0`, while ffmpeg-based players (ffprobe / ffplay / mpv) read it fine. Prefer mpv / ffplay to confirm.

(Full player options in the [vlc](#vlc--the-just-show-me-the-picture-player), [mpv](#mpv--low-latency-scriptable-grid-friendly), and [ffprobe](#ffprobe--what-is-actually-in-this-stream) sections below.)

**The bottom line:** ping → 554 open → ffprobe shows a stream = cameras, switch, and camera LAN are all exonerated. If a streaming box still shows black after this passes from another host, the fault is **that box's** path to the camera subnet, not the cameras. Go to field triage / dual-NIC below.

## Livestream / NVR: no camera video — field triage

The scenario: a box that pulls the cameras (OBS / Streamlabs, an NVR, Frigate,
a vlc/mpv wall) suddenly shows NO video from the IP cameras, while everything
else on that box still works. You have rebooted the box and power-cycled the
cameras several times, with no change.

### The one observation that solves most of these

If **any** non-camera source still works (a graphics PC in PiP, a webcam, a
local file, the app's own UI), then the box, the app, and the output are all
**healthy**. The fault is isolated to the **camera signal path** — which for
IP cameras is the network / RTSP path, **not** camera power. Rebooting the box
cannot fix a network-path or routing problem, which is exactly why "I
restarted it 3 times" changes nothing.

> **Trap: "I can ping the cameras from my phone / laptop."** Another device
> pinging the cameras proves the **cameras** are up and the camera LAN is
> healthy. It does **not** prove the **box running the stream** can reach them
> — the two may sit on different subnets / NICs / VLANs. The only reachability
> test that matters is run **from the box pulling the streams**.

### Triage, in order (run everything from the box pulling the streams)

1. **Confirm the split.** Is at least one NON-camera source still live? If yes,
   STOP rebooting — it's the camera path. If NOTHING works, it's the app /
   output; a different problem.

2. **Inventory the box's own network interfaces.** A camera/streaming box very
   often has TWO NICs (one to the internet / control LAN, one to the camera
   LAN). Know which IP is on which subnet.
   ```bash
   # Linux
   ip -br addr ; ip -br link
   ```
   ```powershell
   # Windows
   Get-NetIPAddress -AddressFamily IPv4 | Select IPAddress, InterfaceAlias, AddressState
   Get-NetAdapter | Select Name, Status, MacAddress, LinkSpeed
   ```
   Look for the camera-subnet NIC present, UP, with link, and NOT on a
   link-local address (no addr on Linux / 169.254.x.x APIPA on Windows).

3. **Ask the OS which interface it will USE to reach a camera.**
   ```bash
   # Linux — must egress the camera-subnet NIC, not the internet NIC
   ip route get 10.0.220.52
   ```
   ```powershell
   # Windows — the returned source IP MUST be the camera-subnet NIC
   Find-NetRoute -RemoteIPAddress 10.0.220.52
   ```
   Wrong NIC = a routing problem (see the dual-NIC fault below).

4. **TCP/554 reachability, from the box that matters** (same probe as the
   Quick TCP reachability check above).
   ```bash
   # Linux
   nc -zv -w 3 10.0.220.52 554
   ```
   ```powershell
   # Windows
   Test-NetConnection -ComputerName 10.0.220.52 -Port 554
   ```
   Success = the RTSP control channel is reachable; the problem is URL / creds
   / transport in the app. Failure = network / NIC / routing / switch / cable.

5. **If 554 is reachable but still no picture,** validate the actual stream
   with ffprobe / vlc (see the ffprobe and vlc sections below).

## The dual-NIC / wrong-subnet fault (the silent killer)

### The shape of it

The box has two NICs on two different subnets, e.g.:

```
NIC A (internet / control):  172.16.23.37   <- holds the default gateway
NIC B (camera LAN):          10.0.220.24    <- same subnet as the cameras
cameras:                     10.0.220.51-53
```

If NIC B is down / lost link / lost its static config after a reboot, the box
has **no local route to 10.0.220.0/24**, so camera-bound traffic falls back to
the default route out NIC A (172.16.23.x) — which cannot reach the camera
subnet. Result: every camera goes black, while a phone on the 10.0.220.x LAN
pings them just fine. **That mismatch is the tell.**

### Why it survives every reboot

The cameras are fine, the switch is fine, the app is fine. Nothing a reboot
touches is broken. The break is a missing/incorrect route or a downed second
NIC — state a reboot may not restore (especially if the static IP config
didn't persist, or the cable on that port is loose).

### Diagnose

```bash
# Linux
ip -br addr ; ip -br link
ip route get 10.0.220.52        # which dev / src does it choose?
ip route show                   # is 10.0.220.0/24 a local route?
```
```powershell
# Windows
Get-NetAdapter | Select Name, Status, MacAddress, LinkSpeed
#   camera NIC must be "Up" with real LinkSpeed (cable/switch port ok)
Get-NetIPConfiguration -InterfaceAlias "<camera NIC>"
#   IPv4Address on the camera subnet? IPv4DefaultGateway should be EMPTY
Get-NetRoute -DestinationPrefix 10.0.220.0/24
Find-NetRoute -RemoteIPAddress 10.0.220.52
#   source IP it returns MUST be the camera-NIC IP (10.0.220.24)
```

### The gotcha — default gateway on the camera NIC

The camera-LAN NIC should have an IP + subnet mask but **no default gateway**.
Only the internet NIC should own the default route. If BOTH NICs carry a
gateway, the OS picks one by route metric and may send camera traffic out the
wrong NIC. (On Windows, also watch the camera NIC's "Public" firewall
profile.)

### Fix

- Bring the camera NIC back up / re-seat its cable on the switch port:
  ```bash
  sudo ip link set <dev> up           # Linux
  ```
  ```powershell
  Enable-NetAdapter -Name "<camera NIC>"   # Windows (or Restart-NetAdapter)
  ```
- Confirm the camera NIC's static IP + mask persisted across the reboot;
  re-apply if it reverted to DHCP / link-local.
- Remove any default gateway from the camera NIC; keep the default route
  **only** on the internet NIC.
- Confirm a local route to the camera subnet exists out the camera NIC.
- Re-test: `ip route get` / `Find-NetRoute`, then `nc` / `Test-NetConnection`.

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

## Recommended cameras — no PoE switch required

Every camera below: speaks RTSP natively (no firmware flashing), supports
ONVIF Profile S, powered by a 12V DC wall wart, connects via Wi-Fi. All picks
chosen to play nicely with this primer's toolkit (vlc / mpv / ffmpeg) and
with Frigate / Home Assistant / MediaMTX downstream.

### What to look for in the spec sheet

- The words "RTSP" or "ONVIF Profile S" (not just "ONVIF" — Profile S is the
  streaming profile; Profile T is newer, also fine).
- 12V DC barrel input — means later you can use a $10 PoE splitter (RJ45 in
  → ethernet + 12V DC out) and your "Wi-Fi" cam becomes a wired PoE cam in
  place.
- Dual-band Wi-Fi (5 GHz available) — 2.4-only is fine for one or two cams;
  with five it's a nightmare.
- H.264 in the codec list. H.265 is fine for raw quality but H.264 has wider
  player support and is the only universally safe choice for older
  Streamlabs / OBS builds.
- "No cloud account REQUIRED to function" — many vendors gate features
  behind their cloud; you want the camera to keep working if their servers
  go away.

### What to avoid

| Avoid | Why |
| --- | --- |
| Ring / Nest / Arlo / Wyze (stock fw) | Cloud-only, no RTSP |
| Reolink battery cams (Argus, Go, Duo battery, battery doorbells) | No RTSP — WebRTC-only |
| Eufy cameras (most models) | Cloud-mostly, plus the 2022 privacy incident |
| No-name AliExpress / Amazon "smart" cams under $30 | Usually "Yoosee" / "iCSee" ecosystem; RTSP support is inconsistent or undocumented |
| Wyze v3 + "RTSP firmware" | Works, but Wyze abandoned it ~2022; not safe to expose on the network long-term |

### Indoor pan/tilt (best $/feature ratio)

- **Reolink E1 Pro / E1 Zoom** — ~$50–70. 4 MP, dual-band Wi-Fi, pan + tilt,
  2-way audio.
  ```
  rtsp://USER:PASS@IP:554/h264Preview_01_main
  rtsp://USER:PASS@IP:554/h264Preview_01_sub
  ```
- **Amcrest IP2M-841 / IP3M-941** — ~$60–80. Dahua OEM, standard Dahua RTSP
  path. IP2M-841 is 2.4 GHz only; ProHD variants are dual-band.
  ```
  rtsp://USER:PASS@IP:554/cam/realmonitor?channel=1&subtype=0
  ```

### Outdoor bullet / turret (Wi-Fi, IP66/67)

- **Reolink RLC-510WA** — ~$60–80. 5 MP, dual-band Wi-Fi, IP66,
  person/vehicle detection on-camera. Same Reolink URL scheme as the indoor
  pan/tilt.
- **Amcrest IP5M-T1179EW** — ~$100. 5 MP turret, IP67, dual-band Wi-Fi,
  Dahua URL scheme.
- **TP-Link Tapo C320WS** — ~$45–60. 2K, dual-band Wi-Fi, color night
  vision. Cheap and decent. RTSP must be ENABLED in the Tapo app first:
  Settings → Camera Account → create a "Camera Account" (this is SEPARATE
  from your Tapo login; RTSP uses ONLY the Camera Account credentials).
  ```
  rtsp://CAM_ACCT:CAM_PASS@IP:554/stream1   (main)
  rtsp://CAM_ACCT:CAM_PASS@IP:554/stream2   (sub)
  ```

### Doorbell (Wi-Fi, hardwired to existing 16-24 VAC bell transformer)

- **Reolink Video Doorbell Wi-Fi** — ~$100. The WIRED model — NOT the
  battery doorbell. Does RTSP.
  ```
  rtsp://USER:PASS@IP:554/h264Preview_01_main
  ```
- **Amcrest AD410** — ~$80. Dahua doorbell, standard Dahua RTSP path.

### Upgrade path when you eventually get a PoE switch

- Every Reolink and Amcrest model above has a near-identical wired/PoE
  sibling (typically the same model number minus the "W"). Same RTSP URL
  scheme = zero migration friction.
- The PoE versions usually ship a better sensor / lens than the Wi-Fi
  equivalent. If a PoE switch is in your near-term plans, wait and buy PoE.
- PoE-to-DC splitter (~$10 each) lets you put your current Wi-Fi cam on PoE
  without buying a new camera. You trade Wi-Fi for wired reliability while
  keeping the same hardware.

### Honest tradeoffs — Wi-Fi vs PoE for IP cameras

- **Wi-Fi (today)** — no rewiring, instant install, no switch to buy, power
  outlet anywhere works. Cons: 2.4 GHz interference, RSSI dropouts in walls,
  wakeup lag from power-save, every camera adds load to your AP. Fine for
  2–3 cams; painful at 6+.
- **PoE (eventually)** — one CAT5e/CAT6 run per cam carries data + power.
  Utterly reliable, no power outlet needed at camera location. Cons: cable
  pulls + switch ($60–150 for an 8-port 802.3af). This is the right answer
  for permanent outdoor installs.

### Wi-Fi reliability tips (for the cameras you're buying NOW)

- Put every camera on the 5 GHz band if it can do dual-band — 2.4 GHz is
  shared with microwaves, baby monitors, BT, etc.
- Reserve a DHCP lease per camera so the IP never changes (so your `rtsp://`
  URLs don't break overnight).
- Drop the camera's frame rate in its web UI to 15 fps (you do not need 30
  fps for security footage; halves the bitrate).
- Drop the bitrate to 2–4 Mbps for 1080p / 4–6 Mbps for 4K.
- Keyframe interval (GOP) = 2 seconds — keeps recording segments clean (see
  common gotchas above).

## Recommended PoE switches — under $100, 8-port, unmanaged

The foot-guns to know BEFORE you click buy:

1. **"8-port PoE" often means "8 ports, 4 of which are PoE".** Read the spec
   sheet. You want a part number that says "8 PoE ports" or "all PoE"
   explicitly. Cheap brands love to ship 8 gigabit ports with only the first
   4 powered, sold under the same "8-port PoE switch" headline as a true
   all-PoE switch.

2. **PoE budget = total watts across all powered ports.** Not per-port. If
   the switch says "65W PoE budget" and you plug in 8 cameras at 10W each,
   you need 80W of budget — cameras will go offline or boot-loop. Typical
   camera draws:

   | Camera type | Draw |
   | --- | --- |
   | Fixed bullet / turret indoor | 3–6 W |
   | Outdoor bullet w/ IR | 5–9 W |
   | Pan/tilt indoor | 6–10 W |
   | Outdoor PTZ w/ heater | 15–25 W (need PoE+) |
   | Video doorbell | 4–7 W |

3. **"PoE" vs "PoE+" vs "PoE++" — get PoE+ at least.**

   | Standard | Per-port |
   | --- | --- |
   | 802.3af PoE | 15.4 W (12.95 W at the device) |
   | 802.3at PoE+ | 30 W (25.5 W at the device) |
   | 802.3bt PoE++ | 60–90 W (overkill for cameras) |

   PoE+ futureproofs you for PTZ / heated outdoor cams. The price gap vs
   plain PoE is now $5–10.

4. **Avoid "passive PoE" switches or injectors.** Passive PoE is NOT a
   standard — it's just DC voltage on the unused ethernet pairs, no
   negotiation. Plug a standard 802.3af/at camera into a passive 24V
   injector and the camera will refuse to power up. Plug it into a passive
   48V injector on the wrong pinout and the camera dies. (Ubiquiti's older
   AirMax gear is the famous passive-PoE example — DON'T repurpose those
   injectors for security cameras.)

5. **Fanless or fanned matters by location.** 8-port switches at the high
   end of their PoE budget often have a small fan that audibly whines. Fine
   in a closet, maddening on a desk. Fanless models cap at a lower budget
   (typically 65–90 W) — that's still 6–8 cameras at average indoor draw,
   fine for most home setups.

### Picks — known brand, warranty-backed

- **TP-Link TL-SG1008MP** — ~$80–100. 8 gigabit ports, ALL 8 are PoE+, 126 W
  total budget. The practical default. Lifetime warranty in the US. Has a
  fan but it's usually idle in normal use.
- **Netgear GS308PP** — ~$95–110. 8 gigabit ports, ALL 8 are PoE+, 83 W
  total budget. **Fanless.** Pricier and lower budget than the TP-Link, but
  silent. Great if it sits in a living room or home office. (Budget math:
  83 W / 8 cameras = ~10 W/cam ceiling — fine for indoor turrets, tight for
  PTZ/heated cams.)
- **TRENDnet TPE-TG83** — ~$80–95. 8 gigabit ports, ALL 8 are PoE+, 65 W
  total budget. Fanless. Lower budget — best for 4–6 cameras, not 8 heavy
  ones.

### Picks — budget / Shenzhen ODM (Amazon-popular)

- **YuanLey YS25-08T (and similar)** — ~$50–70. 8 gigabit ports, ALL 8
  PoE+, 96–120 W budget depending on revision. Fanless on most SKUs.
  Lifetime warranty in writing (vendor honors it, mostly). Same physical
  hardware shows up rebranded under STEAMEMO, MokerLink, SODOLA, Linkke,
  BV-Tech — all from the same Shenzhen factories. Quality is surprisingly
  good for the price. Downside: support is email-only and slow; firmware
  updates are rare.
- **MokerLink 2G08210PMS** — ~$50–65. 8 gigabit PoE+ ports + 2 gigabit
  uplinks, 96–120 W budget. Similar quality story to YuanLey.

### Honest mention — the four-PoE-port gotcha

- **TP-Link TL-SG1008P** — ~$55–70. This IS a fine switch — but only 4 of
  its 8 ports are PoE+ (64 W shared budget). Do NOT buy it if you have 5+
  cameras. Listed here because it's the most-confused product in the space;
  Amazon search will surface it next to the TL-SG1008MP and the part
  numbers differ by one letter.

### Honest mention — if you're willing to go managed

- **TP-Link TL-SG108PE** — ~$60–80. "Easy Smart" — barely managed, web UI
  for basic VLAN / QoS, 8 ports, 4 PoE+, 64 W budget. Nice if you want to
  put cameras on their own VLAN (a smart thing to do — cameras are
  notoriously chatty to vendor cloud, isolate them). Only 4 PoE ports —
  same gotcha as the unmanaged sibling.

### Quick decision

| If you want | Buy |
| --- | --- |
| Simple, warranty, name brand | TP-Link TL-SG1008MP |
| Silent (living-room placement) | Netgear GS308PP |
| The cheapest legit option | YuanLey YS25-08T |
| VLAN isolation for cameras | TP-Link TL-SG108PE (but only 4 PoE) |

## Recommended managed PoE switches — 8-port, over $100

### Why pay more for managed?

For an IP-camera deployment, the single feature worth the upcharge is:

**VLAN isolation for cameras.**

IP cameras are notoriously chatty to vendor cloud (Hikvision Hik-Connect,
Dahua P2P, Reolink p2p, Amcrest's analytics). Their security history is dire
(Mirai, persistent CVEs on web UIs, hardcoded credentials). You do NOT want
them sharing a broadcast domain with your laptop. A managed switch lets you
put cameras on a "camera VLAN" with no internet route OR a tightly-controlled
route — they can still serve RTSP to your NVR / Frigate / Streamlabs box,
but they can't phone home or get reached from the internet.

Secondary features worth having:

| Feature | What it gets you |
| --- | --- |
| Per-port PoE control | Remotely power-cycle a hung camera from the web UI ("turn it off and on again" without going to the closet) |
| Per-port PoE metering | See actual watts drawn per camera (useful for PoE-budget sanity checks) |
| SNMP | Feed switch + camera draw stats into Home Assistant / Prometheus / Grafana |
| IGMP snooping | Reduces multicast noise if you use ONVIF multicast streams (rare on home setups) |
| Port mirroring | For packet-capturing a misbehaving camera with Wireshark — invaluable for debugging |

### The "managed" spectrum (terminology varies by vendor)

| Tier | What you get |
| --- | --- |
| Easy Smart / Plus | Web UI only. VLANs, basic QoS. No SNMP, no CLI, no STP/RSTP. (TP-Link "Easy Smart", Netgear "Plus") — these creep under $100; covered briefly in the unmanaged section. |
| Smart Managed | Full web UI, VLANs, SNMP, basic STP, often cloud-controllable. No CLI. (TP-Link Omada Pro lite, Netgear "Smart") |
| L2/L2+ fully managed | Everything above + CLI, full STP/RSTP/MSTP, ACLs, LACP, layer-3 lite (static routing, DHCP server). (Cisco CBS, Aruba 1930, MikroTik, UniFi Pro) |

### Picks — known-brand, all-PoE+, under $200

- **TP-Link TL-SG2210MP** — ~$140–170. 8 gigabit PoE+ ports + 2 SFP uplinks,
  150 W budget. Omada managed: works standalone via web UI, OR
  controller-managed alongside Omada APs / gateways (Omada controller runs
  free on Linux/Docker/Windows — see [[docker]]). **Practical default in
  this tier.** Lifetime US warranty. All 8 PoE ports, generous budget, full
  VLAN/SNMP/QoS/ACL.
- **Ubiquiti UniFi USW-Lite-8-PoE** — ~$170–200. 8 gigabit ports, 4 PoE+
  (52 W budget). UniFi-managed (controller is free; self-host on
  Linux/Docker, or buy a Cloud Key, or use Ubiquiti hosted). **Gotcha: only
  4 PoE** — same trap as the unmanaged tier. Fine for 3–4 cameras + a UniFi
  AP. If you have 8 cams, you need the USW-Enterprise-8-PoE (~$500) or the
  older USW-PoE-Gen2 (8 ports all PoE+, ~$300). This is the entry-level
  pick. **Buy this if you already run UniFi gear elsewhere** — the
  single-pane-of-glass story is real.
- **Netgear GS308EPP** — ~$110–140. 8 gigabit, ALL 8 PoE+, 123 W budget.
  "Plus Managed" = web UI smart, no SNMP/CLI. Enough for VLANs + per-port
  control. **Cheapest true-managed-with-all-PoE pick.** Fanless. Downside:
  no SNMP, so no Prometheus integration; no Omada / UniFi-style ecosystem
  story.
- **Aruba Instant On 1830 8G PoE 65W** — ~$160–200. Part number JL811A. 8
  PoE+ ports, 65 W budget. Fully managed L2+, cloud-managed via Aruba
  Instant On mobile app + web. HPE/Aruba ecosystem if you already have
  Instant On APs. Budget is tight at 65 W — fine for 6 indoor cams,
  marginal for 8.

### Picks — if you want to learn real networking

- **MikroTik CSS610-8P-2S+IN** — ~$180–200. 8 gigabit PoE-out ports + 2
  SFP+, 110 W budget. Runs SwOS (the simpler, switch-only OS — not full
  RouterOS). Fully managed: VLAN, QoS, link aggregation, port mirroring,
  SNMP. Web UI is sparse and the documentation is a wiki, but the hardware
  is rock-solid and outlives any TP-Link. **Buy this if you find networking
  interesting; skip if you just want it to work without reading manuals.**

### Picks — Cisco SMB (if your shop already runs Cisco)

- **Cisco CBS250-8P-E-2G** — ~$200–260. 8 PoE+ + 2 gigabit uplinks, 67 W
  budget. Fully managed L2+. CBS = "Cisco Business Switching" — the new
  low-end line replacing the old SG-series. Familiar Cisco web UI + CLI.
  Pricey for budget, but it's a Cisco at the bottom of the curve. Five-year
  limited warranty + next-business-day RMA.

### Honest tradeoffs — managed vs unmanaged for cameras

Stick with unmanaged if:

- 1–4 cameras, all behind your home firewall.
- Your router does VLAN tagging already (some prosumer routers like
  MikroTik / Ubiquiti EdgeRouter / OPNsense can isolate at the router
  instead of the switch).
- You don't run an SNMP / monitoring stack.

Step up to managed if:

- 5+ cameras AND you care about network hygiene.
- You want to block cameras from reaching the internet at the SWITCH level
  (defense in depth).
- You want SNMP feeds into Prometheus / Home Assistant.
- You ever want to packet-capture a misbehaving camera.

### Quick decision — managed

| If you want | Buy |
| --- | --- |
| Safe default, all features, name brand | TP-Link TL-SG2210MP |
| You already run UniFi gear | UniFi USW-Lite-8-PoE (only 4 PoE — watch out) |
| Cheapest "real" managed | Netgear GS308EPP |
| You already run Aruba Instant On | Aruba 1830 (JL811A) |
| You want to learn networking | MikroTik CSS610-8P-2S+IN |
| Your shop runs Cisco | Cisco CBS250-8P-E-2G |

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
