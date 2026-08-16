# WinMedia Builder

> Create FAT32-compatible Windows installation media with a simple graphical interface.

WinMedia Builder automatically splits large **install.wim** files, rebuilds a bootable Windows ISO, and can prepare a bootable USB drive with a FAT32 boot partition and optional NTFS partition for the remaining space.

No more DISM commands, DiskPart scripts, or manual ISO rebuilding.

![WinMedia Builder](docs/WinMediaBuilder.png)

---

## Features

- ✅ Simple graphical interface
- ✅ Supports Windows ISO, install.wim and install.esd
- ✅ Automatically splits `install.wim` into `.swm` files
- ✅ Rebuilds a bootable Windows ISO
- ✅ Source media is never modified
- ✅ Optional USB preparation
- ✅ Creates a FAT32 UEFI boot partition
- ✅ Optional NTFS partition for remaining storage
- ✅ Live progress and logging
- ✅ Background processing (responsive UI)
- ✅ Remembers previous settings

---

## Why?

UEFI systems require boot media formatted as **FAT32**.

Unfortunately, modern Windows installation images often contain an **install.wim** larger than the FAT32 4 GB file size limit.

WinMedia Builder solves this automatically by:

1. Extracting the Windows media
2. Locating the installation image
3. Splitting it into `.swm` parts
4. Rebuilding a bootable ISO
5. Optionally creating a correctly partitioned USB drive

---

## Workflow

```
Windows ISO
      │
      ▼
Extract media
      │
      ▼
Locate install.wim / install.esd
      │
      ▼
Split into .swm files
      │
      ▼
Rebuild bootable ISO
      │
      ▼
(Optional)
Prepare FAT32 + NTFS USB
```

---

## Requirements

- Windows 10 or later
- Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges
- Windows ADK Deployment Tools (`oscdimg.exe`)

If the Windows ADK is missing, the application can guide you to install it.

---

## Supported Sources

- Windows ISO
- install.wim
- install.esd

---

## USB Preparation

When enabled, WinMedia Builder can automatically:

- Erase the selected USB drive
- Create a FAT32 boot partition
- Create an optional NTFS partition using the remaining space
- Copy all Windows installation files
- Produce UEFI-compatible installation media

> **Warning**
>
> Preparing a USB drive is destructive and permanently erases all existing data.

---

## Output

The tool creates:

- Bootable Windows ISO
- Split `.swm` files
- Log file
- Optional bootable USB drive

The original Windows ISO or WIM is **never modified**.

---

## Technologies

- PowerShell
- WPF
- DISM
- DiskPart
- Windows ADK
- Oscdimg

---

## Screenshots

Coming soon.

---

## Roadmap

- [ ] Drag & Drop support
- [ ] Automatic ADK download
- [ ] Driver injection
- [ ] Unattend.xml support
- [ ] Language pack integration
- [ ] Offline Windows Updates
- [ ] Secure Boot verification
- [ ] Command-line version
- [ ] Portable edition

---

## License

MIT License

---

## Author

**Simon Hartmann Eriksen**

Microsoft MVP • Endpoint Management • Windows • macOS • Intune

If this project is useful, consider giving it a ⭐ on GitHub.
