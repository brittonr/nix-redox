# Avoiding Panics


Panics should be avoided in kernel, and should only occur in drivers and other services when correct operation is not possible, in which case it should be a call to `panic!()`.

Please also read the kernel [README for kernel-specific suggestions.
