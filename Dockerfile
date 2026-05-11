FROM quay.io/jupyter/scipy-notebook:ubuntu-22.04

LABEL maintainer="hara"
LABEL description="Isolated OpenClaw development environment based on Jupyter scipy-notebook (Ubuntu 22.04)"

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    OPENCLAW_HOME=/home/jovyan/OpenClaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        gdb \
        git \
        pkg-config \
        ca-certificates \
        curl \
        wget \
        unzip \
        zip \
        libsdl2-dev \
        libsdl2-image-dev \
        libsdl2-mixer-dev \
        libsdl2-ttf-dev \
        libtinyxml2-dev \
        libwebp-dev \
        libpng-dev \
        libjpeg-dev \
        zlib1g-dev \
        libgl1-mesa-dev \
        libglu1-mesa-dev \
        libasound2-dev \
        libpulse-dev \
        libx11-dev \
        libxext-dev \
        libxrandr-dev \
        libxi-dev \
        libxcursor-dev \
        libxinerama-dev \
        libfreetype6-dev \
        x11-apps \
        xauth \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mamba install --yes -c conda-forge \
        jupyterlab-git \
        ipywidgets \
        xeus-cling \
    && mamba clean --all -f -y \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "/home/${NB_USER}"

USER ${NB_UID}

WORKDIR /home/jovyan/work

RUN git clone --depth 1 https://github.com/pjasicek/OpenClaw.git ${OPENCLAW_HOME} || true

EXPOSE 8888
