FROM ubuntu:24.04 AS compiler
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc git curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz \
    | tar xJ -C /opt
ENV PATH=/opt/nim-2.2.10/bin:$PATH
WORKDIR /src/polyworld
COPY coworld/dependencies.lock coworld/dependencies.lock
COPY coworld/tools/sync_dependencies.nim coworld/tools/tooling.nim coworld/tools/
RUN nim r --hints:off coworld/tools/sync_dependencies.nim
ENV POLYWORLD_DEPS=/src/polyworld/tmp/coworld/deps
COPY config.nims config.nims
COPY src/polyworld/rooms.nim src/polyworld/relays.nim src/polyworld/
COPY tools/gameserver.nim tools/gameserver.nim
RUN nim c --threads:on -d:release -o:/out/gameserver tools/gameserver.nim
FROM ubuntu:24.04
RUN useradd --system --uid 10001 relay
COPY --from=compiler /out/gameserver /usr/local/bin/gameserver
USER relay
ENV BIND=0.0.0.0 PORT=8090
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/gameserver"]
