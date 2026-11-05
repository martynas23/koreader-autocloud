# Auto-open Cloud Storage

A [KOReader](https://github.com/koreader/koreader) plugin that opens your
cloud storage the moment Wi-Fi connects. Turn on Wi-Fi and you land straight
inside your server's folders, without going through **Cloud storage** and
then tapping the server.

It's made with [Koofr](https://koofr.eu) in mind and picks a Koofr server by
default. It also works with any server you've added to KOReader's Cloud
storage: WebDAV, FTP or Dropbox.

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
   **More tools** → **Plugin management**. **Auto-open cloud storage** should
   be ticked.

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

## Using it

Turn on Wi-Fi. About a second after it connects, Cloud storage opens inside
your Koofr server. Tap a file to download it, as usual.

Settings are under top menu → **Tools** → **Auto-open cloud storage**:

| Option                                     | Default | What it does                                                                 |
|--------------------------------------------|---------|------------------------------------------------------------------------------|
| Open cloud storage when Wi-Fi connects     | On      | Main on/off switch                                                           |
| Also while reading a book                  | Off     | When off, it only opens in the file browser, so it won't interrupt reading   |
| Also if Wi-Fi is already on at startup     | Off     | KOReader sends a "connected" signal at launch if Wi-Fi is on; this ignores it |
| Server: …                                  | Koofr   | Which saved server to open                                                   |
| Open now                                   |         | Open it right away, handy for testing                                        |

**Which server opens:** the one you pick under **Server: …**. If you haven't
picked one, it opens the first server whose address contains `koofr`, or
failing that, your first server.

It won't open a second copy if Cloud storage is already on screen. It also
waits 30 seconds before opening again, because browsing Cloud storage can
itself reconnect Wi-Fi.

## Compatibility

Works on both kinds of KOReader:

- **Older versions** (up to at least v2026.03), where Cloud storage is built in
  and long-pressing a server only offers *Info / Edit / Delete*. The plugin
  opens Cloud storage and taps your server for you.
- **Newer versions**, where Cloud storage is its own plugin and has a
  *Set as default* option. The plugin opens the chosen server directly and
  leaves your default setting unchanged.

## Troubleshooting

- **Nothing happens when Wi-Fi turns on:** check the plugin is ticked in
  **Plugin management**, that you're in the file browser (or have turned on
  **Also while reading a book**), and try **Open now**.
- **It shows the server list instead of opening Koofr:** you have no saved
  servers, or the name in **Server: …** no longer exists. Pick the server
  again in that menu.
- **"Cannot fetch list of folder contents":** that comes from KOReader's
  Cloud storage itself. Check the WebDAV address and app password by tapping
  the server manually.
- **Logs:** turn on debug logging (top menu → **Tools** → **More tools** →
  **Developer options** → **Enable debug logging**). Look for `AutoCloud:`
  lines in `crash.log` in KOReader's folder.

## Uninstalling

Delete the `autocloud.koplugin` folder from KOReader's `plugins` folder and
restart KOReader.

## License

GNU AGPL v3, see [LICENSE](LICENSE).
