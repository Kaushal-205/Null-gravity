# Sentinel AVS Dockerfile
# Multi-stage build for smaller final image

# Build stage
FROM rust:1.75-bookworm as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy manifests
COPY Cargo.toml Cargo.lock* ./

# Create a dummy main.rs to cache dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs

# Build dependencies (cached layer)
RUN cargo build --release || true

# Copy actual source
COPY src ./src

# Touch main.rs to force rebuild
RUN touch src/main.rs

# Build the application
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder
COPY --from=builder /app/target/release/sentinel /usr/local/bin/sentinel

# Create non-root user
RUN useradd -m -s /bin/bash sentinel
USER sentinel

# Set environment defaults
ENV RUST_LOG=sentinel=info
ENV LIGHTWALLETD_URL=http://lightwalletd:9067
ENV L1_RPC_URL=http://anvil:8545
ENV CONFIRMATION_DEPTH=10
ENV ZCASH_NETWORK=regtest

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep sentinel || exit 1

ENTRYPOINT ["sentinel"]

