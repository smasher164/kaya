# Linux validation environment for kaya milestone 0. GTK4 development
# libraries, the four validation languages, and Xvfb for a headless
# display. Built and run by tools/validate-linux.sh; the repo is mounted
# at /work and built inside the container (no cross-compilation: the GTK
# libraries live here).
# PINNED BY DIGEST, not by tag. `debian:trixie` is a moving target: the
# same tag resolves to a different image whenever the base is rebuilt,
# so the one lane whose entire toolchain world lives in this file could
# change under a run nobody touched. A digest makes "it passed
# yesterday" mean something, and makes a red lane attributable to a
# change in the repo rather than to Debian.
#
# To move deliberately: docker pull debian:trixie && docker image
# inspect debian:trixie --format '{{index .RepoDigests 0}}', paste it
# here, and re-run the lane so the bump is a reviewed diff.
#
# NOT pinned, deliberately: the apt package versions below. trixie is
# STABLE, so they move only on point releases and security updates —
# slow, and the security half is drift we want. Freezing them would
# mean snapshot.debian.org, which is slow and periodically unavailable,
# and that turns "rebuild the image" into a coin flip. The rolling
# indexes are the ones pinned here and below, because those move hourly.
FROM debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang pkg-config libgtk-4-dev \
    curl ca-certificates git \
    python3 \
    ocaml-nox opam libffi-dev \
    ghc cabal-install \
    xvfb xauth imagemagick x11-utils \
    weston sway ffmpeg \
    librsvg2-common adwaita-icon-theme \
    && rm -rf /var/lib/apt/lists/*

# ctypes-foreign via opam on the system compiler: Debian's ctypes deb
# omits the foreign (libffi) half entirely — its META even dangles.
#
# The repository is pinned to a COMMIT, fetched as that commit's tarball
# rather than as a git remote (opam-repository's history is enormous and
# a clone would dominate the image build). opam-repository is a ROLLING
# index — it moves hourly — so an unpinned `opam install` resolves to
# whatever existed the day the image was rebuilt, transitive
# dependencies included. Pinning the index pins the whole solution
# space, which is the part naming versions below cannot reach.
#
# The explicit versions are the intent on record: pinning only the index
# would let a deliberate index bump quietly change what gets installed.
# With both, moving either one is a diff someone has to write.
# The index goes in as a LOCAL directory: an http opam repository is a
# directory containing index.tar.gz, and a git one would clone
# opam-repository's whole history. Unpacking one commit and pointing
# opam at it is both pinned and fast. The commit id is the content pin —
# no sha256 on the tarball, because GitHub's generated archives are not
# promised to be byte-stable and a hash that changes without the content
# changing is an alarm nobody can act on.
RUN curl -fsSL -o /tmp/opam-repo.tgz \
        https://github.com/ocaml/opam-repository/archive/ae6f88cbf223d078928da4d89e303253ea5df2f0.tar.gz \
    && mkdir -p /opt/opam-repository \
    && tar -C /opt/opam-repository --strip-components=1 -xzf /tmp/opam-repo.tgz \
    && rm /tmp/opam-repo.tgz
RUN opam init -a --bare --disable-sandboxing default /opt/opam-repository \
    && opam switch create default ocaml-system \
    && opam install -y ocamlfind.1.9.8 ctypes.0.24.0 ctypes-foreign.0.24.0 \
        dune.3.24.0 ppxlib.0.38.0
ENV PATH=/root/.opam/default/bin:$PATH

# cabal needs a package index even for local-only builds; fetch it once
# in the image, not per run.
RUN cabal update

# Go 1.27.0 stable (generic methods), pinned by hash; moves in
# lockstep with flake.nix's and deploy-win's pins (the ledger's go pin
# entry).
RUN curl -fsSL -o /tmp/go.tgz https://go.dev/dl/go1.27.0.linux-arm64.tar.gz \
    && echo "51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
ENV PATH=/usr/local/go/bin:$PATH

RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/local/dotnet \
    && rm /tmp/dotnet-install.sh

ENV PATH=/root/.cargo/bin:/usr/local/dotnet:$PATH
# Toolchain policy: clang everywhere (cgo, cc crate).
ENV CC=clang
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

# The desktop JVM tier: headless is enough — the JVM speaks only the
# ring (no AWT; presentation is the native GTK backend in-process).
# A trailing layer deliberately: appending rebuilds in seconds where
# touching the first apt list rebuilds the toolchain world.
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Accessibility: the AT-SPI bus and registry. GTK deliberately exposes
# no getter for accessible properties — the accessible surface IS
# AT-SPI, so reading it any other way would only read kaya's own writes
# back. `expect_ax` therefore reads as a real assistive client would,
# which needs the a11y bus running (at-spi2-core), a session bus for it
# to sit on (dbus), and the GI typelib so a probe/reader can walk the
# tree (gir1.2-atspi-2.0 + python3-gi).
#
# A trailing layer on purpose, per the note above: appending rebuilds in
# seconds where touching the first apt list rebuilds the toolchain world.
RUN apt-get update && apt-get install -y --no-install-recommends \
    at-spi2-core dbus dbus-x11 gir1.2-atspi-2.0 python3-gi \
    && rm -rf /var/lib/apt/lists/*

# libadwaita: AdwNavigationSplitView is GNOME's list-detail component,
# and adopting it is what gives the platform its own collapse animation,
# pane proportions, and separator instead of arithmetic kaya invented.
# The dev package is what the `libadwaita` crate's pkg-config build
# needs; the runtime library rides along with it.
#
# A trailing layer on purpose, per the note above: appending rebuilds in
# seconds where touching the first apt list rebuilds the toolchain world.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libadwaita-1-dev gir1.2-adw-1 \
    && rm -rf /var/lib/apt/lists/*

# Clipboard (docs/clipboard-plan.md §5b): the foreign reader/writer
# pair for both sessions — wl-copy/wl-paste on wayland, xclip on x11 —
# because every clipboard assertion crosses a process boundary;
# wayland-info, the seat probe's tool; and wtype, the virtual-keyboard
# tap that hands a headless-sway client the input serial Wayland
# charges for taking the selection (finding 3 — without it every GDK
# copy is silently dropped by the compositor). The image's imagemagick
# (identify, above) is the foreign decoder for image verdicts.
#
# A trailing layer on purpose, per the note above.
RUN apt-get update && apt-get install -y --no-install-recommends \
    wl-clipboard xclip wtype wayland-utils \
    && rm -rf /var/lib/apt/lists/*

# The undo milestone's typing verb (docs/undo-plan.md A8): a scene that
# asserts a field's NATIVE undo history has to fill it the way a user
# does, so `type` delivers real key events and never a text write — a
# write would wipe the very history the scene came to observe (D7).
# Wayland already has its injector here (wtype, above); X11's is XTEST,
# and xdotool is the only client for it in the archive. Measured in this
# image: under bare Xvfb with no window manager GDK already holds the
# input focus, so `xdotool type` lands on the app with no focus command,
# while `xdotool type --window` (XSendEvent) delivers NOTHING to GTK4 —
# GDK4 reads XI2 events and a synthetic core event is not one.
#
# A trailing layer on purpose, per the note above.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xdotool \
    && rm -rf /var/lib/apt/lists/*

# The lane's system-font fixture; docs/traps.md, "The Linux font fixture
# has two settings routes".
RUN apt-get update && apt-get install -y --no-install-recommends \
        fontconfig \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/ibm-plex-sans.zip \
        https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans%401.1.0/ibm-plex-sans.zip \
    && echo "fb365d910566e6d199cc2c15579a7dd9a267128e18431a394ed81f1970c69200  /tmp/ibm-plex-sans.zip" \
        | sha256sum -c - \
    && mkdir -p /tmp/ibm-plex-sans \
        /usr/local/share/fonts/IBM/PlexSans \
        /usr/local/share/doc/ibm-plex-sans \
        /etc/gtk-4.0 \
    && python3 -m zipfile -e /tmp/ibm-plex-sans.zip /tmp/ibm-plex-sans \
    && install -m 0644 \
        /tmp/ibm-plex-sans/ibm-plex-sans/fonts/complete/otf/IBMPlexSans-*.otf \
        /usr/local/share/fonts/IBM/PlexSans/ \
    && install -m 0644 /tmp/ibm-plex-sans/ibm-plex-sans/LICENSE.txt \
        /usr/local/share/doc/ibm-plex-sans/LICENSE.txt \
    && fc-cache -f \
    && test "$(fc-match --format='%{family[0]}|%{style[0]}' 'IBM Plex Sans:style=Regular')" = "IBM Plex Sans|Regular" \
    && test "$(fc-match --format='%{family[0]}|%{style[0]}' 'IBM Plex Sans:style=Bold')" = "IBM Plex Sans|Bold" \
    && rm -rf /tmp/ibm-plex-sans /tmp/ibm-plex-sans.zip

COPY gtk-settings.ini /etc/gtk-4.0/settings.ini
COPY 99-kaya-font.gschema.override \
    /usr/share/glib-2.0/schemas/99-kaya-font.gschema.override
RUN glib-compile-schemas /usr/share/glib-2.0/schemas

WORKDIR /work
