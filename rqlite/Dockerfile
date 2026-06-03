FROM alpine:edge

ARG RQLITE_VERSION=10.2.0

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget nginx apache2-utils su-exec gettext && \
    wget -q "https://github.com/rqlite/rqlite/releases/download/v${RQLITE_VERSION}/rqlite-v${RQLITE_VERSION}-linux-amd64-musl.tar.gz" -O /tmp/rqlite.tar.gz && \
    tar xf /tmp/rqlite.tar.gz -C /tmp && \
    mv /tmp/rqlite-v${RQLITE_VERSION}-linux-amd64-musl/rqlited \
       /tmp/rqlite-v${RQLITE_VERSION}-linux-amd64-musl/rqlite \
       /tmp/rqlite-v${RQLITE_VERSION}-linux-amd64-musl/rqbench \
       /usr/local/bin/ && \
    rm -rf /tmp/rqlite*

RUN addgroup -g 1000 rqlite && \
    adduser -u 1000 -G rqlite -D rqlite

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf

EXPOSE 4001 4002

ENTRYPOINT ["/script/entrypoint.sh"]
CMD ["run"]
