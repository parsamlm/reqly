# The image Reqly for Linux is built and tested in: Ubuntu 24.04, the oldest system it supports,
# with Swift 6.4.1, as CI's core jobs use, and the development packages the app builds against,
# all from Ubuntu's own archive. dbus and gnome-keyring let a test run a real Secret Service, under
# dbus-run-session, and gsettings-desktop-schemas has GNOME's proxy settings.
#   docker build -t reqly-linux-dev:noble linux/docker
FROM swift:6.4.1-noble

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-dev zlib1g-dev pkg-config \
        libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libsecret-1-dev \
        libnss3-tools gsettings-desktop-schemas dbus gnome-keyring ca-certificates \
    && rm -rf /var/lib/apt/lists/*
