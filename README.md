# Static `libstdc++`

Generate tarballs for GCC's `libstdc++` for many targets.

## What is this?

This script uses [crosstool-ng](https://crosstool-ng.github.io/) to generate
a basic GCC cross-compiler, and uses this to compile libstdc++. It then packages
the generated artifacts, removes unnecessary files, and generates a tarball with
only the static `libstdc++`/`libsupc++` libraries and GNU STL headers.

## Why?

The intended use-case is with
[zig cc](https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html).
The Zig compiler ships with enough sources to compile LLVM's `libc++` and `compiler_rt`
on-demand for the given target, which is extremely useful. However, in cases
where linking with pre-compiled shared libraries that use the GNU STL ABI is
required, this is not sufficient. `zig cc` does not support Clang's
`-stdlib=libstdc++` flag, because there is no reasonable way to support it with
the way `zig cc` works (
["Building libstdc++ separately from the rest of GCC is not supported."](https://gcc.gnu.org/onlinedocs/libstdc++/manual/setup.html))

Doing `-nostdinc++ -nostdlib++ -I... -L... -lstdc++` *works*; however, it:
- Adds system dependencies to your build (`zig cc` is mostly-hermetic)
- Does not work when cross-compiling to other targets

The use-case I am trying to solve involves using
[`hermetic_cc_toolchain`](https://github.com/uber/hermetic_cc_toolchain) together
with Bazel to cross-compile a project. However, since there are pre-existing
binaries with the GNU STL ABI as mentioned above, this becomes impossible. This
project is intended to solve this.

Because the main incompatibility is the STL ABI itself and not the other bits,
the intention is to use the smallest amount of GNU libraries possible. To
achieve this, this project strips down a standard `libstdc++` install to only
the library files and includes required. It also enables the use of `experimental`
headers which are not present in `libc++` for legacy codebases.

Once included, the final configuration looks like:
- `libunwind` from LLVM (replacing `gcc_s`/`gcc_eh`)
- `compiler_rt` from LLVM (replacing `libgcc`)
- `libstdc++` from GNU
- `libsupc++` from GNU

Thanks to the Itanum exception handling ABI, this mix-match configuration seems
to work.

## Requirements

You need the following on your system:

- `bash`
- `coreutils` (GNU coreutils tested)
- `wget` or `curl`
- Either Clang or GCC (in essence, a C/C++ compiler that can compile GCC)

## Usage

Just running `./build.sh` should be sufficient. Currently, tarballs for the
following targets are built:

- `aarch64-linux-gnu`
- `x86_64-linux-gnu`

TODO: Add documentation on how to use this together with `zig cc` (requires further testing)

## License

Copyright &copy; 2024, sin-ack. This software is released under the GNU General Public License, version 3.
