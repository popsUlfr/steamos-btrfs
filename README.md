# SteamOS 3.0 Btrfs converter (Experimental)

This injector will install the necessary payload to keep a btrfs formatted /home even through system updates (hopefully).
It will allow to mount btrfs formatted sd cards and will also force new sd cards to be formatted as btrfs.

Btrfs with its transparent compression and deduplication capabilities can achieve impressive storage gains but also improve loading times because of less data being read.

**WARNING!!!! It will install a service that will attempt on the next boot to convert the ext4 /home partition into btrfs and depending on the already used storage this operation may fail or take a long time!**

- https://wiki.archlinux.org/title/Btrfs
- https://wiki.archlinux.org/title/F2FS

## Features

- Btrfs /home conversion from ext4
- Btrfs formatted SD card support
- Btrfs formating of SD card by default
- f2fs formatted SD card support
- **Survives updates!**

## Remaining issues and troubleshooting

At this point the installer should be relatively mature and robust.
Once the payload is installed on the next boot the Steam Deck will use tmpfs as /home and attempt the btrfs conversion on the real partition.
Once it reboots it should all be working fine and the /home partition converted.
This configuration has been confirmed by me to survive through updates.

## Install

(CAUTION: there's no way back if you do this! Unless you reinstall with the recovery image.)

### From SteamOS

Switch into Desktop mode, download the tarball from https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz, extract it and launch `./install.sh`

or by opening a terminal and executing

```
mkdir steamos-btrfs
curl -sSL https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz | tar -xzf - -C steamos-btrfs --strip-components=1
sudo ./steamos-btrfs/install.sh
```

### From the SteamOS Recovery image

#### Do you want to reimage SteamOS from scratch on your Steam Deck ?

Then the installation is the same as above. The repair script will be patched to format /home as btrfs during the reimaging of SteamOS.

```
sudo ~/tools/repair_reimage.sh
```

#### Do you want to inject the btrfs payload into an SteamOS installation from the Recovery image ?

When invoking the install script supply the rootfs device node as first argument to prevent it from injecting into the Recovery image.

```
sudo ./steamos-btrfs/install.sh /dev/disk/by-partsets/A/rootfs
sudo ./steamos-btrfs/install.sh /dev/disk/by-partsets/B/rootfs
```

(Do the installation twice for both slots)

## Uninstall

TODO

## Btrfs mount options

The following mount options are used:

- `noatime,lazytime`: to keep writes to a minimum
- `compress-force=zstd`: force zstd compression always on. zstd is smart enough to do the right thing on uncompressible data, works better and achieves better results than the normal heuristics for compression.
- `space_cache=v2`: make sure the newer implementation is used
- `autodefrag`: small random writes are queued up for defragmentation
- `subvol=@`: by default it will create a subvolume `@` which is used as real root of the filesystem. SD Cards formatted as btrfs will be searched for the `@` subvolume or fallback to `/`.

## F2FS mount options

- `noatime,lazytime`: to keep writes to a minimum
- `compress_algorithm=zstd`: use zstd compression
- `compress_chksum`: verify compressed blocks with a checksum
- `whint_mode=fs-based`: optimize fs-log management
- `atgc,gc_merge`: use better garbage collector, async garbage collection

## Deduplication

Using first [rmlint](https://rmlint.readthedocs.io/en/latest/) for fast efficient file deduplication and finally [duperemove](https://github.com/markfasheh/duperemove) for block based deduplication is the most effective way to potentially reduce disk space.

Install the tools locally
```sh
sudo pacman --cachedir /tmp -Sw compsize duperemove rmlint
mkdir -p ~/.local/bin
for f in /tmp/*.pkg.tar.zst ; do tar -xf "$f" -C ~/.local/bin --strip-components=2 usr/bin ; done
sudo rm /tmp/*.pkg.*
```

Set the `PATH` variable and optionally add it to the `~/.bash_profile`.
```sh
export PATH="$PATH:$HOME/.local/bin"
```

Check with `compsize` the used disk space before deduplication:
```sh
sudo compsize /home
```

First use `rmlint` on `/home`:
```sh
cd /tmp
sudo rmlint --types="duplicates" --config=sh:handler=clone /home
sudo ./rmlint.sh -d -p -r -k
sudo rm -r rmlint*
```

Then use `duperemove` which might take a while:
```sh
sudo duperemove -r -d -h --hashfile=/home/duperemove.hash --skip-zeroes --lookup-extents=no /home
```

Check the used disk space again:
```sh
sudo compsize /home
```

## TODO

- [ ] Get the graphical conversion progress working and fix getting stuck on the next boot splash during the conversion
