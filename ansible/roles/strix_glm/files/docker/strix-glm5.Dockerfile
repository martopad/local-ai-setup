# strix-glm5: GLM-5.3-Flash pair engine (rank + serve + tokenizer) on the M5 pool.
#
# Built on top of the pool's gufo-tp2 image: it carries the ROCm 10.1 SDK
# toolchain layer (cmake/ninja/git + amdclang++/hipcc under
# /opt/python/lib/python3.14/site-packages/_rocm_sdk_devel), so this image
# adds only the two repos and their build output. The host stays clean of
# any ROCm toolchain by design (user rule, 2026-11-10): engine + HIP
# runtime live here, the host carries only the strix kernel + /dev nodes.
#
# Revisions (pinned at 2026-11-11):
#   engine  hyukudan/strix-halo-engine-lab @ 51b42906ebbb55edf126dc3471e58b6e5892d85b (main)
#   trellis hyukudan/strix-trellis         @ 9230a97 (RC7, current release checkpoint)
#
# Runtime (per rank, on the strix kernel with /dev/tbstream0-3 present):
#   podman run --net=host --device /dev/kfd --device /dev/dri/renderD128 \
#     --device /dev/tbstream0 ... --device /dev/tbstream3 \
#     -v /home/prod/models/glm53/glm:/models strix-glm5:gfx1151 \
#     /build/strix-engine-lab/build/strix-glm5-serve /models --world 2 --rank 0 ...

FROM localhost/gufo-tp2:gfx1151

ENV DEBIAN_FRONTEND=noninteractive

# --- repos (full clones: small, and commit-pinned checkouts) ---
RUN git clone https://github.com/hyukudan/strix-halo-engine-lab.git /build/strix-engine-lab && \
    cd /build/strix-engine-lab && \
    git checkout --quiet 51b42906ebbb55edf126dc3471e58b6e5892d85b && \
    git clone https://github.com/hyukudan/strix-trellis.git /build/strix-trellis && \
    cd /build/strix-trellis && \
    git checkout --quiet 9230a97 && \
    echo "STRIX-REVS engine=51b42906 trellis=9230a97 (RC7)"

# --- trellis HIP runtime: layout the engine expects (include/ + build-qualification-v03/) ---
RUN SDK=/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel && \
    cmake -S /build/strix-trellis -B /build/strix-trellis/build-qualification-v03 -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRIX_TRELLIS_ENABLE_HIP=ON \
      -DSTRIX_TRELLIS_ENABLE_EXPERIMENTAL_TP=ON \
      -DCMAKE_HIP_COMPILER="$SDK/lib/llvm/bin/amdclang++" \
      -DCMAKE_HIP_COMPILER_ROCM_ROOT="$SDK" \
      -DCMAKE_PREFIX_PATH="$SDK" \
      -DCMAKE_HIP_ARCHITECTURES=gfx1151 && \
    cmake --build /build/strix-trellis/build-qualification-v03 --parallel "$(nproc)" && \
    ls -la /build/strix-trellis/build-qualification-v03/libstrix_trellis.a

# --- engine: GLM5 family against the trellis tree ---
RUN SDK=/opt/python/lib/python3.14/site-packages/_rocm_sdk_devel && \
    cmake -S /build/strix-engine-lab -B /build/strix-engine-lab/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_HIP_COMPILER="$SDK/lib/llvm/bin/amdclang++" \
      -DCMAKE_HIP_ARCHITECTURES=gfx1151 \
      -DCMAKE_PREFIX_PATH="$SDK" \
      -DSTRIX_ENABLE_HIP_RUNTIME=ON \
      -DSTRIX_USE_OPENSSL_SHA256=ON \
      -DSTRIX_FAMILY_GLM5=ON \
      -DSTRIX_GLM5_TRELLIS_DIR=/build/strix-trellis && \
    cmake --build /build/strix-engine-lab/build --parallel "$(nproc)" \
      --target strix-glm5-rank strix-glm5-serve strix-tokenize && \
    ls -la /build/strix-engine-lab/build/strix-glm5-rank \
           /build/strix-engine-lab/build/strix-glm5-serve \
           /build/strix-engine-lab/build/strix-tokenize && \
    /build/strix-engine-lab/build/strix-glm5-rank --help 2>&1 | head -5; \
    echo STRIX-GLM5-BUILD-OK

WORKDIR /build/strix-engine-lab
CMD ["/bin/bash"]
