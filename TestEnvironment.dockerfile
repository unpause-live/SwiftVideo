FROM jrottenberg/ffmpeg:4.2-ubuntu

RUN apt update && apt-get install -y software-properties-common build-essential wget gnupg2 git

RUN export SWIFT_VER=swift-5.1.1-RELEASE && \
    export SWIFT_VER_LOWER=$(echo $SWIFT_VER | tr '[:upper:]' '[:lower:]') && \
    mkdir -p /tmp/swift && \
    cd /tmp/swift && \
        wget --quiet https://swift.org/builds/$SWIFT_VER_LOWER/ubuntu1804/$SWIFT_VER/$SWIFT_VER-ubuntu18.04.tar.gz && \
        tar xzf $SWIFT_VER-ubuntu18.04.tar.gz && \
        cd $SWIFT_VER-ubuntu18.04 && \
            cp -R usr/* /usr/ && \
        cd .. &&  \
    cd / && \
    rm -rf /tmp/swift

RUN apt-get install -y ocl-icd-opencl-dev libfreetype6-dev libbsd-dev pkg-config

RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/cuda-ubuntu1804.pin && \
    mv cuda-ubuntu1804.pin /etc/apt/preferences.d/cuda-repository-pin-600 && \
    apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub && \
    add-apt-repository "deb http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/ /" && \
    apt-get update && \
    apt-get install -y cuda-libraries-dev-10-2

RUN rm -rf /var/lib/apt/lists/*
