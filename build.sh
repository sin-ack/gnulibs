#!/usr/bin/env bash

# Copyright (c) 2024, sin-ack <sin-ack@protonmail.com>
# SPDX-License-Identifier: GPL-3.0-only
# vim: ts=4 sw=4 et :

set -euo pipefail

### Configuration
# The target platforms. Currently only limited to the crosstool-ng
# samples present in the configs directory.
TARGETS=(
    aarch64-linux-gnu
    x86_64-linux-gnu
)
# GCC version to build against. Must match the default version in
# the crosstool-ng version used.
GCC_VERSION="13.2.0"

### Environment variables

DEBUG="${DEBUG:-}"

### Constants

BASE_DIR="$(realpath "$(dirname "$0")")"
WORK_DIR="${BASE_DIR}/work"
OUT_DIR="${BASE_DIR}/out"

# crosstool-ng configuration
CROSSTOOL_URL="http://crosstool-ng.org/download/crosstool-ng/crosstool-ng-1.26.0.tar.xz"
CROSSTOOL_SHA256="e8ce69c5c8ca8d904e6923ccf86c53576761b9cf219e2e69235b139c8e1b74fc"
CROSSTOOL_SOURCE="${WORK_DIR}/src-crosstool"
CROSSTOOL_BUILD="${WORK_DIR}/build-host-crosstool"
CROSSTOOL_PREFIX="${WORK_DIR}/prefix-host-crosstool"
CROSSTOOL_EXE="${CROSSTOOL_PREFIX}/bin/ct-ng"

### Meat of the script

function determine_host_triplet {
    local host_triplet
    local cc_exe

    if which cc >/dev/null; then
        cc_exe="$(which cc)"
    elif which gcc >/dev/null; then
        cc_exe="$(which gcc)"
    elif which clang >/dev/null; then
        cc_exe="$(which clang)"
    else
        echo "!!! Could not find any C compiler on your system (looked for cc, gcc, clang)!" >&2
        echo "!!! Please install one (you're gonna need it for the remaining steps anyway)." >&2
        exit 1
    fi

    # In case the compiler does not understand -dumpmachine, we don't want to
    # bail silently.
    host_triplet="$(
        set +e
        if ! host_triplet="$("${cc_exe}" -dumpmachine)"; then
            echo "!!! Your compiler (${cc_exe}) does not understand -dumpmachine! Please make sure you have GCC or Clang installed." >&2
            exit 1
        fi
        echo "${host_triplet}"
    )"

    # It's possible that the host "triplet" includes a vendor part, which we don't
    # want to include in the triplet. Strip it away.
    host_triplet="$(echo "${host_triplet}" | awk -F- '{ if (NF == 4) { print $1"-"$3"-"$4 } else { print $1"-"$2"-"$3 } }')"
    echo "${host_triplet}"
}

function download_file {
    local url
    local target
    local sha256
    local actual_sha256

    url="$1"
    target="$2"
    sha256="$3"

    if [[ -f "${target}" ]]; then
        actual_sha256="$(sha256sum "${target}" | cut -d' ' -f1)"
        if [[ "${actual_sha256}" = "${sha256}" ]]; then
            # The file was previously downloaded, reuse it.
            return
        else
            # Either the file is corrupted, or the hash changed.
            rm -f "${target}"
        fi
    fi

    if which wget >/dev/null; then
        wget -O "${target}" "${url}"
    elif which curl >/dev/null; then
        curl -fsSL -o "${target}" "${url}"
    else
        echo "!!! Neither curl nor wget are present on your system. Please install one of them." >&2
        exit 1
    fi

    actual_sha256="$(sha256sum "${target}" | cut -d' ' -f1)"
    if [[ "${actual_sha256}" != "${sha256}" ]]; then
        echo "!!! Checksum verification for ${target} failed!" >&2
        echo "!!!   Expected: ${sha256}" >&2
        echo "!!!   Actual:   ${actual_sha256}" >&2
        exit 1
    fi
}

function build_host_crosstool_ng {
    # If host crosstool is built, then do nothing.
    if [[ -f "${CROSSTOOL_EXE}" ]]; then return; fi

    # Download and extract crosstool sources if needed.
    if [[ ! -d "${CROSSTOOL_SOURCE}" ]]; then
        echo ">>> Downloading $(basename "${CROSSTOOL_URL}")..."
        download_file "${CROSSTOOL_URL}" "${WORK_DIR}/crosstool.tar.xz" "${CROSSTOOL_SHA256}"

        echo ">>> Extracting crosstool-ng sources..."
        mkdir -p "${CROSSTOOL_SOURCE}"
        tar -C "${CROSSTOOL_SOURCE}" --strip-components 1 -xf "${WORK_DIR}/crosstool.tar.xz"
    fi

    # Wipe the crosstool build/prefix in case of a broken install.
    rm -rf "${CROSSTOOL_BUILD}" "${CROSSTOOL_PREFIX}"

    echo ">>> Building crosstool-ng for host..."
    mkdir -p "${CROSSTOOL_BUILD}"
    mkdir -p "${CROSSTOOL_PREFIX}"
    (cd "${CROSSTOOL_BUILD}" && "${CROSSTOOL_SOURCE}/configure" --prefix="${CROSSTOOL_PREFIX}")
    make -C "${CROSSTOOL_BUILD}" "-j$(nproc)"
    make -C "${CROSSTOOL_BUILD}" install
}

function needs_to_build_with_crosstool {
    local target
    local version

    target="$1"
    version="$2"

    if [[ -d "${WORK_DIR}/prefix-${version}-${target}" ]]; then
        echo ">>> Prefix already built, using it directly."
        return 1
    else
        echo ">>> Prefix not found, building with crosstool-ng."
        return 0
    fi
}

function generate_config_for_target {
    local target

    target="$1"

    if [[ -a "${WORK_DIR}/.config" ]]; then
        echo ">>> .config exists already, not generating a new one."
    else
        echo ">>> Generating a new .config for ${target}..."
        (cd "${BASE_DIR}" && "${CROSSTOOL_EXE}" "${target}")
        # samples/ directory is at the repository root, and ct-ng will place
        # the generated .config file in the base directory.
        mv "${BASE_DIR}/.config" "${WORK_DIR}/.config"
    fi
}

function build_with_crosstool {
    local target
    local version

    target="$1"
    version="$2"

    # Build until the point where we would build the bootstrap GCC.
    # We don't care about the final target compiler, we only care to
    # build until we create a suitable environment where we can build
    # the GNU libraries.
    echo ">>> Performing crosstool build..."
    (
        cd "${WORK_DIR}"
        if ! "${CROSSTOOL_EXE}" +libc_main; then
            echo "!!! Crosstool-ng build failed!" >&2
            # If we had already partially built the prefix, clean it up so that
            # the next run doesn't try to use it.
            rm -rf "${WORK_DIR}/prefix-${version}-${target}"
            exit 1
        fi
    )

    # Remove .config after a successful build so that the next build can use
    # a different configuration.
    rm -f "${WORK_DIR}/.config"
}

function configure_target_gcc {
    local target
    local version
    local host_triplet

    target="$1"
    version="$2"
    host_triplet="$3"

    echo ">>> Configuring GCC ${version} for ${target}..."
    rm -rf "${WORK_DIR}/build-${version}-${target}"
    mkdir -p "${WORK_DIR}/build-${version}-${target}"

    # Reference: https://github.com/crosstool-ng/crosstool-ng/blob/efcfd1abb6d7bc320ceed062352e0d5bebe6bf1f/scripts/build/cc/gcc.sh#L238
    (cd "${WORK_DIR}/build-${version}-${target}" && \
        "${WORK_DIR}/.build/${target}/src/gcc/configure" \
            --build="${host_triplet}" \
            --host="${host_triplet}" \
            --target="${target}" \
            --prefix="${WORK_DIR}/prefix-${version}-${target}" \
            --exec_prefix="${WORK_DIR}/prefix-${version}-${target}" \
            --with-sysroot="${WORK_DIR}/prefix-${version}-${target}/${target}/sysroot" \
            --with-local-prefix="${WORK_DIR}/prefix-${version}-${target}/${target}/sysroot" \
            --enable-gcc \
            --enable-threads=posix \
            --disable-multilib \
            --disable-libgomp \
            --disable-libmudflap \
            --disable-libmpx \
            --disable-libssp \
            --disable-libquadmath \
            --disable-libquadmath-support \
            --enable-libstdcxx-verbose \
            --enable-long-long \
            --enable-languages=c,c++)
}

function build_libstdcxx {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Building stage1 host GCC with threads support..."
    echo ">>> (This is required because the crosstool-built GCC is built with newlib,"
    echo ">>> because at that point we didn't have a GCC to build Glibc with yet.)"
    # Steps taken from gcc.sh (same link as above). This is required to make target libgcc builds work.
    (cd "${WORK_DIR}/build-${version}-${target}" && \
        make "-j$(nproc)" configure-gcc configure-libcpp configure-build-libiberty && \
        make "-j$(nproc)" all-libcpp all-build-libcpp all-build-libiberty && \
        make "-j$(nproc)" configure-libdecnumber && \
        make "-j$(nproc)" -C libdecnumber libdecnumber.a && \
        make "-j$(nproc)" configure-libbacktrace && \
        make "-j$(nproc)" -C libbacktrace && \
        make "-j$(nproc)" -C gcc libgcc.mvars && \
        make "-j$(nproc)" all-gcc)
    echo ">>> Building target libgcc..."
    (cd "${WORK_DIR}/build-${version}-${target}" && \
        make "-j$(nproc)" all-target-libgcc)
    echo ">>> Building target libstdc++..."
    (cd "${WORK_DIR}/build-${version}-${target}" && \
        make "-j$(nproc)" all-target-libstdc++-v3)
    echo ">>> Building target libatomic..."
    (cd "${WORK_DIR}/build-${version}-${target}" && \
        make "-j$(nproc)" all-target-libatomic)
}

function install_libstdcxx {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Installing GNU libraries into a target folder..."
    rm -rf "${WORK_DIR}/install-${version}-${target}"
    rm -rf "${WORK_DIR}/package-${version}-${target}"
    mkdir -p "${WORK_DIR}/package-${version}-${target}"
    # NOTE: Setting DESTDIR produces something like:
    #           ${WORK_DIR}/install-${version}-${target}/${WORK_DIR}/prefix-${version}-${target}
    #       because DESTDIR is prepended to the prefix. There's no easy way
    #       to change that behavior, so we move the actual contents after the
    #       install step.
    make -C "${WORK_DIR}/build-${version}-${target}/${target}/libgcc" \
        DESTDIR="${WORK_DIR}/install-${version}-${target}" \
        install
    make -C "${WORK_DIR}/build-${version}-${target}/${target}/libstdc++-v3" \
        DESTDIR="${WORK_DIR}/install-${version}-${target}" \
        install
    make -C "${WORK_DIR}/build-${version}-${target}/${target}/libatomic" \
        DESTDIR="${WORK_DIR}/install-${version}-${target}" \
        install
    mv "${WORK_DIR}/install-${version}-${target}/${WORK_DIR}/prefix-${version}-${target}"/* "${WORK_DIR}/package-${version}-${target}"
}

function package_libstdcxx {
    local target
    local version
    local package_root_dir

    target="$1"
    version="$2"

    echo ">>> Packaging GNU libraries..."

    # The install targets of libstdc++/libstdc++ creates the following structure:
    # - <prefix>/
    #   - <target>/ (when host != target)
    #     - include/c++/${version}/ (the actual headers)
    #     - lib/ (contains libstdc++ .a/.so files on 32-bit targets)
    #       - gcc/${target}/${version}/ (contains libgcc .a/.so files)
    #     - lib64/ (contains libstdc++ .a/.so files on 64-bit targets)
    #   - share/ (extra files we don't care about)
    #
    # We want to create the following structure:
    # - gnu-${version}-${target}.tar.xz
    #   - lib/     (.a/.so files)
    #   - include/ (the headers, without the intermediate directories)

    package_root_dir="${WORK_DIR}/package-${version}-${target}"

    # NOTE: This needs to be done conditionally because when host == target,
    #       autotools will use the prefix directly instead of exectoolsdir,
    #       so the intermediate directory won't be present. We need to normalize
    #       only for cases where host != target.
    if [[ -d "${package_root_dir}/${target}" ]]; then
        echo ">>>   Moving up the ${target} directory"
        rm -d "${package_root_dir}/${target}/lib"
        mv "${package_root_dir}/${target}"/* "${package_root_dir}"
        rm -d "${package_root_dir}/${target}"
    fi

    if [[ -d "${package_root_dir}/lib64" ]]; then
        echo ">>>   Moving files from lib64 to lib"
        mv "${package_root_dir}/lib64"/* "${package_root_dir}/lib"
        rm -d "${package_root_dir}/lib64"
    fi

    echo ">>>   Moving up libgcc files to lib"
    mv "${package_root_dir}/lib/gcc/${target}/${version}"/* "${package_root_dir}/lib"
    rm -rd "${package_root_dir}/lib/gcc"

    echo ">>>   Removing unnecessary files"
    # Explanation for each line:
    # - *.la: libtool files. Since we're directly going to be passing -L flags
    #   to ld we don't need these.
    # - *.py: GDB pretty-printer files.
    # - lib/include: Includes unnecessary headers for libgcov and libunwind.
    # - lib/crt*.o: The C runtime startup/shutdown files. The C runtime already
    #   includes these files, so they are unnecessary.
    # - lib/libgcov.a: We don't need the static libgcov library.
    rm -fv \
        "${package_root_dir}/lib/"*.la \
        "${package_root_dir}/lib/"*.py \
        "${package_root_dir}/lib/include/"* \
        "${package_root_dir}/lib/"crt*.o \
        "${package_root_dir}/lib/"libgcov.a
    rm -vd "${package_root_dir}/lib/include"

    echo ">>>   Moving up the include/c++/${version} directory to include"
    mv "${package_root_dir}/include" "${package_root_dir}/include-tmp"
    mv "${package_root_dir}/include-tmp/c++/${version}" "${package_root_dir}/include"
    rm -rd "${package_root_dir}/include-tmp"

    echo ">>>   Running tar"
    mkdir -p "${OUT_DIR}"
    tar --transform "flags=r;s#^#gnu-${version}-${target}/#" -cJf "${OUT_DIR}/gnu-${version}-${target}.tar.xz" -C "${package_root_dir}" "lib" "include"
}

function cleanup {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Cleaning up..."
    if [[ -f "${WORK_DIR}/.config" ]]; then
        echo ">>>   Removing .config"
        rm -f "${WORK_DIR}/.config"
    fi
}

function build {
    local target
    local version
    local host_triplet

    target="$1"
    version="$2"
    host_triplet="$(determine_host_triplet)"

    echo ">>> Building GNU libraries ${version} for target ${target}..."
    mkdir -p "${WORK_DIR}"

    build_host_crosstool_ng "${target}"
    if needs_to_build_with_crosstool "${target}" "${version}"; then
        generate_config_for_target "${target}"
        build_with_crosstool "${target}" "${version}"
    fi
    configure_target_gcc "${target}" "${version}" "${host_triplet}"
    build_libstdcxx "${target}" "${version}"
    install_libstdcxx "${target}" "${version}"
    package_libstdcxx "${target}" "${version}"

    cleanup "${target}" "${version}"
    echo ">>> Package ready at out/gnu-${version}-${target}.tar.xz."
}

trap cleanup ERR
for target in "${TARGETS[@]}"; do
    build "${target}" "${GCC_VERSION}"
done
