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
    # Build until the point where we would build the bootstrap GCC.
    # We don't care about the final target compiler, we only care to
    # build until we create a suitable environment where we can build
    # libstdc++.
    echo ">>> Performing crosstool build..."
    (cd "${WORK_DIR}" && "${CROSSTOOL_EXE}" +libc_main)
}

function configure_target_gcc {
    local target
    local version
    local host_triplet
    local bootstrap_cc
    local bootstrap_cxx
    local bootstrap_cxxflags

    target="$1"
    version="$2"
    host_triplet="$3"

    echo ">>> Configuring GCC ${version} for ${target}..."
    mkdir -p "${WORK_DIR}/build-libstdc++-${version}-${target}"

    # NOTE: A little explanation about what's happening below:
    #
    #       Using the .config file, we make the "bootstrap gcc" step
    #       also produce a C++ compiler for us. We then use the
    #       xgcc/xg++ binaries to build *only* libstdc++ (using the
    #       --disable-gcc argument). The extra arguments and the
    #       interleaved make arguments are copied directly from the
    #       autoconf files of gcc (apparently the gcc maintainers
    #       saw it fit to add these arguments directly into a
    #       configuration parameter where you're expected to only
    #       pass a binary). This gives us a similar setup to if
    #       we had used the bootstrap GCC directory directly, but
    #       with a clean build directory.
    #
    #       A funny side effect of passing these arguments directly
    #       is that you'll get "dirname: invalid option -- -B" in
    #       the configure output, but things will work anyway,
    #       providing further proof that GCC is a Jenga tower of
    #       hacks that manage to produce a working compiler.
    bootstrap_cc="${WORK_DIR}/.build/${target}/build/build-cc-gcc-core/gcc/xgcc"
    bootstrap_cxx="${WORK_DIR}/.build/${target}/build/build-cc-gcc-core/gcc/xg++"
    # NOTE: -nostdlib++ is required to pass some conftests since they compile
    #       C++ code. We can't add it to LDFLAGS_FOR_TARGET because it breaks
    #       C compilation.
    # XXX: The -L parameters are explicitly intended to be left untouched, since
    #      they are interpreted by sub-makes.
    # shellcheck disable=SC2016
    bootstrap_cxxflags='-nostdinc++ -nostdlib++ -shared-libgcc -L$$r/$(TARGET_SUBDIR)/libstdc++-v3/src -L$$r/$(TARGET_SUBDIR)/libstdc++-v3/src/.libs -L$$r/$(TARGET_SUBDIR)/libstdc++-v3/libsupc++/.libs'

    (cd "${WORK_DIR}/build-libstdc++-${version}-${target}" && \
        CC_FOR_TARGET="${bootstrap_cc} -B$(dirname "${bootstrap_cc}")/" \
        CXX_FOR_TARGET="${bootstrap_cxx} -B$(dirname "${bootstrap_cxx}")/" \
        CXXFLAGS_FOR_TARGET="${bootstrap_cxxflags}" \
        "${WORK_DIR}/.build/${target}/src/gcc/configure" \
            --build="${host_triplet}" \
            --host="${host_triplet}" \
            --target="${target}" \
            --prefix="${WORK_DIR}/prefix-${version}-${target}" \
            --exec_prefix="${WORK_DIR}/prefix-${version}-${target}" \
            --with-sysroot="${WORK_DIR}/prefix-${version}-${target}/${target}/sysroot" \
            --with-local-prefix="${WORK_DIR}/prefix-${version}-${target}/${target}/sysroot" \
            --disable-gcc \
            --disable-multilib \
            --enable-libstdcxx-verbose \
            --enable-long-long)
}

function build_libstdcxx {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Building libstdc++ from GCC sources..."
    (cd "${WORK_DIR}/build-libstdc++-${version}-${target}" && \
        make "-j$(nproc)" all-target-libstdc++-v3)
}

function install_libstdcxx {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Installing libstdc++ into a target folder..."
    mkdir -p "${WORK_DIR}/package-${version}-${target}"
    # NOTE: Setting DESTDIR produces something like:
    #           ${WORK_DIR}/install-${version}-${target}/${WORK_DIR}/prefix-${version}-${target}
    #       because DESTDIR is prepended to the prefix. There's no easy way
    #       to change that behavior, so we move the actual contents after the
    #       install step.
    make -C "${WORK_DIR}/build-libstdc++-${version}-${target}/${target}/libstdc++-v3" \
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

    echo ">>> Packaging libstdc++..."

    # The install target of libstdc++ creates the following structure:
    # - <prefix>/
    #   - <target>/ (when host != target)
    #     - include/c++/${version}/ (the actual headers)
    #     - lib/ (empty on 64-bit targets, otherwise contains .a/.so files)
    #     - lib64/ (contains .a/.so files on 64-bit targets)
    #   - share/ (extra files we don't care about)
    #
    # We want to create the following structure:
    # - libstdc++-${version}-${target}.tar.xz
    #   - lib/     (only .a files)
    #   - include/ (the headers, without the intermediate directories)

    package_root_dir="${WORK_DIR}/package-${version}-${target}"

    # NOTE: This needs to be done conditionally because when host == target,
    #       autotools will use the prefix directly instead of exectoolsdir,
    #       so the intermediate directory won't be present. We need to normalize
    #       only for cases where host != target.
    if [[ -d "${package_root_dir}/${target}" ]]; then
        echo ">>>   Moving up the ${target} directory"
        mv "${package_root_dir}/${target}"/* "${package_root_dir}"
        rm -d "${package_root_dir}/${target}"
    fi

    if [[ -d "${package_root_dir}/lib64" ]]; then
        echo ">>>   Moving libraries from lib64 to lib"
        # If this fails, then we have unexpected files in lib on a 64-bit target.
        rm -d "${package_root_dir}/lib"
        mv "${package_root_dir}/lib64" "${package_root_dir}/lib"
    fi

    echo ">>>   Removing unnecessary files"
    # Explanation for each line:
    # - *.la: libtool files. Since we're directly going to be passing -L flags
    #   to ld we don't need these.
    # - *.py: GDB pretty-printer files.
    # - *.so*: Shared libraries. The only shared libraries present here are for
    #   libstdc++ itself, and we intend to use the static version.
    rm -fv \
        "${package_root_dir}/lib/"*.la \
        "${package_root_dir}/lib/"*.py \
        "${package_root_dir}/lib/"*.so*

    echo ">>>   Moving up the include/c++/${version} directory to include"
    mv "${package_root_dir}/include" "${package_root_dir}/include-tmp"
    mv "${package_root_dir}/include-tmp/c++/${version}" "${package_root_dir}/include"
    rm -rd "${package_root_dir}/include-tmp"

    echo ">>>   Running tar"
    mkdir -p "${OUT_DIR}"
    tar --transform "s#^#libstdc++-${version}-${target}/#" -cJf "${OUT_DIR}/libstdc++-${version}-${target}.tar.xz" -C "${package_root_dir}" "lib" "include"
}

function cleanup {
    local target
    local version

    target="$1"
    version="$2"

    echo ">>> Cleaning up..."
    if [[ "${DEBUG}" -eq "" ]]; then
        echo ">>>   Removing packaging directory"
        rm -rf "${WORK_DIR}/package-${version}-${target}"
        echo ">>>   Removing libstdc++ install directory"
        rm -rf "${WORK_DIR}/install-${version}-${target}"
        echo ">>>   Removing libstdc++ build directory"
        rm -rf "${WORK_DIR}/build-libstdc++-${version}-${target}"
        echo ">>>   Removing crosstool-created prefix"
        rm -rf "${WORK_DIR}/prefix-${version}-${target}"
    else
        echo ">>>   Debug mode enabled. Not cleaning work directories."
        echo ">>>     (Note that for builds to succeed you'll need to clean them yourself.)"
    fi

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

    echo ">>> Building libstdc++ ${version} for target ${target}..."
    mkdir -p "${WORK_DIR}"

    build_host_crosstool_ng "${target}"
    generate_config_for_target "${target}"
    build_with_crosstool
    configure_target_gcc "${target}" "${version}" "${host_triplet}"
    build_libstdcxx "${target}" "${version}"
    install_libstdcxx "${target}" "${version}"
    package_libstdcxx "${target}" "${version}"

    cleanup "${target}" "${version}"
    echo ">>> Package ready at out/libstdc++-${version}-${target}.tar.xz."
}

trap cleanup ERR
for target in "${TARGETS[@]}"; do
    build "${target}" "${GCC_VERSION}"
done
