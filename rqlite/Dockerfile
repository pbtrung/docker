FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget rqlite

WORKDIR /script
COPY entrypoint.sh /script/

EXPOSE 4001 4002
USER rqlite

ENTRYPOINT ["/script/entrypoint.sh"]
