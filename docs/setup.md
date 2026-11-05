# Set up Tako

Tako opens its setup guide after the first terminal window is ready. All steps
are optional. **Finish later** remembers the current step; use **Tako → Set Up
Tako…** or **Settings (⌘,) → Setup…** to return. Closing the guide leaves your
terminal and running programs in place.

If no terminal window is open, explicitly choosing **Set Up Tako…** opens a
clean terminal for the guide. Automatic setup waits for the first usable
terminal window; it respects `initial-window = false`.

## Appearance

Choose a color preset to preview it immediately. Colors save automatically;
your terminal font, size and layout stay as configured. Edit full themes and
typography in **Settings**. Workspace and pane overrides retain their priority.

## Command line

**Install takoctl** links this app's bundled CLI into a writable bin directory.
It preserves unrelated programs. Add that directory to your shell's `PATH` if needed.

```sh
takoctl split right
takoctl workspace list
takoctl theme list
```

## AI agents

Choose detected agents and press **Connect selected**. Tako installs its hooks
and skill, preserves unrelated configuration, and reports each connection's status.
Already connected agents are checked without reinstalling them.

## Permissions

The setup step shows one icon for each permission. Click an icon to request,
check or configure that access. Agent setup remains in its separate step.

| Action | What happens |
| --- | --- |
| **Your files** | Checks Desktop, Documents and Downloads; macOS may request access. |
| **Protected files** | Shows this exact app to drag into Full Disk Access, or copy its path for the + file picker. |
| **Notifications** | Requests task alerts, or opens Settings after a previous denial. |
| **Microphone** | Uses the native consent dialog, or Settings after denial. |
| **Local Network** | Attempts Apple's no-traffic UDP consent trigger; an attempt never means permission was granted. |
| **System Audio** | Explains the recording-time request and opens its Settings page; playback needs no recording access. |
| **Screen Recording / Automation** | Requests screen access, or explains app-specific automation setup. |

The protected-files helper stays available when Settings opens. Select the
application bundle shown there, not an arbitrary shell or zmx process. If drag
and drop is unavailable, press **+** in Full Disk Access, then **⇧⌘G** and paste
the copied app path. Add the app and turn its switch on.

The file check opens and closes directory handles without reading file names
or contents. Results apply to Tako and each tested folder; they do not establish
Full Disk Access or access for every terminal program.

Microphone and screen requests use system consent APIs without recording.
Permissions without a public status API remain managed in macOS Settings.

## Notifications

**Enable notifications** requests alerts, sounds and badges. **Check again**
sends a test notification when allowed and displays its result. If access is
denied or banners are off, open **macOS Settings** to change them.

## Returning to setup

Skipping optional integrations does not prevent ordinary terminal use. Opening
setup does not request access. File checks and
permission requests require an explicit action. Camera access is not requested.
Tako renders screenshots of its own terminal content without reading other
apps' screens.

Setup progress records navigation and explicit choices. Installed components
and permissions are checked again rather than inferred from a previous click.
Existing “Don't Ask Again” choices are preserved; a previous agent decline
leaves agents unselected until you choose them.
Explicit agent selections, including unchecking every agent, are remembered
when you finish later or close and reopen the guide.

After finishing or dismissing the guide, it does not reopen automatically on
every launch. Release notes remain a separate notice for later app versions.
