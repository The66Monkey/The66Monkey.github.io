# Fixing video playback on Fedora: building FFmpeg and mpv

Fedora installs cleanly, but modern video formats don’t decode out of the box. HEVC files open with audio only, H.264 behaves inconsistently, and AAC doesn’t load. It doesn’t matter which player you try or how you install it — system packages and Flatpaks behave the same. After rebuilding mpv and getting identical results, the next step was checking the codec layer directly.

Fedora uses ffmpeg‑free, a reduced FFmpeg build with many formats removed. To get proper decoding, I created a folder for FFmpeg and built it there. A normal source build with the formats I needed. When it finished, I had a complete FFmpeg installation in my home directory with its binaries and libraries in predictable places. This handled HEVC Main10, H.264, AAC, and the rest without issues.

mpv lives in its own folder. I built it using its standard waf system. During configuration, mpv detected the FFmpeg I had just built and linked against it. The resulting mpv binary uses that FFmpeg directly.

To make runtime consistent, I added a small wrapper script in ~/bin that sets LD_LIBRARY_PATH to the FFmpeg libraries and launches the mpv binary from the build directory. I added ~/bin to PATH so the wrapper is easy to call.

mpv built from source doesn’t install a desktop entry, so I added one under ~/.local/share/applications. It points to /usr/bin/mpv and lets the system handle double‑clicking video files normally.

With that in place, video playback works reliably. HEVC Main10 loads, H.264 behaves normally, AAC decodes, and hardware acceleration operates as expected. The repeated mpv builds made it clear the codec layer needed a full FFmpeg, and once that was in place everything functioned correctly on this hardware.
