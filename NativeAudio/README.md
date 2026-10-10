# Native audio package

Self-contained Swift package; no remote package dependencies. Both apps carry identical copies.
Portable floating-point libopus 1.6.1 sources are selected from the official OPUS_SOURCES,
OPUS_SOURCES_FLOAT, CELT_SOURCES, SILK_SOURCES and SILK_SOURCES_FLOAT makefile lists.
Neural enhancement and architecture-specific assembly are disabled. Apple Clang compiles
this same source for macOS, iPhone and simulator architectures through Swift Package Manager.

Upstream: https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
SHA256: 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
License: OPUS-LICENSE.txt (also bundled in each application).

Run `swift test --package-path NativeAudio`. Xcode builds the local package with each app.

`python3 scripts/verify_opus.py /path/to/opus-1.6.1.tar.gz` (from the app root) checks
the pinned archive digest and every bundled upstream source against that archive.
`OPUS-SHA256.json` also permits a fully offline integrity check without the tarball.
The small OpusBridge wrapper supplies non-variadic controls for Swift.
