# Technas shared Android CI image — Flutter + JDK + Android SDK (+ Ruby for Fastlane).
#
# Single source of truth for every Technas Flutter app (BeautyGo, Éclat d'Or, Rede, …).
# The reusable workflows in this repo (deploy-flutter-android.yml, flutter-apk-smoke.yml)
# check this repo out alongside the caller app and build this image on each run, so we
# never depend on a private registry tag for the mobile builder.
#
# Pin: use a tag that exists on ghcr.io/cirruslabs/flutter (see package versions).
# `stable` tracks Flutter stable channel — reliable pulls in CI; lock a semver tag for reproducibility.
FROM ghcr.io/cirruslabs/flutter:stable

USER root
# Flutter invokes git against /sdks/flutter; when the container runs as a non-root
# user (--user uid:gid from CI), Git 2.35+ rejects "dubious ownership" unless marked safe.
RUN git config --system --add safe.directory '*'

RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    wget \
    unzip \
    ruby \
    ruby-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_SDK_ROOT=/usr/lib/android-sdk
ENV ANDROID_HOME=/usr/lib/android-sdk
ENV PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools"

RUN mkdir -p $ANDROID_SDK_ROOT/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/tools.zip \
    && unzip -q /tmp/tools.zip -d $ANDROID_SDK_ROOT/cmdline-tools \
    && mv $ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools $ANDROID_SDK_ROOT/cmdline-tools/latest \
    && rm /tmp/tools.zip

RUN yes | sdkmanager --licenses \
    && sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"

RUN yes | flutter doctor --android-licenses \
    && flutter config --android-sdk $ANDROID_SDK_ROOT \
    && flutter precache

RUN gem install bundler --no-document

RUN flutter doctor -v
