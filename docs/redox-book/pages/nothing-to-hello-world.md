# From Nothing To Hello World


This page explain the quickest way to test a program on Redox. This tutorial doesn't build Redox from source.

In this example we will use a "Hello World" program written in Rust.

-

Create the `tryredox` folder.
```
mkdir -p ~/tryredox

```

-

Navigate to the `tryredox` folder.
```
cd ~/tryredox

```

-

Download the script to configure Podman and download the Redox build system.
```
curl -sf https://gitlab.redox-os.org/redox-os/redox/raw/master/podman_bootstrap.sh -o podman_bootstrap.sh

```

-

Execute the downloaded script.
```
time bash -e podman_bootstrap.sh

```

-

Enable the Rust toolchain in the current shell.
```
source ~/.cargo/env

```

-

Navigate to the Redox build system directory.
```
cd ~/tryredox/redox

```

-

Create the `.config` file and add the `REPO_BINARY` environment variable to download the pre-compiled packages.
```
echo "REPO_BINARY?=1 \n CONFIG_NAME?=my-config" >> .config

```

-

Create the `hello-world` recipe folder.
```
mkdir recipes/other/hello-world

```

-

Create the `source` folder for the recipe.
```
mkdir recipes/other/hello-world/source

```

-

Navigate to the recipe's `source` folder.
```
cd recipes/other/hello-world/source

```

-

Initialize a Cargo project with the "Hello World" string.
```
cargo init --name="hello-world"

```

-

Create the `hello-world` recipe configuration.
```
cd ~/tryredox/redox

```

```
nano recipes/other/hello-world/recipe.toml

```

-

Add the following to the recipe configuration:
```
[build]
template = "cargo"

```

-

Create the `my-config` filesystem configuration.
```
cp config/x86_64/desktop.toml config/x86_64/my-config.toml

```

-

Open the `my-config` filesystem configuration file (i.e., `config/x86_64/my-config.toml`) and add the `hello-world` package to it.
```
[packages]
# Add the item below
hello-world = "source"

```

-

Build the Hello World program and updae the Redox image.
```
time make prefix rp.hello-world

```

-

Start the Redox virtual machine without a GUI.
```
make qemu gpu=no

```

-

At the Redox login screen, write "user" for the user name and press Enter.
-

Run the "Hello World" program.
```
helloworld

```

-

Shut down the Redox virtual machine.
```
sudo shutdown

```
