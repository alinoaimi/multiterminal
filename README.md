<h1 align="center">MultiTerminal</h1>

<p align="center"><strong>Your whole stack in one window.</strong></p>

<p align="center">
  A native terminal multiplexer with embedded browsers, live file previews,<br>
  and saved workspaces for your development projects.
</p>

<p align="center">
  <a href="https://pub-5cad420ad3d64a419341e2db6b2dda80.r2.dev/apps/multiterminal/releases/0.1.0/MultiTerminal-0.1.0-macOS.dmg">
    <img src="https://img.shields.io/badge/macOS-Download%20.dmg-2563eb?style=for-the-badge" alt="Download MultiTerminal for macOS (.dmg)">
  </a>
  <img src="https://img.shields.io/badge/Windows-.exe%20coming%20soon-6b7280?style=for-the-badge" alt="Windows .exe — coming soon">
  <a href="#linux">
    <img src="https://img.shields.io/badge/Linux-Install%20options-2563eb?style=for-the-badge" alt="Linux download status and installation instructions">
  </a>
</p>

<p align="center"><sub>macOS 14+ · Windows installer coming soon · Linux source available</sub></p>

<p align="center">
  <a href="https://aleecode.dev/multiterminal/">Website</a> ·
  <a href="https://aleecode.dev/multiterminal/#demo">Interactive demo</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<table>
  <tr>
    <th>Whole-stack workspace</th>
    <th>Terminals, side by side</th>
  </tr>
  <tr>
    <td width="50%">
      <a href="docs/screenshots/workspace.png">
        <img src="docs/screenshots/workspace.png" alt="MultiTerminal with an AI coding terminal, API and test tabs, a localhost browser, and Markdown notes">
      </a>
    </td>
    <td width="50%">
      <a href="docs/screenshots/terminal-multiplexer.png">
        <img src="docs/screenshots/terminal-multiplexer.png" alt="An AI coding CLI, API server, and test watcher in three terminal panes">
      </a>
    </td>
  </tr>
</table>

<p align="center">
  <sub>macOS screenshots with sample content.</sub>
</p>

## Why MultiTerminal?

- **Terminal multiplexer.** Run independent shells in split panes and tab groups.
  Drag, group, and resize them around your work.
- **Your whole stack in one window.** Keep servers, tests, your local app, and
  live read-only file previews together.
- **Save your workspace.** Automatically remember each project's layout, tabs,
  starting folders, URLs, and files. Keep browser logins separate by workspace.
- **For AI vibe coding flows.** Run your preferred coding agent beside the app
  and test output. Prompt, review changes, and iterate with everything in view.

Open workspaces keep sessions running while you switch projects. Reopening a
closed workspace starts **fresh shells**; commands and terminal output are not restored.

## Linux

**`.deb` package — coming soon.** You can run the Linux app from source today.
Ubuntu 26.04 is the target environment; the Fedora and Arch instructions below
have not yet been tested on those distributions.

<details>
<summary>Install dependencies and run from source</summary>

Download or clone this repository, then install your distribution's dependencies.

**Ubuntu 26.04**

```sh
sudo apt install python3-gi python3-markdown gir1.2-gtk-4.0 \
  gir1.2-vte-3.91 gir1.2-webkit-6.0 fonts-dejavu-core xdg-utils
```

**Fedora**

```sh
sudo dnf install python3-gobject python3-markdown gtk4 \
  vte291-gtk4 webkitgtk6.0 dejavu-sans-mono-fonts xdg-utils
```

**Arch Linux**

```sh
sudo pacman -Syu --needed python-gobject python-markdown gtk4 \
  vte4 webkitgtk-6.0 ttf-dejavu xdg-utils
```

**Other distributions**

Use your package manager to install Python 3, PyGObject, Python-Markdown,
GTK 4.12 or newer, the GTK 4 version of VTE, WebKitGTK 6.0, DejaVu fonts,
and `xdg-utils`. The GObject introspection namespaces must include `Gtk 4.0`,
`Vte 3.91`, and `WebKit 6.0`.

Package references: [Fedora VTE](https://packages.fedoraproject.org/pkgs/vte291/vte291-gtk4/),
[Fedora WebKitGTK](https://packages.fedoraproject.org/pkgs/webkitgtk/webkitgtk6.0/),
[Arch VTE](https://archlinux.org/packages/extra/x86_64/vte4/), and
[Arch WebKitGTK](https://archlinux.org/packages/extra/x86_64/webkitgtk-6.0/).

**Launch the app**

From this repository's root directory:

```sh
PYTHONPATH=linux /usr/bin/python3 -m multiterminal --check-dependencies
PYTHONPATH=linux /usr/bin/python3 -m multiterminal
```

Use the system Python; a virtual environment may not have access to the native
bindings. See the [Linux guide](linux/README.md) for tests and local data locations.

</details>

## Build from source

Choose your platform. Each guide includes requirements, build commands, and tests.

| Platform | Build and run |
| --- | --- |
| macOS 14+ | [macOS guide](macos/README.md) |
| Linux (Ubuntu 26.04 target) | [Linux guide](linux/README.md) |
| Windows 11 x64 | [Windows guide](windows/README.md) |

Once running, create a workspace and add terminal, browser, or file preview panes.
CLI tools and accounts are configured separately. Preview formats vary by platform.

<details>
<summary>About this source release</summary>

The three platforms have separate native implementations, with no shared runtime
code or automatic workspace import between them.

The apps have no telemetry or automatic updater. Source builds store their data
locally, in separate folders from the closed-source distribution. Browsers and
commands can access the network; terminal commands run with your user permissions.

This repository contains app source and build configuration. It excludes signing
credentials, production service configuration, release infrastructure, marketing
tools, and website code.

Build and test each implementation on its target operating system before
distributing binaries. Including a platform's source here does not imply that
every native GUI or installer has been validated.

</details>

## License

Copyright © 2026 Ali Alnoaimi. Licensed under **AGPL-3.0-only**; see [LICENSE](LICENSE).
Third-party copyright and license notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
