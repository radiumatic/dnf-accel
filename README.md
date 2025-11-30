# dnf-accel
[dnf](https://docs.fedoraproject.org/en-US/quick-docs/dnf/) is very, very bad at downloading files. It will wipe half-downloaded files if interrupted in any way and stop the entire operation if the network is unstable. In contrast, a proper download manager like [aria2](https://aria2.github.io/) will not do these. 
dnf-accel is a wrapper bash script that shows the transaction table (list of modified packages and sizes), asks you for confirmation the same way dnf does, gives the download links to aria2, installs the packages and cleans them up after succesful completion. It will not delete them unless they're installed.

To use it, you simply need to put the bash script inside `~/.local/bin`, run `chmod +x` and prepend it with sudo. 

It is very simple and you can review it in five minutes. 
