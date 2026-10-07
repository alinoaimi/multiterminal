"""System-provided native libraries; deliberately use /usr/bin/python3."""
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Vte", "3.91")
gi.require_version("WebKit", "6.0")
from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Pango, Vte, WebKit
