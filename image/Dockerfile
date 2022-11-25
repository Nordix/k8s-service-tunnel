FROM alpine:latest
RUN apk update && apk add iproute2 tcpdump iputils net-tools
COPY service-tunnel.sh bin/
CMD ["/bin/service-tunnel.sh"]

