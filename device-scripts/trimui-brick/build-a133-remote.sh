#!/usr/bin/env bash
set -euo pipefail

# Build A133 (Trimui Brick) on a remote Fedora Linux machine via SSH.
# Syncs the source tree with rsync, builds natively on the remote host,
# and can copy artifacts back to the local machine.
#
# Usage: ./build-a133-remote.sh [command]
# Examples:
#   ./build-a133-remote.sh              # sync source + full build
#   ./build-a133-remote.sh shell        # open an SSH shell in the build dir
#   ./build-a133-remote.sh copy         # copy build artifacts to local host
#   ./build-a133-remote.sh clean        # remove remote build output
#   ./build-a133-remote.sh deps         # install build dependencies on remote
#   ./build-a133-remote.sh sync         # sync source only (no build)

COMMAND="${1:-build}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="a133"
OUTPUT_DIR="${PROJECT_DIR}/output"

# Remote host settings
REMOTE_HOST="acorbellini@pc.local"
REMOTE_HOME="$(ssh "${REMOTE_HOST}" 'echo $HOME')"
REMOTE_PROJECT_DIR="${REMOTE_HOME}/knulli-distribution"
REMOTE_OUTPUT_DIR="${REMOTE_HOME}/knulli-output/${TARGET}"

# Number of parallel jobs (auto-detect remote CPU count)
JOBS="${JOBS:-}"

sync_source() {
    echo "==> Syncing source tree to ${REMOTE_HOST}..."
    rsync -az --delete \
        --exclude='output/' \
        --exclude='buildroot-ccache/' \
        --exclude='dl/' \
        --exclude='.git/objects/' \
        --filter=':- .gitignore' \
        "${PROJECT_DIR}/" \
        "${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/"
    # Sync buildroot separately (it's a submodule)
    rsync -az --delete \
        --exclude='.git/objects/' \
        --exclude='dl/' \
        --filter=':- .gitignore' \
        "${PROJECT_DIR}/buildroot/" \
        "${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/buildroot/"
    echo "==> Source sync complete."
}

get_jobs() {
    if [ -n "${JOBS}" ]; then
        echo "${JOBS}"
    else
        ssh "${REMOTE_HOST}" nproc
    fi
}

case "${COMMAND}" in
    deps)
        echo "==> Installing build dependencies on ${REMOTE_HOST}..."
        ssh -t "${REMOTE_HOST}" bash -ls <<'DEPS_EOF'
sudo dnf install -y \
    gcc gcc-c++ make cmake git \
    ncurses-devel openssl-devel \
    mercurial texinfo zip pigz xdelta \
    java-latest-openjdk-headless \
    ImageMagick subversion \
    autoconf automake bison flex \
    python3-scons glib2-devel \
    bc mtools uboot-tools \
    wget cpio dosfstools \
    libtool rsync dtc \
    gettext glibc-langpack-en \
    graphviz python3 \
    patch perl perl-ExtUtils-MakeMaker \
    glibc-devel.i686 libstdc++-devel.i686 \
    glibc.i686 ncurses-libs.i686 libstdc++.i686 \
    lzip unzip file which diffutils \
    libatomic libatomic-static
echo "==> Dependencies installed."
DEPS_EOF
        ;;
    sync)
        sync_source
        ;;
    build)
        sync_source

        NPROC=$(get_jobs)
        echo "==> Building ${TARGET} on ${REMOTE_HOST} with -j${NPROC}..."

        # Generate defconfig, configure if needed, and build
        ssh "${REMOTE_HOST}" bash -ls <<BUILD_EOF
set -euo pipefail
export FORCE_UNSAFE_CONFIGURE=1
export LANG=en_US.UTF-8

# GCC 15 changed default C standard to gnu23, which breaks older gnulib,
# kernel host tools, and other packages that use C identifiers like
# "constexpr" that became keywords in C23. Create a gcc wrapper that
# forces gnu17 so it applies everywhere (HOSTCC, kernel scripts, etc).
GCC_MAJOR=\$(gcc -dumpversion | cut -d. -f1)
if [ "\${GCC_MAJOR}" -ge 15 ] 2>/dev/null; then
    WRAPPER_DIR="/tmp/knulli-gcc-wrapper"
    mkdir -p "\${WRAPPER_DIR}"
    cat > "\${WRAPPER_DIR}/gcc" <<'GWEOF'
#!/bin/sh
exec /usr/bin/gcc -std=gnu17 "\$@"
GWEOF
    chmod +x "\${WRAPPER_DIR}/gcc"
    # Only wrap gcc (C), not g++ (C++ doesn't have the same issue)
    ln -sf /usr/bin/g++ "\${WRAPPER_DIR}/g++"
    export PATH="\${WRAPPER_DIR}:\${PATH}"
fi

cd "${REMOTE_PROJECT_DIR}"
mkdir -p "${REMOTE_OUTPUT_DIR}"

# Generate defconfig
echo "==> Generating defconfig for ${TARGET}..."
configs/createDefconfig.sh configs/knulli-${TARGET}

# Configure if no .config exists yet
if [ ! -f "${REMOTE_OUTPUT_DIR}/.config" ]; then
    echo "==> Configuring buildroot for ${TARGET}..."
    make O="${REMOTE_OUTPUT_DIR}" \
        BR2_EXTERNAL="${REMOTE_PROJECT_DIR}" \
        -C "${REMOTE_PROJECT_DIR}/buildroot" \
        knulli-${TARGET}_defconfig
else
    echo "==> Existing config found, resuming build..."
fi

echo "==> Starting build with -j${NPROC}. This may take several hours on a first build."
make O="${REMOTE_OUTPUT_DIR}" \
    BR2_EXTERNAL="${REMOTE_PROJECT_DIR}" \
    -C "${REMOTE_PROJECT_DIR}/buildroot" \
    -j${NPROC}
BUILD_EOF
        ;;
    shell)
        echo "==> Opening SSH shell on ${REMOTE_HOST}..."
        ssh -t "${REMOTE_HOST}" "cd ${REMOTE_PROJECT_DIR} && export FORCE_UNSAFE_CONFIGURE=1 && exec bash -l"
        ;;
    copy)
        echo "==> Copying trimui-brick images to ${OUTPUT_DIR}/${TARGET}/..."
        mkdir -p "${OUTPUT_DIR}/${TARGET}"
        rsync -avz --progress \
            "${REMOTE_HOST}:${REMOTE_OUTPUT_DIR}/images/knulli/images/trimui-brick/" \
            "${OUTPUT_DIR}/${TARGET}/" \
            && echo "Done." \
            || echo "No images found yet."
        ;;
    clean)
        echo "==> Removing remote build output at ${REMOTE_HOST}:${REMOTE_OUTPUT_DIR}..."
        ssh "${REMOTE_HOST}" "rm -rf ${REMOTE_OUTPUT_DIR}"
        echo "==> Done. Run './build-a133-remote.sh' to start a fresh build."
        ;;
    *)
        sync_source
        NPROC=$(get_jobs)
        echo "==> Running: make ${COMMAND} on ${REMOTE_HOST}..."
        ssh "${REMOTE_HOST}" bash -ls <<CUSTOM_EOF
set -euo pipefail
export FORCE_UNSAFE_CONFIGURE=1
export LANG=en_US.UTF-8

# GCC 15 changed default C standard to gnu23, which breaks older gnulib,
# kernel host tools, and other packages that use C identifiers like
# "constexpr" that became keywords in C23. Create a gcc wrapper that
# forces gnu17 so it applies everywhere (HOSTCC, kernel scripts, etc).
GCC_MAJOR=\$(gcc -dumpversion | cut -d. -f1)
if [ "\${GCC_MAJOR}" -ge 15 ] 2>/dev/null; then
    WRAPPER_DIR="/tmp/knulli-gcc-wrapper"
    mkdir -p "\${WRAPPER_DIR}"
    cat > "\${WRAPPER_DIR}/gcc" <<'GWEOF'
#!/bin/sh
exec /usr/bin/gcc -std=gnu17 "\$@"
GWEOF
    chmod +x "\${WRAPPER_DIR}/gcc"
    # Only wrap gcc (C), not g++ (C++ doesn't have the same issue)
    ln -sf /usr/bin/g++ "\${WRAPPER_DIR}/g++"
    export PATH="\${WRAPPER_DIR}:\${PATH}"
fi
cd "${REMOTE_PROJECT_DIR}"
mkdir -p "${REMOTE_OUTPUT_DIR}"
make O="${REMOTE_OUTPUT_DIR}" \
    BR2_EXTERNAL="${REMOTE_PROJECT_DIR}" \
    -C "${REMOTE_PROJECT_DIR}/buildroot" \
    -j${NPROC} \
    ${COMMAND}
CUSTOM_EOF
        ;;
esac
