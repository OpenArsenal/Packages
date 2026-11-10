# ntfsplus-udev

These udev rules prefer the `ntfs` driver for NTFS volumes mounted through
udisks2-based desktop automounters (including Dolphin, Nautilus, and Thunar).

- `90-udev-prefer-ntfsplus.rules` retains the NTFS filesystem identification.
- `99-udisks2-prefer-ntfsplus.rules` sets
  `UDISKS_MOUNT_OPTIONS_NTFS_DRIVERS=ntfs` for desktop mounts.

This package does not provide a filesystem driver. The kernel's `ntfs` driver
or a compatible backport must be available for the rules to work. Replug
devices or refresh udev state after installing or changing the rules.
