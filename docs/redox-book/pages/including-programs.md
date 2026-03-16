# Including Programs in Redox


(Before reading this page you must read the [Build System page)

This page will teach you how to add programs on the Redox image, it's a simplified version of the [Application Porting page.

- Existing Recipe

  - Setup the Redox Build Environment
  - Setup Your Configuration
  - Build the System
  - Dependencies
  - Update crates
- Modifying an Existing Recipe
- Create Your Own Hello World

  - Setting up the recipe
  - Writing the program
  - Adding the program to the Redox image
- Running your program

The Cookbook system makes the packaging process very simple. First, we will show how to add an existing program for inclusion. Then we will show how to create a new program to be included. In the [Coding and Building page, we discuss the development cycle in more detail.
## Existing Recipe


Redox has many programs that are available for inclusion. Each program has a recipe in the directory `recipes/recipe-name`. Adding an existing program to your build is as simple as adding it to `config/$ARCH/my-config.toml`, or whatever name you choose for your filesystem configuration. Here we will add the `games` package, which contains several terminal games.
### Setup the Redox Build Environment


- Follow the steps in the [Building Redox or [Native Build pages to create the Redox Build Environment on your system.
- Build the system as described. This will take quite a while the first time.
- Run the system in **QEMU**.
```
cd ~/tryredox/redox

```

```
make qemu

```


Assuming you built the default configuration `desktop` for `x86_64`, none of the Redox games (e.g. `/usr/bin/minesweeper`) have been included yet.

- On your Redox emulation, log into the system as user `user` with an empty password.
- Open a `Terminal` window by clicking on the icon in the toolbar at the bottom of the Redox screen, and type `ls /usr/bin`. You will see that `minesweeper` **is not** listed.
- Type `Ctrl-Alt-G` to regain control of your cursor, and click the upper right corner of the Redox window to exit QEMU.
### Setup your Configuration


Read the [Configuration Settings page and follow the commands below.

- From your `redox` base directory, copy an existing configuration and edit it.
```
cd ~/tryredox/redox

```

```
cp config/x86_64/desktop.toml config/x86_64/my-config.toml

```

```
nano config/x86_64/my-config.toml

```


- Look for the `[packages]` section and add the package to the configuration. You can add the package anywhere in the `[packages]` section, but by convention, we add them to the end or to an existing related area of the section.
```
...
[packages]
# Add the item below under the "[packages]" section
redox-games = {}
...

```


- Add the `CONFIG_NAME` environment variable on your [.config to use the `myfiles.toml` configuration.
```
nano .config

```

```
# Add the item below
CONFIG_NAME?=my-config

```


- Save your changes with Ctrl+X and confirm with `y`
### Update The System Image


- In your base `redox` folder, e.g. `~/tryredox/redox`, build the system and run it in **QEMU**.
```
cd ~/tryredox/redox

```

```
make rp.redox-games qemu

```


- On your Redox emulation, log into the system as user `user` with an empty password.
- Open a `Terminal` window by clicking it on the icon in the toolbar at the bottom of the Redox screen, and type `ls /usr/bin`. You will see that `minesweeper` **is** listed.
- In the terminal window, type `minesweeper`. Play the game using the arrow keys or `WSAD`,`space` to reveal a spot, `f` to flag a spot when you suspect a mine is present. When you type `f`, an `F` character will appear.

If you had a problem, use this command to log any possible errors on your terminal output:
```
make r.recipe-name 2>&1 | tee recipe-name.log

```


And that's it! Sort of.
### Dependencies


Read the [Dependencies section to learn how to handle recipe dependencies.
### Update crates


Read the [Update crates section to learn how to update crates on Rust programs.
## Modifying an Existing Recipe


If you want to make changes to an existing recipe for your own purposes, you can do your work in the directory `recipes/recipe-name/source`. The Cookbook process will not download sources if they are already present in that folder. However, if you intend to do significant work or to contribute changes to Redox, please read the [Coding and Building page.
## Create Your Own Hello World


To create your own program to be included, you will need to create the recipe. This example walks through adding the "Hello World" program that the `cargo new` command automatically generates to the folder of a Rust project.

This process is largely the same for other Rust programs.
### Setting Up The Recipe


The Cookbook will only build programs that have a recipe defined in `recipes`. To create a recipe for the Hello World program, first create the directory `recipes/hello-world`. Inside this directory create the "recipe.toml" file and add these lines to it:
```
[build]
template = "cargo"

```


The `[build]` section defines how Cookbook should build our project. There are several templates but `"cargo"` should be used for Rust projects.

The `[source]` section of the recipe tells Cookbook how to download the Git repository/tarball of the program.

This is done if `recipes/recipe-name/source` does not exist, during `make fetch` or during the fetch step of `make all`. For this example, we will simply develop in the `source` directory, so no `[source]` section is necessary.
### Writing the program


Since this is a Hello World example, we are going to have Cargo write the code for us. In `recipes/hello-world`, do the following:
```
mkdir source

```

```
cd source

```

```
cargo init --name="hello-world"

```


This creates a `Cargo.toml` file and a `src` directory with the Hello World program.
### Adding the program to the Redox image


To be able to run a program inside of Redox, it must be added to the filesystem. As above, create a filesystem config `config/x86_64/myfiles.toml` or similar by copying an existing configuration, and modify `CONFIG_NAME` in [.config to be `myfiles`. Open `config/x86_64/myfiles.toml` and add `hello-world = {}` below the `[packages]` section.

During the creation of the Redox image, the build system installs those packages on the image filesystem.
```
[packages]
# Add the item below
hello-world = {}

```


To update the Redox image, including your program, run the following commands:
```
cd ~/tryredox/redox

```

```
make rp.hello-world

```

## Running your program


Once the rebuild is finished, run `make qemu`, and when the GUI starts, log in to Redox, open the terminal, and run `helloworld`. It should print
```
Hello, world!

```


Note that the `hello-world` binary can be found in `/usr/bin` on Redox.
