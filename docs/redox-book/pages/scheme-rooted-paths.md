# Scheme-rooted Paths


Scheme-rooted paths are the way that resources are identified on Redox.
## What is a Resource


A [resource is anything that a program might wish to access, usually referenced by some name.
## What is a Scheme


A [scheme identifies the starting point for finding a resource.
## What is a Scheme-rooted Path


A scheme-rooted path takes the following form, with text in **bold** being literal.

**/scheme/***scheme-name***/***resource-name*

*scheme-name* is the name of the kind of resource, and it also identifies the name used by the manager **daemon** for that kind.

*resource-name* is the specific resource of that kind. Typically in Redox, the *resource-name* is a path with elements separated by slashes, but the resource manager is free to interpret the *resource-name* how it chooses, allowing other formats to be used if required.
## Differences from Unix


Unix systems have some special file types, such as "block special file" or "character special file". These special files use [major/minor numbers to identify the driver and the specific resource within the driver. There are also pseudo-filesystems, for example [procfs that provide access to resources using paths.

Redox's scheme-rooted paths provide a consistent approach to resource naming, compared with Unix.
## Regular Files


For Redox, a path that does not begin with `/scheme/` is a reference to the the root filesystem, which is managed by the `file` scheme. Thus `/home/user/.bashrc` is interpreted as `/scheme/file/home/user/.bashrc`.

In this case, the scheme is `file` and the resource is `home/user/.bashrc` within that scheme.

This makes paths for regular files feel as natural as Unix file paths.
