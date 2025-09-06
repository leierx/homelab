# renovate: datasource=docker depName=quay.io/kairos/alpine
ARG KAIROS_ALPINE_TAG=3.21-core-amd64-generic-v3.5.2
FROM quay.io/kairos/alpine:${KAIROS_ALPINE_TAG}

# required build args
ARG OEM_VARIANT
ARG IMAGE_VERSION

# Fail early if args are missing or invalid
RUN test -n "$OEM_VARIANT" || exit 1
RUN test -n "$IMAGE_VERSION" || exit 1

# nfs client
RUN apk add --no-cache nfs-utils

# Bake in correct OEM file
COPY oem/${OEM_VARIANT}.yaml /system/oem/90-${OEM_VARIANT}.yaml

# metadata
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

