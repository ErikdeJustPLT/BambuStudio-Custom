# Custom Bambu Studio — auto-placement reverted to November 2025 behaviour.
#
# Two flags that took a long time to find:
#   DEP_WX_GTK3=ON  wxWidgets against GTK3. With the default GTK2, wxWebView
#                   needs WebKitGTK 1.x, which does not exist on Ubuntu 24.04,
#                   and libslic3r_gui fails with ~70 wxWebViewEvent errors.
#   SLIC3R_GTK=3    must match the toolkit wxWidgets was built against.
#
# SLIC3R_GUI stays ON. BambuStudio.cpp includes <wx/stdpaths.h> unconditionally
# and src/CMakeLists.txt references the BambuStudio target in ~30 unguarded
# places, so GUI=OFF does not produce a CLI — it produces a broken configure.
# The CLI lives inside this same binary.

FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential cmake git pkg-config ninja-build nasm m4 \
    extra-cmake-modules \
    libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev \
    libxcursor-dev libxi-dev libxext-dev libxkbcommon-dev \
    libwayland-dev libwayland-egl1-mesa wayland-protocols \
    libglu1-mesa-dev libcairo2-dev libosmesa6-dev \
    libgtk-3-dev libpango1.0-dev libgdk-pixbuf2.0-dev \
    libdbus-1-dev libwebkit2gtk-4.1-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libsecret-1-dev libudev-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone https://github.com/ErikdeJustPLT/BambuStudio-Custom.git . && \
    git checkout custom/revert-autoplace-to-nov2025

# Deps in their own layer: a failure in the app build below reuses this instead
# of rebuilding OpenCASCADE, OpenVDB and wxWidgets from scratch.
RUN mkdir -p deps/build && cd deps/build && \
    cmake .. -DDESTDIR="/root/deps_install" -DDEP_WX_GTK3=ON && \
    make -j$(nproc)

RUN mkdir -p build && cd build && \
    cmake .. \
      -DSLIC3R_GUI=ON \
      -DSLIC3R_STATIC=ON \
      -DSLIC3R_GTK=3 \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="/root/deps_install/usr/local" && \
    cmake --build . -j$(nproc)

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    xvfb xauth \
    libgtk-3-0 libwebkit2gtk-4.1-0 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
    libosmesa6 libsecret-1-0 libgl1 libglu1-mesa libglew2.2 \
    libcairo2 libpango-1.0-0 libgdk-pixbuf-2.0-0 libdbus-1-3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Binary and resources as siblings, mirroring the build tree layout where
# CMake symlinks resources next to the executable.
COPY --from=builder /build/build/src/bambu-studio /opt/bambustudio/bambu-studio
COPY --from=builder /build/resources /opt/bambustudio/resources

# The deps stage builds FFmpeg 7.0 from source; Ubuntu 24.04 ships only 6.1, so
# libavcodec.so.61 and friends have no apt equivalent and must come from there.
COPY --from=builder /root/deps_install/usr/local/lib/*.so* /usr/local/lib/
RUN ldconfig

# AppRun is the path the existing pipeline's SLICER_BIN already points at, so
# this image is a drop-in for the AppImage-based ones.
COPY bambu-headless /opt/bambu/squashfs-root/AppRun
RUN chmod +x /opt/bambu/squashfs-root/AppRun

ENTRYPOINT []
CMD ["/opt/bambu/squashfs-root/AppRun", "--help"]
