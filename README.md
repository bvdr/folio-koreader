# Folio for KOReader

Get your [Folio](https://myfolio.so) issues on any e-reader that runs [KOReader](https://koreader.rocks): Kobo, PocketBook, Kindle (jailbroken), Boox, reMarkable and more.

- **Connect with a code.** No typing passwords on e-ink. The reader shows a 6-character code, you enter it at [myfolio.so/link](https://myfolio.so/link).
- **New issues arrive on their own.** Whenever Wi-Fi comes on, new issues download into a `Folio` folder.
- **Make an issue from your inbox.** Pick articles and tap *Make an issue*.
- **Save links while you read.** Tap a link in any book and choose *Save to Folio inbox*.

## Install

1. Download `folio.koplugin.zip` from the [latest release](../../releases/latest).
2. Unzip it. You get a folder called `folio.koplugin`.
3. Copy that folder into KOReader's `plugins` folder on your reader:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/` on internal storage
4. Restart KOReader.

## Use

Open the top menu, go to **Tools → Folio → Connect to Folio**, and follow the steps on screen.

After that, the Folio menu has:

| Item | What it does |
|------|--------------|
| Issues | Your finished issues. Tap one to download and open it. |
| Inbox | Your saved articles. Tap to pick, then *Make an issue*. *Add a link…* saves a new one. |
| Check for new issues | Download anything new right now. |
| Download new issues on Wi-Fi | On by default. |
| Folder | Where issues are saved. Default: `Folio` in your home folder. |
| Disconnect | Signs this reader out of Folio. Files you already have stay. |

Issues come as EPUB, so they fit your screen and font settings.

## Privacy

The plugin only talks to `myfolio.so`. It stores one sign-in token in KOReader's `settings/folio.lua`. *Disconnect* deletes it on the reader and on Folio.

## License

MIT
