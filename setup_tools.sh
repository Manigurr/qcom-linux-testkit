G=$(pwd)/gstreamer

R="$G/runtime-aarch64"
GLIBC="$R/glibc"
GCC="$R/gcc"
GLIB="$R/glib"
DEPS="$R/deps"

GSTLIB="$G/lib/aarch64-linux-gnu"

LOADER="$GLIBC/ld-linux-aarch64.so.1"

PLUGIN_DIR="$GSTLIB/gstreamer-1.0"

SCANNER_DIR="$G/libexec/gstreamer-1.0"
SCANNER="$SCANNER_DIR/gst-plugin-scanner"
SCANNER_BIN="$SCANNER_DIR/gst-plugin-scanner.bin"

WRAPPER="$G/bin-private"

mkdir -p "$WRAPPER"

LIBPATH="$GLIBC:$GCC:$GLIB:$DEPS:$GSTLIB:$G/extra_libs:/lib:/usr/lib"

cat > "$WRAPPER/gst-wrapper" <<'EOF'
#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
G=$(dirname "$SCRIPT_DIR")

R="$G/runtime-aarch64"
LOADER="$R/glibc/ld-linux-aarch64.so.1"

LIBPATH="$R/glibc:$R/gcc:$R/glib:$R/deps:$G/lib/aarch64-linux-gnu:$G/extra_libs:/lib:/usr/lib"

APP=$(basename "$0")

export GST_PLUGIN_SCANNER="$G/libexec/gstreamer-1.0/gst-plugin-scanner"
export GST_REGISTRY_1_0=/tmp/gstreamer-registry-private-glibc.bin

case "$1" in
    --version|--help|-h)
        export GST_PLUGIN_PATH_1_0=/nonexistent
        export GST_PLUGIN_SYSTEM_PATH_1_0=/nonexistent
        ;;
    *)
        export GST_PLUGIN_PATH_1_0="$G/lib/aarch64-linux-gnu/gstreamer-1.0"
        export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGIN_PATH_1_0"
        ;;
esac

exec env -u LD_LIBRARY_PATH \
    "$LOADER" \
    --library-path "$LIBPATH" \
    "$G/bin/$APP" \
    "$@"
EOF

chmod +x "$WRAPPER/gst-wrapper"

for app in \
    gst-launch-1.0 \
    gst-inspect-1.0 \
    gst-play-1.0 \
    gst-discoverer-1.0
do
    ln -sf "$WRAPPER/gst-wrapper" "$WRAPPER/$app"
done

if [ -f "$SCANNER" ] && [ ! -f "$SCANNER_BIN" ]; then
    MAGIC="$(od -An -tx1 -N4 "$SCANNER" | tr -d ' ')"
    if [ "$MAGIC" = "7f454c46" ]; then
        mv "$SCANNER" "$SCANNER_BIN"
    fi
fi

if [ -f "$SCANNER_BIN" ]; then
    cat > "$SCANNER" <<'EOF'
#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
G=$(dirname "$(dirname "$SCRIPT_DIR")")

R="$G/runtime-aarch64"
LOADER="$R/glibc/ld-linux-aarch64.so.1"

LIBPATH="$R/glibc:$R/gcc:$R/glib:$R/deps:$G/lib/aarch64-linux-gnu:$G/extra_libs:/lib:/usr/lib"

exec "$LOADER" \
    --library-path "$LIBPATH" \
    "$SCRIPT_DIR/gst-plugin-scanner.bin" \
    "$@"
EOF

    chmod +x "$SCANNER" "$SCANNER_BIN"
fi

export PATH="$WRAPPER:$G/bin:$PATH"
export GST_PLUGIN_PATH_1_0="$PLUGIN_DIR"
export GST_PLUGIN_SYSTEM_PATH_1_0="$PLUGIN_DIR"
export GST_PLUGIN_SCANNER="$SCANNER"
export GST_REGISTRY_1_0=/tmp/gstreamer-registry-private-glibc.bin

hash -r

chmod +x "$LOADER"

rm -f /tmp/gstreamer-registry-private-glibc.bin

gst-inspect-1.0 --version

chmod +x iris-v4l2-test/iris_v4l2_test

ROOT="$(pwd)"

cat >/usr/bin/v4l2-ctl <<EOF
#!/bin/sh

ROOT="$ROOT"

exec "\$ROOT/gstreamer/runtime-aarch64/glibc/ld-linux-aarch64.so.1" \
    --library-path "\$ROOT/gstreamer/runtime-aarch64/glibc:\$ROOT/gstreamer/runtime-aarch64/gcc:/usr/lib:/lib" \
    "\$ROOT/v4l2/bin/v4l2-ctl" \
    "\$@"
EOF

cat >/usr/bin/v4l2-compliance <<EOF
#!/bin/sh

ROOT="$ROOT"

exec "\$ROOT/gstreamer/runtime-aarch64/glibc/ld-linux-aarch64.so.1" \
    --library-path "\$ROOT/gstreamer/runtime-aarch64/glibc:\$ROOT/gstreamer/runtime-aarch64/gcc:/usr/lib:/lib" \
    "\$ROOT/v4l2/bin/v4l2-compliance" \
    "\$@"
EOF

chmod +x /usr/bin/v4l2-ctl
chmod +x /usr/bin/v4l2-compliance

cp -r "$(pwd)/python_install/bin/."     /usr/bin/
cp -r "$(pwd)/python_install/lib/."     /usr/lib/
cp -r "$(pwd)/python_install/include/." /usr/include/
cp -r "$(pwd)/python_install/share/."   /usr/share/

chmod +x /usr/bin/python*
chmod +x /usr/bin/pip* 2>/dev/null || true

export PYTHONHOME=/usr
export PYTHONPATH=/usr/lib/python3.13:/usr/lib/python3.13/lib-dynload
export LD_LIBRARY_PATH=/usr/lib:${LD_LIBRARY_PATH}

hash -r

python3 -V

echo "Extracting compressed assets"

# libavcodec
if [ -f gstreamer/lib/aarch64-linux-gnu/libavcodec.a.tar.xz ] &&
   [ ! -f gstreamer/lib/aarch64-linux-gnu/libavcodec.a ]; then
    tar -C gstreamer/lib/aarch64-linux-gnu \
        -xJf gstreamer/lib/aarch64-linux-gnu/libavcodec.a.tar.xz
fi

# 720p encoder input
if [ -f iris-v4l2-test/input_folder/encoder_input_1280_720.yuv.tar.xz ] &&
   [ ! -f iris-v4l2-test/input_folder/encoder_input_1280_720.yuv ]; then
    tar -C iris-v4l2-test/input_folder \
        -xJf iris-v4l2-test/input_folder/encoder_input_1280_720.yuv.tar.xz
fi

# 1080p encoder input
if [ -f iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv.tar.xz.part.aa ] &&
   [ ! -f iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv ]; then

    cat \
        iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv.tar.xz.part.* \
        > iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv.tar.xz

    tar -C iris-v4l2-test/input_folder \
        -xJf iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv.tar.xz

    rm -f iris-v4l2-test/input_folder/encoder_input_1920_1080.yuv.tar.xz
fi

echo "Done"
