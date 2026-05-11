FROM quay.io/jupyter/scipy-notebook:ubuntu-22.04

LABEL maintainer="hara"
LABEL description="Isolated OpenClaw (openclaw.ai) personal AI assistant environment based on Jupyter scipy-notebook (Ubuntu 22.04)"

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    OPENCLAW_HOME=/home/jovyan/.openclaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        python3-dev \
        jq \
        tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mamba install --yes -c conda-forge "nodejs>=24" \
    && mamba clean --all -f -y \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "/home/${NB_USER}" \
    && node --version \
    && npm --version

RUN npm install -g pnpm@latest \
    && npm install -g openclaw@latest \
    && openclaw --version

RUN install -d -o ${NB_UID} -g ${NB_GID} \
        /home/jovyan/.openclaw \
        /home/jovyan/.openclaw/workspace \
        /home/jovyan/.openclaw/credentials \
    && fix-permissions "/home/${NB_USER}"

USER ${NB_UID}

WORKDIR /home/jovyan/work

EXPOSE 8888 18789

CMD ["start-notebook.sh"]
