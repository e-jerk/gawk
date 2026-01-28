# Stage 1: Builder
FROM alpine:3 AS builder

# Install build dependencies including Vulkan
RUN apk add --no-cache \
    curl \
    xz \
    shaderc \
    bash \
    vulkan-loader-dev \
    vulkan-headers

# Install Zig 0.15.2 - architecture dependent
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) ZIG_ARCH="x86_64" ;; \
        arm64) ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz" -o /tmp/zig.tar.xz && \
    tar -xJf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-0.15.2/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /build

# Copy source code
COPY . .

# Build the binary
ARG BINARY_NAME=gawk
ARG BUILD_VARIANT=pure
RUN if [ "$BUILD_VARIANT" = "gnu" ]; then \
        zig build -Doptimize=ReleaseFast -Dgnu=true; \
    else \
        zig build -Doptimize=ReleaseFast; \
    fi && \
    mv zig-out/bin/${BINARY_NAME} /${BINARY_NAME}

# Stage 2: Export (for CI binary extraction)
FROM scratch AS export
ARG BINARY_NAME=gawk
COPY --from=builder /${BINARY_NAME} /${BINARY_NAME}

# Stage 3: Runtime (pure variant)
FROM alpine:3 AS runtime

ARG TARGETARCH
ARG BINARY_NAME=gawk

# Install Vulkan runtime and drivers
RUN apk add --no-cache vulkan-loader mesa-vulkan-swrast && \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        apk add --no-cache mesa-vulkan-ati mesa-vulkan-intel || true; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
        apk add --no-cache mesa-vulkan-broadcom mesa-vulkan-freedreno mesa-vulkan-panfrost || true; \
    fi

COPY --from=builder /${BINARY_NAME} /usr/local/bin/${BINARY_NAME}
RUN chmod +x /usr/local/bin/${BINARY_NAME}

ENTRYPOINT ["gawk"]
CMD ["--help"]