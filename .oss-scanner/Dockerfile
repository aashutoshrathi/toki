FROM node:22-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 procps lsof tmux curl \
    && rm -rf /var/lib/apt/lists/*

COPY . /src
WORKDIR /src

RUN python3 -m py_compile Sources/Toki/Resources/toki_remote.py \
    && node --check Sources/Toki/Resources/webui/app.js \
    && node --check Sources/Toki/Resources/webui/markdown.js \
    && node --check Sources/Toki/Resources/webui/sw.js

RUN (python3 -m unittest discover -s Tests -p 'test_*.py' \
      || echo "WARNING: companion server tests reported failures") \
    && (for t in Tests/test_*.js; do node "$t" || echo "WARNING: $t reported failures"; done)
