FROM ghcr.io/archlinux/archlinux:base-20230911.0.178072

RUN --mount=type=cache,target=/var/cache/pacman/\
    pacman -Sy --noconfirm \
        kubectl \
        kubeconform \
        kustomize \
        yq

COPY validate /usr/local/bin/
