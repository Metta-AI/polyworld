# Build the game and runner artifacts independently, then compose the approved pair.
ARG RUNNER_IMAGE
ARG GAME_IMAGE
FROM ${RUNNER_IMAGE} AS runner
FROM ${GAME_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY --from=runner /usr/local/bin/node /usr/local/bin/node
COPY --from=runner /opt/worlds/server.mjs /opt/worlds/server.mjs
COPY coworld/gota/conductor/host.py /opt/gota/host.py
RUN useradd --system --create-home world
USER world
ENTRYPOINT ["node", "/opt/worlds/server.mjs"]
