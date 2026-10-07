# MultiTerminal for Linux

Native GTK 4 app using VTE terminals and WebKitGTK browsers. The target environment
is Ubuntu 26.04 with system-provided Python/GObject bindings.

## Run from source

Install dependencies on the target Ubuntu system:

```sh
sudo apt install python3-gi python3-markdown gir1.2-gtk-4.0 gir1.2-vte-3.91 gir1.2-webkit-6.0 fonts-dejavu-core xdg-utils
```

From the repository root:

```sh
PYTHONPATH=linux /usr/bin/python3 -m multiterminal --check-dependencies
PYTHONPATH=linux /usr/bin/python3 -m multiterminal
```

Use `/usr/bin/python3`: virtual environments may hide the system GI bindings.
Other distributions need equivalent GTK 4, VTE 3.91 and WebKit 6.0 introspection packages.

## Tests

Model tests use only Python's standard library and require no display:

```sh
PYTHONPATH=linux /usr/bin/python3 -m unittest discover -s linux/tests -p 'test_*.py'
```

Native integration tests require the app dependencies plus `dbus-x11`, `xvfb` and
`xauth`. Run on a disposable Linux test environment from the repository root:

```sh
dbus-run-session -- xvfb-run -a /usr/bin/python3 linux/tests/smoke.py
dbus-run-session -- xvfb-run -a /usr/bin/python3 linux/tests/ux_smoke.py
```

These tests use temporary settings, real PTYs and a loopback HTTP server. The
`capture.py` helper supports optional test screenshots; it is not marketing tooling.

## Local data

Source builds use `multiterminal-source` under the XDG config, data and cache
locations (by default `~/.config`, `~/.local/share` and `~/.cache`). Settings are
stored as `workspaces.json`; browser profiles are stored separately per workspace.
`MULTITERMINAL_WORKSPACE_FILE` can override the settings path for testing.

The app has no telemetry or automatic updater. Terminals run with your user
permissions. Browsers and shell commands may contact external services.

## License

[AGPL-3.0-only](../LICENSE). Native dependencies are installed separately by the
system package manager; see [third-party notices](../THIRD_PARTY_NOTICES.md).
This source repository does not include a prebuilt Debian package or release tooling.
