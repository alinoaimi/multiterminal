import sys
from . import __linux_revision__, __version__


def main():
    if "--version" in sys.argv[1:]:
        print(f"MultiTerminal {__version__}-{__linux_revision__} (native Linux)")
        return 0
    try:
        from .native import Gtk, Vte, WebKit
        import markdown
    except (ImportError, ValueError) as exc:
        print(f"MultiTerminal needs Ubuntu's native dependencies: {exc}\nSee linux/README.md for the system packages required to run from source.", file=sys.stderr)
        return 1
    if "--check-dependencies" in sys.argv[1:]:
        print(f"GTK {Gtk.get_major_version()}.{Gtk.get_minor_version()}; VTE {Vte.get_major_version()}.{Vte.get_minor_version()}; WebKit {WebKit.get_major_version()}.{WebKit.get_minor_version()}; Markdown {markdown.__version__}")
        return 0
    from .app import Application
    return Application().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
