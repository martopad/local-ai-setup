FROM docker.io/rocm/vllm:rocm10.1.0_ubuntu24.04_py3.14-pytorch_2.13.0_vllm-0.29.0

ENV DEBIAN_FRONTEND=noninteractive ROCM_PATH=/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel
ENV PATH=/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel/bin:/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel/lib/llvm/bin:${PATH}

# --- gufo build deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ninja-build pkgconf git libicu-dev libcurl4-openssl-dev zlib1g-dev \
    libpng-dev libjpeg-turbo8-dev libwebp-dev libsndfile1-dev libsoxr-dev \
    libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libssl-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- RDMA: build rdma-core WITH the upstream usb4_rdma provider patch ---
RUN \
    apt-get update && \
    apt-get install -y --no-install-recommends libnl-3-dev libnl-route-3-dev libudev-dev devscripts dpkg-dev && \
    git clone --depth 1 https://github.com/linux-rdma/rdma-core /src/rdma-core && \
    git clone --depth 1 https://github.com/hellas-ai/thunderbolt-ibverbs /src/tbv && \
    for p in /src/tbv/packaging/rdma-core-patches/*.patch; do \
      patch -d /src/rdma-core -p1 < "$p" || exit 1; \
    done && \
    cd /src/rdma-core && \
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -DNO_MAN_PAGES=ON && \
    cmake --build build --parallel "$(nproc)" && \
    cmake --install build && ldconfig && \
    ls /etc/libibverbs.d/ && ldconfig -p | grep -i "libusb4_rdma\|libibverbs"

# --- gufo-tp build (TP2 RDMA) ---
RUN git clone --depth 1 https://github.com/uv-genai/gufo-tp /build/gufo && \
    cd /build/gufo && \
    cmake --preset release -DCMAKE_PREFIX_PATH=/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel -DGUFO_ENABLE_TP2_RDMA=ON \
      "-DCMAKE_CXX_FLAGS=-include format" "-DCMAKE_HIP_FLAGS=-include format" \
      -DGUFO_REVISION="$(git rev-parse HEAD)" && \
    cmake --build --preset release --parallel "$(nproc)" && \
    ./build/release/gufo --version && \
    echo GUFO-BUILD-OK

WORKDIR /build/gufo
CMD ["/bin/bash"]
