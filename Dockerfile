# syntax=docker/dockerfile:1
ARG VERSION=EDGE
ARG RELEASE=0

FROM python:3.10-slim as build

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /app

# Install under /root/.local
ENV PIP_USER="true"
ARG PIP_NO_WARN_SCRIPT_LOCATION=0
ARG PIP_ROOT_USER_ACTION="ignore"

# Install build dependencies
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends python3-launchpadlib git curl && \
    apt-get clean

# Install PyTorch and TensorFlow
# The versions must align and be in sync with the requirements_linux_docker.txt
# hadolint ignore=SC2102
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    pip install -U --extra-index-url https://download.pytorch.org/whl/cu121 --extra-index-url https://pypi.nvidia.com \
    torch==2.1.2 torchvision==0.16.2 \
    xformers==0.0.23.post1 \
    # Why [and-cuda]: https://github.com/tensorflow/tensorflow/issues/61468#issuecomment-1759462485
    tensorflow[and-cuda]==2.14.0 \
    ninja \
    pip setuptools wheel

# Install requirements
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    --mount=source=requirements_linux_docker.txt,target=requirements_linux_docker.txt \
    --mount=source=requirements.txt,target=requirements.txt \
    --mount=source=setup/docker_setup.py,target=setup.py \
    pip install -r requirements_linux_docker.txt -r requirements.txt

# Replace pillow with pillow-simd (Only for x86)
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    apt-get -qq update && \
    apt-get install -y --no-install-recommends zlib1g-dev libjpeg62-turbo-dev build-essential && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    pip uninstall -y pillow && \
    CC="cc -mavx2" pip install -U --force-reinstall pillow-simd; \
    fi

FROM python:3.10-slim as final

ARG VERSION
ARG RELEASE

LABEL name="bmaltais/kohya_ss" \
    vendor="bmaltais" \
    maintainer="bmaltais" \
    # Dockerfile source repository
    url="https://github.com/bmaltais/kohya_ss" \
    version=${VERSION} \
    # This should be a number, incremented with each change
    release=${RELEASE} \
    io.k8s.display-name="kohya_ss" \
    summary="Kohya's GUI: This repository provides a Gradio GUI for Kohya's Stable Diffusion trainers(https://github.com/kohya-ss/sd-scripts)." \
    description="The GUI allows you to set the training parameters and generate and run the required CLI commands to train the model. This is the docker image for Kohya's GUI. For more information about this tool, please visit the following website: https://github.com/bmaltais/kohya_ss."

# Install runtime dependencies
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    apt-get -qq update && \
    apt-get install -y --no-install-recommends libgl1 libglib2.0-0 libjpeg62 libtcl8.6 libtk8.6 libgoogle-perftools-dev dumb-init && \
    apt-get install -y --no-install-recommends rsync git htop wget curl && \
    apt-get clean

RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists/ \ 
    set -x && \
    apt-get -qq update && \
    apt-get install -qq -y openssh-server tmux --no-install-recommends

# Fix missing libnvinfer7
RUN ln -s /usr/lib/x86_64-linux-gnu/libnvinfer.so /usr/lib/x86_64-linux-gnu/libnvinfer.so.7 && \
    ln -s /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so.7



# Create directories with correct permissions
RUN install -d -m 775 -o 0 -g 0 /dataset && \
    install -d -m 775 -o 0 -g 0 /licenses && \
    install -d -m 775 -o 0 -g 0 /app

COPY --chown=0:0 --chmod=775 \
    --from=build /root/.local /root/.local

WORKDIR /app
COPY --chown=0:0 --chmod=775 . .

# Copy licenses (OpenShift Policy)
COPY --chmod=775 LICENSE.md /licenses/LICENSE.md

ADD docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN set -x && \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh
RUN echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config && \
    mkdir /var/run/sshd && \
    echo "root:root" | chpasswd

ENV PATH="/root/.local/bin:$PATH"
ENV PYTHONPATH="${PYTHONPATH}:/root/.local/lib/python3.10/site-packages" 
ENV LD_PRELOAD=libtcmalloc.so
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
RUN cat <<EOF > /etc/profile.d/00-env.sh
export PATH="/root/.local/bin:\$PATH"
export PYTHONPATH="\${PYTHONPATH}:/root/.local/lib/python3.10/site-packages"
export LD_PRELOAD=libtcmalloc.so
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
EOF
VOLUME [ "/dataset" ]

# 7860: Kohya GUI
# 6006: TensorBoard
# 22: SSH
EXPOSE 7860 6006 22

STOPSIGNAL SIGINT

# Use dumb-init as PID 1 to handle signals properly
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["python3", "kohya_gui.py", "--listen", "0.0.0.0", "--server_port", "7860"]