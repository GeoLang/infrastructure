ARG GEOPLUMB_BASE_IMAGE=geoplumb-base:latest
FROM ${GEOPLUMB_BASE_IMAGE}

USER root
COPY layers.toml /etc/geoplumb/layers.toml
RUN chmod 0444 /etc/geoplumb/layers.toml
USER geoplumb
