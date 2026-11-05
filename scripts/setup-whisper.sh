#!/bin/zsh
# 本地编译 whisper.cpp (Metal) 并下载 large-v3-turbo 模型. 不装任何全局依赖:
# cmake 装在项目 .venv 里, whisper.cpp 在 vendor/, 模型在 models/
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x .venv/bin/cmake ]]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi

if [[ ! -d vendor/whisper.cpp ]]; then
  mkdir -p vendor
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git vendor/whisper.cpp
fi

if [[ ! -x vendor/whisper.cpp/build/bin/whisper-server ]]; then
  (cd vendor/whisper.cpp &&
    ../../.venv/bin/cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF &&
    ../../.venv/bin/cmake --build build -j 12 --config Release --target whisper-cli whisper-server)
fi

MODEL=models/ggml-large-v3-turbo.bin
if [[ ! -f $MODEL ]]; then
  mkdir -p models
  curl -L --fail -o $MODEL.part "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
  mv $MODEL.part $MODEL
fi
echo "whisper ready: vendor/whisper.cpp/build/bin/whisper-server + $MODEL"
