# SteamOS 3/Steam Deck Btrfs converter <img align="right" height="32" src="data/steamos-btrfs-logo.svg">

This injector will install the necessary payload to keep a btrfs formatted /home even through system updates. You may also choose to only install the support for formatting and mounting of multiple filesystems for the SD cards.
It will allow to mount btrfs, f2fs and ext4 formatted sd cards and will also force new sd cards to be formatted as btrfs by default or a user configured filesystem.

Btrfs with its transparent compression and deduplication capabilities can achieve impressive storage gains but also improve loading times because of less data being read.

**WARNING!!!! If you decide to so, it will install a service that will attempt on the next boot to convert the ext4 /home partition into btrfs and depending on the already used storage this operation may fail or take a long time!**

**Make sure you have at least 10-20% free space available before attempting the conversion (`df -h /home` 80-90% use with at least 10-20 GiB available space)**

- https://wiki.archlinux.org/title/Btrfs
- https://wiki.archlinux.org/title/F2FS

## Features

- Btrfs /home conversion from ext4 (optional)
- Btrfs, f2fs, ext4 formatted SD card support
- Btrfs, f2fs, ext4 formating of SD card
- Progress dialog and logging during the home conversion!
- Install additional pacman packages into the rootfs automatically and persist through updates
- **Survives updates and branch changes!**
- Steam's `downloading` and `temp` folders as subvolumes with COW disabled

![Btrfs /home conversion progress dialog](data/steamos-btrfs-conversion.webp "Btrfs /home conversion progress dialog")

## Remaining issues and troubleshooting

At this point the installer should be relatively mature and robust.
Once the payload is installed and the conversion was greenlit by the user, on the next boot the Steam Deck will use tmpfs as /home and attempt the btrfs conversion on the real partition.
Once it reboots it should all be working fine and the /home partition converted.
This configuration has been confirmed by me and others to survive through updates.

A log file is created at `/var/log/steamos-btrfs.log` containing the installation and the home conversion log to review the process or help with bug reports.

If the conversion of the home partition fails for any reason, the service will do its best to restore the original ext4 mount and hard mask the systemd conversion service to prevent a conversion boot loop.

Please submit the log file at `/var/log/steamos-btrfs.log` as new issue if that happens to you.

You'll need to explicitely unmask the service yourself if you want to attempt the conversion again:
```sh
sudo systemctl unmask steamos-convert-home-to-btrfs.service
```
or
```sh
sudo rm /etc/systemd/system/steamos-convert-home-to-btrfs.service
```

## Configuration

Before the installation you may want to modify the [Configuration options](#configuration-options)
* If it's a first time installation, edit `./files/etc/default/steamos-btrfs`.
* Otherwise edit `/etc/default/steamos-btrfs` as it will take precedence over the local one.

## Install

**CAUTION**: there's not an easy way back if you proceed! Once the /home partition is converted, you can not go back to ext4 and keep your files.
The original files that have been changed are backed up with the `.orig` extension. Keep in mind that they are specifically changed to allow for a btrfs `/home`.
It is safe to revert to the original files if the btrfs conversion was not attempted.

**Please make sure you have enough free space before attempting the conversion. At least 10-20GiB and/or 10-20% free space should usually be fine.**

### From SteamOS

If you haven't already done so, set a password for your user in a terminal:

```
passwd
```

**Switch into Desktop mode**, download the tarball from https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz, extract it and launch `./install.sh`

or by opening a terminal and executing

```sh
mkdir steamos-btrfs
curl -sSL https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz | tar -xzf - -C steamos-btrfs --strip-components=1
./steamos-btrfs/install.sh
```

In case you want to install over SSH or without graphical environment (will assume the default options!):
```sh
sudo NONINTERACTIVE=1 ./steamos-btrfs/install.sh
```

Follow the on-screen instructions and if you decide to convert your home to btrfs, on the next boot you'll see a progress dialog.

### From the SteamOS Recovery image

#### **Do you want to reimage SteamOS from scratch on your Steam Deck ?**

Then the installation is the same as above and your recovery image will be btrfs ready. The repair script will be patched to format /home as btrfs during the reimaging of SteamOS.

```sh
sudo ~/tools/repair_reimage.sh
```

#### **Do you want to inject the btrfs payload into a SteamOS installation from the Recovery image ?**

When invoking the install script, supply the rootfs device node as first argument to prevent it from injecting into the Recovery image.

```sh
./steamos-btrfs/install.sh /dev/disk/by-partsets/A/rootfs
./steamos-btrfs/install.sh /dev/disk/by-partsets/B/rootfs
```

(Do the installation twice for both slots)

## Updating or changing config options

At any time you can download the latest version and go through the installation again to enable the latest changes or simply apply changed settings.
Disabling the home conversion won't have any effect on an already converted home partition.
You should still select the `Convert /home` option if you want to update the home partition's mount flags modified through `/etc/default/steamos-btrfs`.

At times updates may change the default config options and you may want to merge the changes with your own: [Configuration options](#configuration-options)

If you don't want to be prompted while running the script you can set the `NONINTERACTIVE=1` environment variable:
```sh
sudo NONINTERACTIVE=1 ./install.sh
```

## Uninstall

- the underlying rootfs needs to be mounted somewhere else and the readonly mode disabled
  + `sudo mount /dev/disk/by-partsets/self/rootfs /mnt`
  + `sudo btrfs property set /mnt ro false`
- the original files are backed up next to the new files with a `.orig` extension so you can move them back into position
  + `sudo find /mnt -type f,l -name '*.orig' -exec sh -c 'mv -vf "$1" "${1%.*}"' _ '{}' \;`
- make sure to disable the conversion systemd services or it will attempt to convert `/home` again
  + `sudo rm /mnt/usr/lib/systemd/system/*.target.wants/steamos-convert-home-to-btrfs*.service`
- the `/home` partition will need to be force formatted back to ext4 if it has been converted to btrfs (obviously all files on it will be lost!)
  + you can edit `/etc/fstab` to mount `/home` in tmpfs for the next boot : `tmpfs /home tmpfs defaults,nofail,noatime,lazytime 0 0`
  + force format the real `/home` to ext4 : `sudo mkfs.ext4 -m 0 -O casefold -F -L home /dev/disk/by-partsets/shared/home`
  + change the line in `/etc/fstab` back to ext4 : `/dev/disk/by-partsets/shared/home /home   ext4    defaults,nofail,x-systemd.growfs 0       2`

## Mount options

### Btrfs mount options

The following mount options are used by default:

- `noatime,lazytime`: to keep writes to a minimum
- `compress-force=zstd`: force zstd compression always on. zstd is smart enough to do the right thing on uncompressible data, works better and achieves better results than the normal heuristics for compression. You can set a specific compression level by appending `:<level>` to the type e.g.: `compress-force=zstd:6`. The default level is 3 and going over 6 is rarely worth it (compression/decompression complexity grows quickly after that).
- `space_cache=v2`: make sure the newer implementation is used
- `autodefrag`: small random writes are queued up for defragmentation, invests more effort during writes to achieve as much contiguous data as possible. Interesting for games where more fragmentation can lead to loading stutter.
- `subvol=@`: by default it will create a subvolume `@` (can be changed in the config) which is used as real root of the filesystem. SD Cards formatted as btrfs will be searched for the `@` subvolume or fallback to `/`.
- `ssd_spread`:  attempts to allocate into bigger and aligned chunks of unused space for a potential performance boost on SD cards.

### F2FS mount options

- `noatime,lazytime`: to keep writes to a minimum
- `compress_algorithm=zstd`: use zstd compression. You can set a specific compression level by appending `:<level>` to the type e.g.: `compress_algorithm=zstd:6`. The default level is 3 and going over 6 is rarely worth it (compression/decompression complexity grows quickly after that).
- `compress_chksum`: verify compressed blocks with a checksum
- `whint_mode=fs-based`: optimize fs-log management
- `atgc,gc_merge`: use better garbage collector, async garbage collection

### ext4 mount options

- `noatime,lazytime`: to keep writes to a minimum

## Configuration options

A configuration file is available to change various filesystem options at [`/etc/default/steamos-btrfs`](files/etc/default/steamos-btrfs).

- `STEAMOS_BTRFS_HOME_MOUNT_OPTS`           : the mount options to use for mounting the `/home` partition. Changing only this variable will not have any effect if the conversion is already done. `/etc/fstab` would need to be edited to reflect the new values and you can do this easily by running the installation script again [`./install.sh`](install.sh) (pick `Convert /home` again during installation).
- `STEAMOS_BTRFS_HOME_MOUNT_SUBVOL`         : the root subvolume to use when mounting. Changing only this variable will not have any effect if the conversion is already done. A new subvolume with the desired name would need to be created and `/etc/fstab` would need to be edited to reflect the new values.
- `STEAMOS_BTRFS_SDCARD_FORMAT_FS`          : allows you to specify what new blank SD cards will be formatted as. One of `btrfs`, `f2fs`, `ext4`.
- `STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_OPTS`   : the btrfs mount options for btrfs formatted SD cards.
- `STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL` : the default subvolume to mount if available. It also specifies the default subvolume to create on newly formatted btrfs SD cards.
- `STEAMOS_BTRFS_SDCARD_BTRFS_FORMAT_OPTS`  : flags to pass to `mkfs.btrfs` during the format.
- `STEAMOS_BTRFS_SDCARD_EXT4_MOUNT_OPTS`    : the ext4 mount options for ext4 formatted SD cards.
- `STEAMOS_BTRFS_SDCARD_EXT4_FORMAT_OPTS`   : flags to pass to `mkfs.ext4` during the format.
- `STEAMOS_BTRFS_SDCARD_F2FS_MOUNT_OPTS`    : the f2fs mount options for f2fs formatted SD cards.
- `STEAMOS_BTRFS_SDCARD_F2FS_FORMAT_OPTS`   : flags to pass to `mkfs.f2fs` during the format.
- `STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS`  : additional pacman packages to install into the rootfs separated by spaces (e.g.: "compsize nfs-utils wireguard-tools ..."). You can install them easily immediately by running the installation script again [`./install.sh`](install.sh).

If you changed the default options and want to reset them or want to benefit from updated default options you can do the following:

Delete the modified file from the upper overlay layer:
```sh
sudo rm -f /var/lib/overlays/etc/upper/default/steamos-btrfs
```

Refresh the overlay for `/etc`:
```sh
sudo mount -o remount /etc
```

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

**DISCLAIMER: in most cases running `duperemove` will not result in a lot of space improvements and is slow.**

Then use `duperemove` which might take a while:
```sh
sudo duperemove -r -d -h --hashfile=/home/duperemove.hash --skip-zeroes --lookup-extents=no /home
```

Check the used disk space again:
```sh
sudo compsize /home
```

## Steam preallocation woes

The latest version attempts to replace Steam's `downloading` and `temp` folders (located in `Steam/steamapps/`) with btrfs subvolumes and COW disabled. This is to mitigate the issue of games downloaded through the Steam client not having the most optimal compression ratio.

If you were already using this project or you think your games' space usage is less than ideal you may want to consider to defragment and balance your Steam library manually:

For the internal storage:
```sh
sudo btrfs filesystem defrag -czstd -v -r -f /home/deck/.local/share/Steam/steamapps
sudo btrfs balance start -m -v /home/deck/.local/share/Steam/steamapps
```

For your SD card:
```sh
sudo btrfs filesystem defrag -czstd -v -r -f /run/media/mmcblk0p1/steamapps
sudo btrfs balance start -m -v /run/media/mmcblk0p1/steamapps
```

## TODO

- [ ] rootfs/slot user dialog selection
- [ ] deduplication service
- [ ] easier installer (appimage, desktop file...)
