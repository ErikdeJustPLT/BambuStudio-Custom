# Multi-stage build for custom Bambu Studio CLI
# Stage 1: Builder
FROM fedora:39 as builder

# Install build dependencies
RUN dnf install -y \
    gcc-c++ \
    gcc \
    make \
    cmake \
    git \
    pkg-config \
    boost-devel \
    CGAL-devel \
    glew-devel \
    glfw-devel \
    mesa-libGL-devel \
    libX11-devel \
    libXrandr-devel \
    libXinerama-devel \
    libXcursor-devel \
    libXi-devel \
    libXext-devel \
    libxkbcommon-devel \
    openssl-devel \
    zlib-devel \
    libcurl-devel \
    freetype-devel \
    dbus-devel \
    libtbb-devel \
    && dnf clean all

# Clone and build
WORKDIR /build
RUN git clone https://github.com/ErikdeJustPLT/BambuStudio-Custom.git . && \
    git checkout custom/revert-autoplace-to-nov2025

# Build dependencies
WORKDIR /build/deps/build
RUN cmake .. -DDESTDIR="/install" && \
    make -j$(nproc)

# Build the app
WORKDIR /build/build
RUN cmake .. \
    -DSLIC3R_GUI=OFF \
    -DSLIC3R_STATIC=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="/install/usr/local" && \
    cmake --build . -j$(nproc)

# Stage 2: Runtime (minimal image with just the binary)
FROM fedora:39

# Install only runtime dependencies
RUN dnf install -y \
    openssl-libs \
    zlib \
    libcurl \
    libX11 \
    libXrandr \
    libxkbcommon \
    dbus-libs \
    && dnf clean all

# Copy the built binary from builder
COPY --from=builder /build/build/src/bambu-studio-console /usr/local/bin/bambu-studio-console

# Make it executable
RUN chmod +x /usr/local/bin/bambu-studio-console

# Set the default command
ENTRYPOINT ["/usr/local/bin/bambu-studio-console"]
CMD ["--help"]
