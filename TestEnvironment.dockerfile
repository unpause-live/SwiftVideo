FROM ubuntu:18.04

RUN apt update && apt-get install -y build-essential wget gnupg2 git

RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 8CF63AD3F06FC659 && \
    cp /etc/apt/sources.list /etc/apt/sources.list.save && \
    echo "deb http://ppa.launchpad.net/jonathonf/ffmpeg-4/ubuntu bionic main" > /etc/apt/sources.list.d/jonathonf-ubuntu-ffmpeg-4-disco.list && \
    echo "deb http://cz.archive.ubuntu.com/ubuntu bionic main universe" >> /etc/apt/sources.list && \
    echo "deb-src http://archive.ubuntu.com/ubuntu bionic universe" >> /etc/apt/sources.list && \
    apt update && \
    apt-get install -y --no-install-recommends libavcodec-dev libavdevice-dev libavformat-dev libavfilter-dev libavutil-dev libswscale-dev && \
    cp /etc/apt/sources.list.save /etc/apt/sources.list && \
    rm /etc/apt/sources.list.d/jonathonf-ubuntu-ffmpeg-4-disco.list

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

RUN rm -rf /var/lib/apt/lists/*
