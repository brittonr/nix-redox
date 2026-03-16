# Native Build


This page explains how to build Redox in your operating system's native environment, without Podman.
>

⚠️ **Warning:** Building outside Podman is not guaranteed to succeed. Unless you have problems using Podman, we recommend you to use the [Podman Build before trying the Native Build to avoid build environment bugs.
>

📝 **Note:** Read the [Build System Reference page after installation for an explanation of the build system's organization and functionality.
## Supported Unix-like Distributions and Podman Build


The following Unix-like systems are supported:

- Pop_OS!
- Ubuntu
- Debian
- Fedora
- Arch Linux
- OpenSUSE
- Gentoo
- FreeBSD (experimental)
- MacOS (experimental, require [workarounds)
- Nix (experimental)
- Solus (not maintained)

If you encounter a weird or difficult-to-fix problem, test the [Podman Build to determine if the problem occurs there as well.
## Preparing the Build

### Bootstrap Prerequisites and Fetch Sources


On supported Linux distributions, build system preparation can be performed automatically via the build system's bootstrap script:

-

Ensure you have the `curl` program installed. e.g., for Pop!_OS/Ubuntu/Debian:
```
which curl || sudo apt-get install curl

```

-

Create a new directory and run the `native_bootstrap.sh` script in it.
```
mkdir -p ~/tryredox

```

```
cd ~/tryredox

```

```
curl -sf https://gitlab.redox-os.org/redox-os/redox/raw/master/native_bootstrap.sh -o native_bootstrap.sh

```

```
time bash -e native_bootstrap.sh

```


You will be asked to confirm some steps: answer with `y` or `1`.

For an explanation of what the `native_bootstrap.sh` script does, read [this section.

Note that `curl -sf` operates silently, so if there are errors, you may get an empty or incorrect version of `native_bootstrap.sh`. Check for typos in the command and try again. If you continue to have problems, join the [chat and let us know.

Please be patient. The bootstrapping process can take anywhere from 5 minutes to an hour depending on the hardware and network it's being run on.

If the `native_bootstrap.sh` script does not work for you, please try reading the [Advanced Build page to install the right packages for your operating system.
-

After bootstrapping is completed, update the `PATH` environment variable for the current shell:
```
source ~/.cargo/env

```

### Setting Configuration Values


The build system uses several configuration files, which contain settings that you may wish to change. These are detailed in the [Configuration Settings page. For the Native Build we recommend setting these in the `.config` file:

- `ARCH=x86_64`
- `CONFIG_NAME=desktop`
- `PODMAN_BUILD=0` to disable Podman Build
- `PREFIX_BINARY=0` to disable [prebuilt prefix binary
- `PREFIX_USE_UPSTREAM_RUST_COMPILER=1` to [avoid compiling Rust compiler

The [build.sh script also allows the user to specify the CPU architecture and filesystem contents to be used in the build, although these settings needs to be written again every time the script is executed.
## Compiling Redox


At this point we have:

- Downloaded the sources
- Tweaked the settings to our liking
- Probably added our recipe to the filesystem

We are ready to build the Redox operating system image. Skip ahead to [Configuration Settings if you want to build for a different CPU architecture or with different filesystem contents.
### Build all system components and programs


To build all the components and packages to be included in the filesystem.
```
cd ~/tryredox/redox

```

```
time make all

```


This will build the target `build/x86_64/desktop/harddrive.img`, which can be run in a virtual machine.

Give it a while. Redox is big. Read the [`make all` (first run) section for an explanation of what the `make all` command does.
>

💡 **Tip:** the filesystem parts are merged into the final system image using the [FUSE library. The `bootstrap.sh` script installs `libfuse` automatically. If you encounter problems with the final Redox image, verify `libfuse` is installed and that you are able to use it.
