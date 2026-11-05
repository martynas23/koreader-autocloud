# Auto Cloud

A [KOReader](https://github.com/koreader/koreader) plugin that turns a cloud
folder into an inbox for your e-reader. When Wi-Fi connects, it asks what you
want to do:

- **Open cloud storage:** opens KOReader's Cloud storage straight inside your
  server, so you don't have to tap through the server list.
- **Download everything in your inbox folder:** downloads every file in a
  cloud folder you choose (e.g. `/kobo-inbox`) to your device. Afterwards it
  asks whether to **delete** those files from the cloud, **move** them to
  another cloud folder (e.g. `/kobo-done`), or **keep** them where they are.

Drop books into the inbox folder from your phone or computer, turn on Wi-Fi
on the e-reader, tap once, and they're on the device.

It's made with [Koofr](https://koofr.eu) in mind and picks a Koofr server by
default. Downloading, deleting and moving need a **WebDAV** server, which
covers Koofr, Nextcloud, ownCloud and others. *Open cloud storage* also works
with FTP and Dropbox servers.

## Installation

1. **Download the plugin.** Either clone this repository or download it as a
   ZIP (green **Code** button → **Download ZIP**) and unzip it.

2. **Find the `autocloud.koplugin` folder** inside what you downloaded. That
   folder is the plugin; you don't need the README or LICENSE on the device.
   Keep the folder name as it is: KOReader only loads plugin folders whose
   names end in `.koplugin`.

3. **Copy the `autocloud.koplugin` folder into KOReader's `plugins` folder**
   on your device:

   | Device     | Plugins folder                                    |
   |------------|---------------------------------------------------|
   | Kindle     | `koreader/plugins/` (on the Kindle drive's root)  |
   | Kobo       | `.adds/koreader/plugins/` (hidden folder)         |
   | PocketBook | `applications/koreader/plugins/`                  |
   | Android    | `koreader/plugins/` in internal storage           |

   On a Kobo you should end up with:

   ```
   .adds/koreader/plugins/autocloud.koplugin/_meta.lua
   .adds/koreader/plugins/autocloud.koplugin/main.lua
   ```

4. **Restart KOReader** (top menu → **Exit** → **Restart KOReader**).

5. **Check the plugin is enabled:** top menu → **Tools** (wrench) →
   **More tools** → **Plugin management**. **Auto cloud** should be ticked.

## Setting up Koofr

If you haven't already added Koofr to KOReader:

1. In the file browser, open the top menu → **Cloud storage**.
2. Tap **+** (top left) → **WebDAV**.
3. Fill in:
   - **Server display name:** anything, e.g. `Koofr`
   - **WebDAV address:** `https://app.koofr.net/dav/Koofr`
   - **Username:** your Koofr email
   - **Password:** an *app password*. Create one in Koofr's web app under
     **Preferences** → **Password** → **App passwords**. Your normal account
     password won't work over WebDAV.
   - **Start folder:** leave empty, or e.g. `/books`
4. Save it, then tap it once to check that it opens.

## Setting up the inbox

Open top menu → **Tools** → **Auto cloud**:

1. **Download from (cloud):** tap it to browse your server's folders and pick
   the inbox folder. Use **+ New folder here…** to create one, e.g.
   `kobo-inbox`. The default is `/kobo-inbox`.
2. **Save to (this device):** the folder on the e-reader where downloads go.
   Defaults to your KOReader home folder.
3. Optional: **Move to (cloud):** a folder to move files into after they've
   been downloaded, e.g. `/kobo-done`. If you don't set one, you can still
   pick a folder each time.

## Using it

Turn on Wi-Fi. About a second after it connects you get a dialog:

| Button                               | What happens                                                         |
|--------------------------------------|----------------------------------------------------------------------|
| Open cloud storage                   | Opens Cloud storage inside your server                               |
| Download 3 files from /kobo-inbox    | Downloads them (greyed out if the inbox is empty)                    |
| Not now                              | Closes the dialog                                                    |

While downloading, a message shows progress (`Downloading 2 / 3`). Tap it to
stop after the current file. When it's done you're asked what to do with the
files **in the cloud**:

| Button                    | What happens                                                          |
|---------------------------|-----------------------------------------------------------------------|
| Delete from cloud         | Deletes the downloaded files from the inbox                           |
| Move to /kobo-done        | Moves them to your **Move to** folder (only shown once one is set)    |
| Move to another folder…   | Pick any cloud folder; it's remembered as the new **Move to** folder  |
| Keep in cloud             | Leaves them in the inbox                                              |

Only files that downloaded successfully are deleted or moved. Files that
were already on the device with the same name aren't downloaded again, but
they're still included, so the inbox gets cleaned up.

Only files directly in the inbox folder are downloaded. Subfolders are
skipped.

## Settings

All under top menu → **Tools** → **Auto cloud**:

| Option                                 | Default       | What it does                                                                     |
|----------------------------------------|---------------|----------------------------------------------------------------------------------|
| When Wi-Fi connects                    | Ask           | *Ask*, *Open cloud storage*, *Download inbox* (only if it has files), or *Do nothing* |
| Also while reading a book              | Off           | When off, it only reacts in the file browser, so it won't interrupt reading      |
| Also if Wi-Fi is already on at startup | Off           | KOReader sends a "connected" signal at launch if Wi-Fi is on; this ignores it    |
| Server                                 | Koofr         | Which saved Cloud storage server to use                                          |
| Download from (cloud)                  | `/kobo-inbox` | The inbox folder                                                                 |
| Save to (this device)                  | Home folder   | Where downloads go                                                               |
| After downloading                      | Ask           | *Ask*, *Delete from cloud*, *Move to the folder below*, or *Keep in cloud*       |
| Move to (cloud)                        | not set       | Folder used by *Move*                                                            |
| Download inbox now                     |               | Run a download right away                                                        |
| Open cloud storage now                 |               | Open Cloud storage right away                                                    |

**Which server is used:** the one you pick under **Server**. If you haven't
picked one, it uses the first server whose address contains `koofr`, or
failing that, your first server.

It won't prompt again within 30 seconds, and won't prompt at all if Cloud
storage is already on screen, because browsing Cloud storage can itself
reconnect Wi-Fi.

## Compatibility

Works on both kinds of KOReader:

- **Older versions** (up to at least v2026.03), where Cloud storage is built in
  and long-pressing a server only offers *Info / Edit / Delete*. The plugin
  opens Cloud storage and taps your server for you.
- **Newer versions**, where Cloud storage is its own plugin and has a
  *Set as default* option. The plugin opens the chosen server directly and
  leaves your default setting unchanged.

Downloading, deleting and moving don't depend on the KOReader version: the
plugin talks to the WebDAV server itself, using the address, username and
password saved in Cloud storage.

## Troubleshooting

- **Nothing happens when Wi-Fi turns on:** check the plugin is ticked in
  **Plugin management**, **When Wi-Fi connects** isn't set to *Do nothing*,
  and you're in the file browser (or have turned on **Also while reading a
  book**). Try **Download inbox now** or **Open cloud storage now**.
- **"Could not open cloud folder /kobo-inbox":** the folder doesn't exist on
  the server. Pick or create it under **Download from (cloud)**.
- **"Downloading the inbox needs a WebDAV server":** the selected server is
  FTP or Dropbox. Pick a WebDAV server under **Server**.
- **Some files failed to move:** a file with the same name is probably already
  in the destination folder. The plugin never overwrites files in the cloud,
  so those stay in the inbox.
- **It shows the server list instead of opening Koofr:** the name under
  **Server** no longer exists. Pick the server again in that menu.
- **"Cannot fetch list of folder contents":** that comes from KOReader's
  Cloud storage itself. Check the WebDAV address and app password by tapping
  the server manually.
- **Logs:** look for `AutoCloud:` lines in `crash.log` in KOReader's folder.
  Failed WebDAV requests are always logged. For more detail, turn on debug
  logging (top menu → **Tools** → **More tools** → **Developer options** →
  **Enable debug logging**).

## Uninstalling

Delete the `autocloud.koplugin` folder from KOReader's `plugins` folder and
restart KOReader.

## License

GNU AGPL v3, see [LICENSE](LICENSE).
