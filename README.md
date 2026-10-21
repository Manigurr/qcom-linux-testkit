# video-test-suite

Self-contained test suite for V4L2 hardware video codecs on **aarch64** targets.
It bundles a private GStreamer build, a Python 3.13 runtime, v4l-utils and three
test suites, all started from one script, [run.sh](run.sh):

| Suite | What it tests |
|---|---|
| **v4l2-compliance** | V4L2 compliance of every Iris decoder and encoder video node |
| **iris_v4l2_test** | Decoder, encoder and concurrent decoder+encoder sessions straight on V4L2 |
| **fluster** | Decoder conformance (AVC, HEVC, VP9) through GStreamer V4L2 decoders |

The platform the tests run on is detected automatically, and only the tests that
platform supports are run (see [Platform capabilities](#3-platform-capabilities)).

## Repository layout

```
video-test-suite/
├── run.sh                # The only runner: detects the platform and runs the suites
├── platforms.json        # Per-platform capabilities (resolution, sessions, codecs, features)
├── setup_tools.sh        # Environment setup (GStreamer wrappers + Python install)
├── gstreamer/            # Prebuilt GStreamer 1.0 for aarch64 with its own glibc/gcc/glib runtime
├── python_install/       # Prebuilt Python 3.13 (bin/lib/include/share)
├── v4l2/                 # Prebuilt v4l-utils (v4l2-ctl, v4l2-compliance, media-ctl, ...)
├── fluster/              # Fluster conformance framework + test vectors in fluster/resources/
└── iris-v4l2-test/
    ├── iris_v4l2_test    # Statically linked aarch64 test binary
    ├── decoder/          # Decoder test configs (JSON)
    ├── encoder/          # Encoder test configs (JSON)
    ├── decoder+encoder/  # Concurrent decode + encode configs (JSON)
    ├── input_folder/     # Input bitstreams and YUV files
    └── output_folder/    # Test outputs (cleared after every config)
```

## Requirements

- An aarch64 target with a V4L2 video codec driver (e.g. Qualcomm Iris).
- Root access. `setup_tools.sh` copies Python into `/usr`.
- A POSIX shell (`sh`/`bash`). The scripts do not work in `csh`/`tcsh`.

## 1. Setup

`run.sh` sources `setup_tools.sh` by itself, so this step is only needed if you want
to use the tools (`gst-inspect-1.0`, `python3`, `v4l2-ctl`, ...) in your own shell.
Run it from the **repository root**, as root, and **source** the script rather
than executing it, because it exports environment variables into your shell:

```sh
cd video-test-suite
. ./setup_tools.sh        # or: source setup_tools.sh
```

What `setup_tools.sh` does:

1. **GStreamer wrappers.** Creates `gstreamer/bin-private/gst-wrapper` and symlinks
   `gst-launch-1.0`, `gst-inspect-1.0`, `gst-play-1.0` and `gst-discoverer-1.0` to it.
   The wrapper runs each tool through the bundled loader
   (`gstreamer/runtime-aarch64/glibc/ld-linux-aarch64.so.1`) with a private library
   path, so the host's glibc and GStreamer are never used.
2. **Plugin scanner.** Renames the real `gst-plugin-scanner` ELF to
   `gst-plugin-scanner.bin` and replaces it with a shell wrapper that uses the same
   private loader. It checks the ELF magic first, so running setup again is safe.
3. **Environment.** Exports `PATH`, `GST_PLUGIN_PATH_1_0`,
   `GST_PLUGIN_SYSTEM_PATH_1_0`, `GST_PLUGIN_SCANNER` and
   `GST_REGISTRY_1_0=/tmp/gstreamer-registry-private-glibc.bin`, clears the old
   registry, and prints `gst-inspect-1.0 --version`.
4. **iris binary.** Makes `iris-v4l2-test/iris_v4l2_test` executable.
5. **Python.** Copies `python_install/{bin,lib,include,share}` into
   `/usr/{bin,lib,include,share}` and sets `PYTHONHOME=/usr`,
   `PYTHONPATH=/usr/lib/python3.13:/usr/lib/python3.13/lib-dynload` and
   `LD_LIBRARY_PATH=/usr/lib:...`. At the end it prints `python3 -V`.

> **Note:** The exports only last for the current shell. Step 5 overwrites files in
> `/usr`, so run setup on test targets only.

Check the setup:

```sh
gst-inspect-1.0 --version
gst-inspect-1.0 | grep v4l2      # should list v4l2h264dec, v4l2h265dec, v4l2vp9dec, ...
python3 -V                       # Python 3.13.x
```

## 2. Running the tests

Run everything from the repository root, as root:

```sh
./run.sh                                  # all three suites
./run.sh v4l2-compliance                  # one suite
./run.sh iris_v4l2_test fluster           # several suites
./run.sh iris_v4l2_test decoder           # iris: decoder/ configs only
./run.sh iris_v4l2_test encoder           # iris: encoder/ configs only
./run.sh iris_v4l2_test both              # iris: decoder+encoder/ (concurrent) configs only
./run.sh iris_v4l2_test decoder encoder   # iris: union of the named folders
./run.sh --list                           # show the platform and which iris configs would run or be skipped
./run.sh --help
```

`decoder`, `encoder` and `both` on their own imply `iris_v4l2_test`. Nothing named
means run everything.

At the start `run.sh` prints the detected machine, the platform entry used and its
limits. At the end it prints a list of failed tests and the path of each failure's
log, and exits non-zero if anything failed.

| Suite | Timeout | Notes |
|---|---|---|
| v4l2-compliance | 60 s per video node | A timeout counts as a failure. Fails if no Iris decoder or encoder node is found. |
| iris_v4l2_test | 10 s per config | A timeout counts as a failure. |
| fluster | 100 s per test vector | Passes a codec only if it reaches `fluster_min_pass`. |

The timeouts are the variables `V4L2_TIMEOUT`, `IRIS_TIMEOUT` and `FLUSTER_TIMEOUT`
at the top of `run.sh`.

### Failed tests

The log of every failed test is copied to `failed_logs/<suite>/<test>.log`, for
example `failed_logs/iris_v4l2_test/avc_decoder_1920_1080_8.log` or
`failed_logs/v4l2-compliance/decoder_video16.log`. The folder of a suite is cleared
when that suite starts. The final summary lists each failed test with the path of
its log.

### v4l2-compliance

Finds every `/dev/video*` node that `v4l2-ctl` reports as `Iris Decoder` or
`Iris Encoder` and runs `v4l2-compliance` on it: decoders with
`-s5 --stream-from=v4l2/avc_decoder_input_1280_720.h264`, encoders with `-s`. The
logs are `decoder_compliance.log` and `encoder_compliance.log` in the repository
root. A node fails when it reports `Failed: N` with N above 0, times out, or prints
no `Total for` line.

### iris_v4l2_test

Takes the configs from `iris-v4l2-test/decoder`, `encoder` and `decoder+encoder`
(or the folders you name), drops the ones the platform does not support (each skip
is printed with its reason) and runs the rest one at a time:

1. Counts the expected test cases (entries with `"Domain": "Decoder"` or
   `"Domain": "Encoder"`).
2. Runs `./iris_v4l2_test --config <json>` with the timeout.
3. Marks the config **PASS** when the number of `SUCCESS!` lines equals the
   expected count, and **FAIL** (or **TIME** on a timeout) otherwise.

The live output has one line per config with the result, `SUCCESS` as
actual/expected, the run time and the running `Passed`, `Failed` and `Pending`
counts. A failed config also shows its reason. The summary is written to
`iris-v4l2-test/iris_v4l2_test_result.txt`.

#### Test configs

Config file names end with the resolution the test runs at, followed by the session
count or the feature, for example `avc_decoder_1280_720_16.json`,
`hevc_decoder_qc10c_1920_1080.json`, `avc_encoder_1920_1080_ltr.json` and
`av1_dec_1920_1080_8_hevc_enc_1280_720_8.json`. `run.sh` prints a warning if the
resolution in a file name does not match the `Width` and `Height` inside the JSON.

| Folder | Count | Coverage |
|---|---|---|
| `decoder/` | 120 | AV1, AVC, HEVC, VP9 at 720p and 1080p; NV12, QC08C and QC10C (10-bit) output; 1 to 32 concurrent sessions |
| `encoder/` | 48 | AVC and HEVC at 720p and 1080p, multi-session, plus feature tests: dynamic bitrate, hier-B/hier-P, LTR, intra refresh (cyclic/random), multislice (max bytes/max MB), rotation (90/180/270), H/V flip, downscale |
| `decoder+encoder/` | 24 | Concurrent AV1/AVC/HEVC/VP9 1080p decode with AVC/HEVC 720p encode (4, 8 and 16 sessions) |

Each JSON has an `ExecutionMode` (`Concurrent` or `Sequential`) and a list of
`TestCases`. Each `TestConfigs` block sets `Domain`, `CodecName`, `InputPath`,
`Outputpath`, `Width`, `Height`, `NumFrames`, `PixelFormat`, buffer counts and
static/dynamic controls. Input files are read from `input_folder/`.

To run a single config directly (from `iris-v4l2-test/`):

```sh
./iris_v4l2_test --config decoder/avc_decoder_1920_1080_8.json
```

### fluster

Runs three suites, with `fluster_jobs` parallel jobs (`-j`) each, skipping any codec
the platform does not list as a decoder:

| Codec | Test suite | Decoder | Log file (in `fluster/`) |
|---|---|---|---|
| AVC  | `JVT-AVC_V1`       | `GStreamer-H.264-V4L2-Gst1.0` | `avc_log.txt`  |
| HEVC | `JCT-VC-HEVC_V1`   | `GStreamer-H.265-V4L2-Gst1.0` | `hevc_log.txt` |
| VP9  | `VP9-TEST-VECTORS` | `GStreamer-VP9-V4L2-Gst1.0`   | `vp9_log.txt`  |

The test vectors are already in `fluster/resources/`, so no download is needed. A
codec passes when its `Ran X/Y tests successfully` line has X at or above that
platform's `fluster_min_pass` value for the codec.

To run a single suite or decoder by hand (from `fluster/`):

```sh
python3 fluster.py list                                         # list suites and decoders
python3 fluster.py run -ts JVT-AVC_V1 -d GStreamer-H.264-V4L2-Gst1.0 -j 8
python3 fluster.py run -ts JVT-AVC_V1 -d GStreamer-H.264-V4L2-Gst1.0 -tv <vector_name>
```

See [fluster/README.md](fluster/README.md) for all Fluster options.

## 3. Platform capabilities

Platforms differ in maximum resolution, number of concurrent sessions, supported
codecs and encoder features. [platforms.json](platforms.json) holds one entry per
platform, and `run.sh` uses only the entry of the platform it runs on.

**Detection.** The machine name is read from `/sys/devices/soc0/machine` and, if
that is missing, from `/proc/device-tree/model`. A key in `platforms.json` matches when it
equals the machine name or appears inside it, in any letter case (so `glymur`
matches `Qualcomm Technologies, Inc. Glymur CRD`); the longest matching key wins.
An unknown machine uses `default` and prints a warning.

**Keys.** Keys missing in a platform fall back to the `default` entry, except that a
platform's own `dec_max_*_sessions` (or `enc_max_*_sessions`) set replaces the
default's set.

| Key | Meaning |
|---|---|
| `dec_max_width`, `dec_max_height` | Largest decoder resolution. Larger tests are skipped. |
| `enc_max_width`, `enc_max_height` | Same for the encoder. |
| `dec_max_<W>_<H>_sessions` | Most concurrent decoder sessions for a stream of that size or smaller. The smallest listed size that fits the test is used. `0` means not supported. Add any resolution you need. |
| `enc_max_<W>_<H>_sessions` | Same for the encoder. |
| `decoder`, `encoder` | Supported codecs (`avc`, `hevc`, `vp9`, `av1`). |
| `decoder_10bit`, `encoder_10bit` | Codecs that also support 10-bit (`qc10c`, `p010`). Optional; when missing, 10-bit follows `decoder` / `encoder`. |
| `pixel_formats` | Supported formats (`nv12`, `qc08c`, `qc10c`, `p010`). |
| `encoder_supported_features` | Encoder features: `multislice`, `multislice_maxbytes`, `multislice_maxmb`, `ltr`, `hierb`, `hierp`, `rotate`, `hflip`, `vflip`, `intrarefresh_cyclic`, `intrarefresh_random`, `dynamic_bitrate`, `downscale`. `rotate` covers rotate90/180/270, `multislice` covers both multislice types and `intrarefresh` covers cyclic and random. |
| `fluster_jobs` | Parallel jobs (`-j`) for fluster. |
| `fluster_min_pass` | Minimum passed test vectors per codec (`avc`, `hevc`, `vp9`) for fluster to count as PASS. Must be set. |

**How an iris config is checked.** `run.sh` reads each config's test cases and skips
the config, with the reason printed, if any test case uses a codec, pixel format,
10-bit format, resolution, number of concurrent sessions or encoder feature the
platform does not support. The resolution, codec and format come from the JSON
content. A `Concurrent` config counts every test case as one session, a `Sequential`
one counts as a single session, and decoder and encoder are counted separately. The
encoder feature comes from the file name and from the controls in the JSON.

To add a platform, add an entry to `platforms.json` with the machine name as the
key. Use `./run.sh --list` to check which configs it would run or skip.

## v4l-utils

`v4l2/` contains prebuilt v4l-utils binaries (`v4l2-ctl`,
`v4l2-compliance`, etc.).

Verify the installation:

```sh
v4l2-ctl --version
v4l2-compliance --version
```

List available video codec devices:

```sh
v4l2-ctl --list-devices
```

Example:

```text
Iris Decoder (platform:aa00000.video-codec:de):
        /dev/video0

Iris Encoder (platform:aa00000.video-codec:en):
        /dev/video1
```

`run.sh v4l2-compliance` runs these for you on every Iris node. By hand:

Run decoder compliance:

```sh
v4l2-compliance -d /dev/video0 -s5 --stream-from=<bitstream.h264>
```

Run encoder compliance:

```sh
v4l2-compliance -d /dev/video1 -s
```

Alternatively, the bundled binaries can be invoked directly:

```sh
./v4l2/bin/v4l2-ctl --list-devices

./v4l2/bin/v4l2-compliance -d /dev/video0 -s5 --stream-from=<bitstream.h264>

./v4l2/bin/v4l2-compliance -d /dev/video1 -s
```
