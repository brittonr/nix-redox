# Developer FAQ


The [General FAQ have questions and answers of/for newcomers and end-users, while this FAQ contain organization, technical questions and answers of/for developers and testers, feel free to suggest new questions and answers.

(If the following questions aren't enough, ask us in the [Chat)

- General Questions

  - Why does Redox have unsafe Rust code?
  - Why does Redox have Assembly code?
  - Why does Redox do cross-compilation?
  - What are the CPU requirements of Redox?
  - How can I port a program?
  - How can I write a driver?
  - How can I debug?
  - What is the software and hardware requirements for development?
  - Does Redox support OpenGL and Vulkan?
- Build System Questions

  - What is the correct way to update the build system?
  - How can I verify if my build system is up-to-date?
  - What is a recipe?
  - When I should rebuild the build system or recipes from scratch?
  - How can I test my changes on real hardware?
  - How can I insert files to the Redox image?
  - How can I change my Redox variant?
  - How can I increase the filesystem size of my QEMU image?
  - How can I change the CPU architecture of my build system?
  - How can I cross-compile to ARM64 from a x86-64 computer?
  - How can I use a recipe in my Redox image?
  - How to update initfs?
  - I made changes to my recipe. What is the quickest way to test it in QEMU?
  - I made changes to multiple recipes. What is the quickest way to test it in QEMU?
  - How can I disable recipe compilation?
  - How can I disable recipe compilation except for a specific recipe?
  - How to disable the automatic recipe source update?
  - How can I install the packages needed by recipes (Native Build) or Podman without a new download of the build system?
  - How can I build the toolchain from source?
- Porting Questions

  - How to determine if some program is portable to Redox?
  - How to determine the dependencies of some program?
  - How can I configure the build system of the recipe?
  - How can I search for functions on relibc?
  - Which are the upstream requirements to accept my recipe?
  - What are the possible problems when porting programs and libraries?
  - Why C/C++ programs and libraries are hard and time consuming to port?
- Scheme Questions

  - What is a scheme?
  - When does a regular program need to use a scheme?
  - When would I write a program to implement a scheme?
  - How do I use a scheme for sandboxing a program?
  - How can I see all userspace schemes?
  - How can I see all kernel schemes?
  - What is the difference between kernel and userspace schemes?
  - How does a userspace daemon provide file-like services?
  - How the system calls are used by userspace daemons?
- GitLab Questions

  - How to properly request a review or review MRs?
  - I have a merge request with many commits, should I squash them after merge?
  - Should I delete my branch after merge?
  - How can I have an anonymous account?
- Documentation Questions

  - How can I write code documentation properly?
  - How can I write book documentation properly?
  - How can I insert commands or code correctly?
  - How can I create diagrams?
- Troubleshooting Questions

  - Scripts

    - I can't download the build system bootstrap scripts, how can I fix this?
    - I tried to run the "podman_bootstrap.sh" and "native_bootstrap.sh" scripts but got an error, how to fix this?
  - Build System

    - I ran "make all" but it show a "rustup can't be found" message, how can I fix this?
    - I tried all troubleshooting methods but my build system is still broken, how can I fix that?
  - Recipes

    - I had an error with a recipe, how can I fix that?
    - I tried all methods of the "Troubleshooting the Build" page and my recipe still doesn't build, what can I do?
    - When I run "make r.recipe" I get a syntax error, how can I fix that?
    - When I run "cargo update" on some recipe source it call Rustup to install other Rust toolchain version, how can I fix that?
    - I added the dependency of my program in the "recipe.toml" file but the program build system doesn't detect it, then I installed the program dependency on my Linux distribution and it detected, why?
    - I made changes to system daemons, drivers and RedoxFS but they aren't applied in the Redox image, how can I fix that?
  - QEMU

    - How can I kill the QEMU process if Redox freezes or get a kernel panic?
  - Real Hardware

    - I got a kernel panic, what can I do?
    - Some driver is not working with my hardware, what can I do?
## General Questions

### Why does Redox have unsafe Rust code?


In some cases we must use `unsafe` declarations to allow some low-level tasks, for example at certain parts in the kernel and drivers, these unsafe parts are generally wrapped with a safe interface.

These are the cases where unsafe Rust is mandatory:

- Implementing a foreign function interface (FFI) (for example the relibc API)
- Working with system calls directly (you should use `libredox`, `relibc` or Rust `libstd` library instead of `redox_syscall`)
- Creating or managing processes and threads
- Working with memory mapping and stack allocation
- Working with hardware devices

It is an important goal for Redox to minimize the amount of `unsafe` declared Rust code. If you want to use unsafe Rust code on Redox anywhere other than interfacing with system calls, ask for Jeremy Soller's approval before.

Unsafe Rust still has most of the compiler verification and allow some safe Rust syntax usage, thus still more safe than C and C++.

Read the following pages to learn more about Unsafe Rust:

- https://doc.rust-lang.org/book/ch20-01-unsafe-rust.html
- https://doc.rust-lang.org/nomicon/meet-safe-and-unsafe.html
### Why does Redox have Assembly code?


[Assembly is the core of low-level because it's a CPU-specific programming language and deal with things that aren't possible or feasible to do in high-level languages like Rust.

Sometimes required or preferred for accessing hardware, or for carefully optimized hot spots.

Reasons to use Assembly instead of Rust:

- Deal with low-level things (those that can't be handled by Rust)
- Writing constant time algorithms for cryptography
- Optimizations

Places where Assembly is used:

- `kernel` - Interrupt and system call entry routines, context switching, special CPU instructions and registers
- `drivers` - Port IO need special instructions (x86_64)
- `relibc` - Some parts of the C runtime
### Why does Redox do cross-compilation?


[Cross-compilation is when you build a program or library from one CPU architecture to another CPU architecture or one operating system to another operating system, but it require more configuration than native compilation.

Read some of the reasons below:

- When developing a new operating system you can't build programs inside of it because the system interfaces are premature. Thus you need to build the programs from your host system to the new OS and transfer the binaries to the filesystem of the new OS.
- Cross-compilation reduces the porting requirements because you don't need to support the compiler of the program's programming language, the program's build system and build tools. You just need to port the programming language standard library (if used), program libraries or the program source code (dependency-free).
- Some developers prefer to develop from other operating systems like Linux, MacOS, FreeBSD or Windows, the same applies for Linux where some developers write code on MacOS and test their kernel builds in a virtual machine (mostly QEMU) or real hardware.

(Interpreted programs and scripts don't need cross-compilation but the programming language's interpreter or possible compiled dependencies needs to be ported and cross-compiled to Redox)
### What are the CPU requirements of Redox?


Read [this section.
### How can I port a program?


Read the [Application Porting page.
### How can I write a driver?


Read the [drivers repository README.
### How can I debug?


Read the [Debug Methods section.
### Does Redox support OpenGL and Vulkan?


Read the [Software Rendering section.
### What is the software and hardware requirements for development?


- If you are using the Podman Build you need any Linux or Unix-like distribution supporting Podman 4.0 or newer and FUSE 3.x (if you have problems with FUSE in the host system there's [this workaround to run FUSE inside the Podman container instead of host system)
- If you are using the Native Build a recent Ubuntu, PopOS or Fedora version is recommended

The following hardware requirements are enough for fast compilation of the system and most programs, but some heavy programs may require more.

- An Intel or AMD CPU newer than 10 years with 4 cores/threads or more
- 4GB DDR4 or more (8GB or 16GB for heavy programs)
- 50GB of storage space or more (a high-performance HDD, SSD, and NVMe is recommended)
- An Internet connection good enough to not cause timeouts
## Build System Questions

### What is the correct way to update the build system?


Read the [Update The Build System section.
### How can I verify if my build system is up-to-date?


After the `make pull` command, run the `git rev-parse HEAD` command to verify if it match the latest commit hash on [GitLab.
### What is a recipe?


A software port to Redox
### When I should rebuild the build system or recipes from scratch?


Sometimes the execution of the `make pull rebuild` command is not enough to update the build system and recipes because of breaking changes, learn what to do on the following changes:

- New relibc functions and fixes: to allow a recipe to use the new relibc functions you need to rebuilt it with the `make cr.recipe-name` command, sometimes relibc fixes require a complete system rebuild by running the `make c.--all all` command
- Dependency changes on recipes: if the shared objects had symbol changes or the recipe is statically linked, run the `make cr.recipe-name` command
- Configuration changes on recipes: run the `make cr.recipe-name` command
- Source code changes on recipes: if the shared objects had symbol changes or the recipe is statically linked, run the `make ucr.recipe-name` command
- Changes on the location of the build system artifacts: run the `make clean pull all` command to not cause breakage with the previous artifacts locations, if the previous location of the build artifacts had contents you can try to fix manually or download the build system again to avoid confusion or fix difficult breakage
### How can I test my changes on real hardware?


Read the [Testing on Real Hardware section.
### How can I insert files to the Redox image?


If you use a [recipe your changes will persist after the `make image` command, but you can also [mount the Redox filesystem to insert them directly.
### How can I change my Redox variant?


Insert the `CONFIG_NAME?=your-config-name` environment variable to your `.config` file, read the [config section for more details.
### How can I increase the filesystem size of my QEMU image?


Change the `filesystem_size` data type of your filesystem configuration at: `config/$ARCH/your-config.toml` and run the `make image` command, read the [Filesystem Size section for more details.
### How can I change the CPU architecture of my build system?


Insert the `ARCH?=your-cpu-arch` environment variable on your `.config` file and run the `make all` command, read the [config section for more details.

If you want to do it temporarily run the `make all ARCH=$ARCH` command.

If you want to clean the binaries of the previous CPU architecture run the following command:
```
make c.--all ARCH=previous-cpu-arch

```

### How can I cross-compile to ARM64 from a x86-64 computer?


Insert the `ARCH?=aarch64` environment variable on your `.config` file and run the `make all` command.

If you want to do it temporarily run the `make all ARCH=aarch64` command.
### How can I use a recipe in my Redox image?


If you want to quickly install the recipe package until the next image creation, run the following command:
```
make rp.recipe-name

```


Or (if you want to use a remote package if you want to use it more quickly)
```
make rp.recipe-name REPO_BINARY=1

```


If you want to permanently install the recipe on your image, read the following steps.

- Go to your filesystem configuration and add the recipe:
```
nano config/$ARCH/your-config.toml

```

```
[packages]
...
recipe-name = {}
...

```


Or (for a remote package)
```
[packages]
...
recipe-name = "binary"
...

```


- Build the recipe and install in a existing image
```
make rp.recipe-name

```


Or (for a remote package)
```
make rp.recipe-name REPO_BINARY=1

```

## How to update initfs?


initfs don't automatically add your changes to system daemons, drivers or RedoxFS and need manual rebuild.

Read [this section to learn how to do it.
### I made changes to my recipe. What is the quickest way to test it in QEMU?


If you did incremental changes (which don't change the binary symbols), run the following command:

- Rebuild the recipe, install to an existing image and launch QEMU
```
make rp.recipe-name qemu

```


If you did breaking changes (which changed the binary symbols) run the following command:

- Rebuild the recipe, install to an existing image and launch QEMU
```
make crp.recipe-name qemu

```

### I made changes to multiple recipes. What is the quickest way to test it in QEMU?


- Rebuild the modified recipes, install to an existing image and launch QEMU:
```
make rp.recipe1,recipe2 qemu

```


If you don't want to specify all modified recipes run the following command:

- Rebuild the modified recipes, install to an existing image and launch QEMU:
```
make repo push qemu

```

### How can I disable the recipe compilation?


Insert the `REPO_BINARY?=1` environment variable to your `.config` file, it will download pre-compiled recipe packages from the [build server if available.
### How can I disable recipe compilation except for a specific recipe?


After inserting the `REPO_BINARY?=1` environment variable to your `.config` file, go to your filesystem configuration and add the source-based variant of the recipe:
```
nano config/$ARCH/your-config.toml

```

```
[packages]
...
recipe-name = "source"
...

```


- Install the recipe package in the Redox image
```
make rp.recipe-name

```


Or (if the above doesn't work)
```
make rebuild

```

### How to disable the automatic recipe source update?


The build system automatically update recipe sources if new upstream commits exist, which can break your local changes.

To learn how to disable it for one or multiple recipes read [this section.

To learn how to disable it for all recipes read [this section.
### How can I install the packages needed by recipes (Native Build) or Podman without a new download of the build system?


- Run the following command from your build system:
```
./native_bootstrap.sh -d

```


(If you are using Podman this process is automatic)

Or (for Podman dependencies)

- Run the following command from your build system:
```
./podman_bootstrap.sh -d

```

### How can I build the toolchain from source?


- Disable the `PREFIX_BINARY` environment variable inside of your `.config` file:
```
nano .config

```

```
PREFIX_BINARY?=0

```


- Clean the previous toolchain binaries and build new ones:
```
rm -rf prefix

```

```
make prefix

```


- Clean the previous recipe binaries and build again with the new toolchain:
```
make c.--all all

```

## Porting Questions

### How to determine if some program is portable to Redox?


- The source code of the program must be available
- The program should use cross-platform libraries (if not, more porting effort is required)
- The program's build system should support cross-compilation (if not, more porting effort is required)
- The program shouldn't directly use the Linux kernel API on its code (if not, more porting effort is required)

Some APIs of the Linux kernel can be ported while others not, because they require a complete Linux kernel.
### How to determine the dependencies of some program?


Read the [Dependencies section.
### How can I configure the build system of the recipe?


Read the [Templates section.
### How can I search for functions on relibc?


Read the [Search For Functions on Relibc section.
### Which are the upstream requirements to accept my recipe?


Read the [Package Policy section.
### What are the possible problems when porting programs and libraries?


- Missing build tools
- Cross-compilation configuration problems
- Lack of Redox patches
- Missing C, POSIX or Linux library functions in relibc
- Runtime crashes or errors
### Why C/C++ programs and libraries are hard and time consuming to port?


- C/C++ don't have an official, advanced and automatic dependency manager and build system which force programs and libraries to select competing build systems with different configurations (GNU Make, GNU Autotools, CMake, Meson and others), projects like [Conan and [vcpkg tried to solve this problem but weren't adopted by most programs/libraries and lack many libraries
- Programs and libraries need to manually manage the library versions, to workaround this some programs use bundled libraries which can difficult patching when needed
- Some build systems lack a good cross-compilation support which require more tweaks and sometimes hacks
- As libraries are manually managed programs with many dependencies can take hours to port depending on available library documentation/configuration and developer experience
- Some programs and libraries have bad or lacking documentation about build instructions and configuration
## Scheme Questions

### What is a scheme?


Read the [Schemes and Resources page.
### When does a regular program need to use a scheme?


Most schemes are used internally by system components or relibc, you don't need to access them directly. One exception is the pseudoterminal for your command window, which is accessed using the value of `$TTY`, which might have a value of e.g. `pty:18`. Some low-level graphics programming might require you to access your display, which might have a value of e.g. `display:3`
### When would I write a program to implement a scheme?


If you are implementing a kernel service, userspace service or a device driver.
### How do I use a scheme for sandboxing a program?


The [contain program provides a partial implementation of sandboxing using schemes and namespaces.
### How can I see all userspace schemes?


Read the [Userspace Schemes section.
### How can I see all kernel schemes?


Read the [Kernel Schemes section.
### What is the difference between kernel and userspace schemes?


Read the [Kernel vs Userspace Schemes section.
### How does a userspace daemon provide file-like services?


When a regular program calls `open`, `read`, `write`, etc. on a file-like resource, the kernel translates that to a message of type `syscall::data::Packet`, describing the file operation, and makes it available for reading on the appropriate daemon's scheme file descriptor. See the [Providing A Scheme section for more information.
### How the system calls are used by userspace daemons?


All userspace daemons use the system calls through [relibc like any normal program.
## GitLab Questions

### How to properly request a review or review MRs?


These rules prevent you from wasting time and stress.

- **Don't edit your code suggestions without a warning before to prevent merge errors and review disorganization**
- If you are requesting a review it's recommended that it's done by one reviewer per time to avoid extra coordination effort with multiple reviewers to confirm when each reviewer finished their review, but if you accept multiple reviewers at once **each reviewer should warn when started and finished its review to prevent code suggestion conflicts between reviewers due to possible different file states while you apply the code suggestions**
- If you are requesting a review where code suggestions will not be used, you can accept multiple reviewers without coordination of when they started and finished their reviews
- Once you finish your review warn to avoid conflicts with other reviewers
- It's recommended to use code suggestions for normal text and code to help and save time for developers, that way they can quickly improve or apply the text or code.

You can start a code suggestion by clicking on the file icon with the + symbol when you click to comment in some line of a file.
### I have a merge request with many commits, should I squash them after merge?


If they don't have relevant informaiton on titles, yes.
### Should I delete my branch after merge?


Yes.
### How can I have an anonymous account?


During the account creation process you can add a fake name on the "First Name" and "Last Name" fields and change it later after your account approval (single name field is supported).

Read the [Anonymous Commits section if you need more anonymity.
## Documentation Questions

### How can I write code documentation properly?


Read the following pages:

- [Literate programming
- [Writting Documentation Correctly
### How can I write book documentation properly?


**Read the entire book before writing new documentation and submiting MRs to avoid information duplication**

- Only add work-in-progress information if really necessary, as it may unnecessarily increases maintenance cost
- Don't use informal grammar abbreviations such as "config" (except technical terms such as "CPU")
- Use spaces instead of tabs to avoid formatting breakage with different text editor tab configurations
- Use [Oxford commas
- The documentation grammar is not strictly formal to allow better understanding and readability, the grammar is a mix of American, British and International English
### How can I insert commands or code correctly?


Commands or code should be inserted inside Markdown code blocks (using 3 backticks above and below the line of the command), for example:
```
your-command-or-code

```


- Multiple commands should use an unique code block for each command to allow them to be copied with one cursor click
- If you can't use a code block due to incompatible wording in the explanation, you can use the simple code highlighting using 1 backtick before and after the command on the same line
### How can I create diagrams?


For diagrams to this book read [this article.

For diagrams to the GitLab web interface the GitLab Markdown has support for some diagram syntaxes, read [this article to learn how to use them.
## Troubleshooting Questions

### Scripts

#### I can't download the build system bootstrap scripts, how can I fix this?


Verify if you have `curl` installed or download the script from your web browser.
#### I tried to run the "podman_bootstrap.sh" and "native_bootstrap.sh" scripts but got an error, how to fix this?


- Verify if you have the GNU Bash shell installed on your system.
- Verify if Podman is supported on your operating system.
- Verify if your operating system is [supported on the `native_bootstrap.sh` script
### Build System

#### I ran "make all" but it show a "rustup can't be found" message, how can I fix this?


Run the following command:
```
source ~/.cargo/env

```


(If you installed rustup before the first `podman_bootstrap.sh` or `native_bootstrap.sh` execution, this error doesn't happen)
#### I tried all troubleshooting methods but my build system is still broken, how can I fix that?


If the `make clean pull container_clean all` command doesn't work download a new build system copy or wait for an upstream fix.
### Recipes

#### I had an error with a recipe, how can I fix that?


Read the [Solving Compilation Problems section.
#### I tried all methods of the "Troubleshooting the Build" page and my recipe still doesn't build, what it can be?


- Missing dependencies
- Environment leakage: when some part of the recipe build system does native Linux compilation instead of cross-compilation to Redox
- Misconfigured cross-compilation
- The recipe needs to be ported to Redox
#### When I run "make r.recipe" I get a syntax error, how can I fix that?


Verify if your `recipe.toml` file has some typo, missing data type or value.
#### When I run "cargo update" on some recipe source it call rustup to install other Rust toolchain version, how can I fix that?


It happens because Cargo is not using the Redox fork of the Rust compiler, to fix that run `make env` from the Redox build system root.

It will import the Redox Makefile environment variables to your active shell (it already does that when you run other `make` commands from the Redox build system root).
#### I added the dependency of my program in the "recipe.toml" file but the program build system doesn't detect it, then I installed the program dependency on my Linux distribution and it detected, why?


Read the [Environment Leakage section.
#### I made changes to system daemons, drivers and RedoxFS but they aren't applied in the Redox image, how can I fix that?


You forgot to update initfs which is manual, read [this section to learn how to do this.
### QEMU

#### How can I kill the QEMU process if Redox freezes or get a kernel panic?


Read the [Kill A Frozen Redox VM section.
### Real Hardware

#### I got a kernel panic, what can I do?


Read the [Kernel Panic section.
#### Some driver is not working with my hardware, what can I do?


Read the [Debug Methods section and ask us for instructions in the [Matrix chat.
