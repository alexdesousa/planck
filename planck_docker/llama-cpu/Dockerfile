FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libcurl4-openssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG LLAMA_COMMIT=d104cf1b639a909ddea521d61f7cb023c6e41f57
RUN git clone https://github.com/PrismML-Eng/llama.cpp /llama.cpp \
    && cd /llama.cpp \
    && git checkout $LLAMA_COMMIT

WORKDIR /llama.cpp/build
RUN cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DGGML_CUDA=OFF \
    && cmake --build . --config Release --target llama-server -j$(nproc)

# ---------------------------------------------------------------------------

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 \
    libgomp1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

# Ubuntu 24.04 already ships with uid/gid 1000 as the 'ubuntu' user
USER ubuntu
EXPOSE 11434

ENV LLAMA_THREADS=8
ENV LLAMA_CTX_SIZE=32768

# exec replaces the shell so llama-server is PID 1 and receives signals correctly
CMD exec llama-server \
    -m /models/Bonsai-8B-Q1_0.gguf \
    --host 0.0.0.0 \
    --port 11434 \
    --threads $LLAMA_THREADS \
    --ctx-size $LLAMA_CTX_SIZE \
    --cache-type-k q8_0 \
    --cache-type-v q8_0
