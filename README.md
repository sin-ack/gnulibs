# gnulibs

Generate tarballs for GNU C++ and support libraries for many targets.

## What is this?

This script uses [crosstool-ng](https://crosstool-ng.github.io/) to generate
a basic GCC cross-compiler, and uses this to compile:

- `libstdc++`
- `libgcc`
- `libatomic`

It then packages the generated artifacts, removes unnecessary files, and
generates a tarball with only the libraries and GNU STL headers.

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

To use these libraries, you will need the following compile flags:

- `-nostdinc++ -nostdlib++ -nodefaultlibs` (prevent your compiler from automatically linking in your system libraries)
- Include paths:
  + `-isystem path/to/gnulibs/include`
  + `-isystem path/to/gnulibs/include/backward`
  + `-isystem path/to/gnulibs/include/target` (This is renamed to be target-independent)
  
You also need these link flags:

- `-nostdinc++ -nostdlib++ -nodefaultlibs`
- Library path: `-Lpath/to/gnulibs/lib`
- The libraries you need: `-lc -lgcc -lstdc++ -latomic`
  + Might make sense to use `-Wl,--as-needed` to reduce the amount you have to link.
- When linking shared objects/dynamic executables, add `-lgcc_s`
- When linking a static binary, add `-lgcc_eh`

TODO: Add documentation on how to use this together with `zig cc` (requires further testing)

## License

Copyright &copy; 2024, sin-ack. This software is released under the GNU General Public License, version 3.

The contents of the generated tarballs are under the same license as `libstdc++` ([GNU General Public License version 3, with the GCC Runtime Library Exception version 3.1](https://gcc.gnu.org/onlinedocs/libstdc++/manual/license.html)).
