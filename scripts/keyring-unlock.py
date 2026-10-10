#!/usr/bin/env python3
# Unlock the keyring ./sandbox stores the model credential in, or create it
# when the account has none yet. Linux only.
#
#   scripts/keyring-unlock.py            asks for the keyring password
#   ... | scripts/keyring-unlock.py      reads it from standard input
#
# Why this exists. secret-tool, and ./sandbox login through it, can store a
# credential only in a keyring that exists and is unlocked. On a desktop both
# are taken care of at login (PAM creates the "login" keyring with your account
# password and unlocks it). An account made the way the quickstart says - no
# password, reached over SSH with a key - never goes through that: it has no
# keyring, and nothing can create one, because gnome-keyring creates and
# unlocks keyrings by putting up a graphical prompt. With no display the
# prompt dies and secret-tool reports "Cannot create an item in a locked
# collection". `gnome-keyring-daemon --unlock` does not help either: against
# the systemd-managed daemon on gnome-keyring 48 it returns 0 and unlocks
# nothing.
#
# This asks the daemon directly over D-Bus, through the interface gnome-keyring
# keeps for exactly this (its own name admits what it is), with the password as
# data. No prompt is involved. The keyring stays unlocked until the daemon
# stops; after a reboot run this again, or let ./sandbox run ask for the
# credential (it does when the keyring will not answer).
#
# Needs python3-gi, which gnome-keyring's distribution packages pull in.
import getpass
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402  (after require_version)

SERVICE = "org.freedesktop.secrets"
ROOT = "/org/freedesktop/secrets"
SECRETS = "org.freedesktop.Secret.Service"
COLLECTION = "org.freedesktop.Secret.Collection"
INTERNAL = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"


def main():
    if sys.platform == "darwin":
        sys.exit("this is for the Secret Service on Linux; macOS unlocks the Keychain itself")
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as e:
        sys.exit(f"no session bus: {e.message}")

    def call(path, interface, method, params):
        return bus.call_sync(SERVICE, path, interface, method, params, None,
                             Gio.DBusCallFlags.NONE, -1, None).unpack()

    try:
        (collection,) = call(ROOT, SECRETS, "ReadAlias", GLib.Variant("(s)", ("default",)))
    except GLib.Error as e:
        sys.exit(f"no Secret Service on the session bus (is gnome-keyring installed and running?): {e.message}")

    if sys.stdin.isatty():
        verb = "Choose a password for the new keyring" if collection == "/" else "Keyring password"
        password = getpass.getpass(f"{verb}: ").encode()
    else:
        password = sys.stdin.buffer.read().rstrip(b"\n")
    if not password:
        sys.exit("an empty password is not accepted")

    # A plain (unencrypted) session is fine: this is a local socket to a daemon
    # running as this same user.
    _, session = call(ROOT, SECRETS, "OpenSession", GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))))
    secret = (session, b"", password, "text/plain")

    if collection == "/":
        label = {"org.freedesktop.Secret.Collection.Label": GLib.Variant("s", "login")}
        (collection,) = call(ROOT, INTERNAL, "CreateWithMasterPassword",
                             GLib.Variant("(a{sv}(oayays))", (label, secret)))
        call(ROOT, SECRETS, "SetAlias", GLib.Variant("(so)", ("default", collection)))
        print("created a keyring and made it the default")
    else:
        try:
            call(ROOT, INTERNAL, "UnlockWithMasterPassword", GLib.Variant("(o(oayays))", (collection, secret)))
        except GLib.Error as e:
            if (Gio.DBusError.get_remote_error(e) or "").endswith(".Denied"):
                sys.exit("that is not the keyring's password. If you do not know it and the keyring holds nothing you need,"
                         " remove it and run this again to make a new one:\n"
                         "    rm ~/.local/share/keyrings/login.keyring && systemctl --user restart gnome-keyring-daemon")
            sys.exit(f"the keyring could not be unlocked: {e.message}")

    (locked,) = call(collection, "org.freedesktop.DBus.Properties", "Get",
                     GLib.Variant("(ss)", (COLLECTION, "Locked")))
    if locked:
        sys.exit(f"{collection} is still locked")
    print("the keyring is unlocked; ./sandbox login can store the credential now")


if __name__ == "__main__":
    main()
