# Folio for KOReader

**Read your saved articles, newsletters and RSS feeds on Kobo, PocketBook, Kindle and any e-reader that runs [KOReader](https://koreader.rocks).**

[Folio](https://myfolio.so/?utm_source=github&utm_medium=readme&utm_campaign=koreader) collects everything you want to read and turns it into one calm, typeset issue for your e-ink screen. This open-source KOReader plugin brings those issues to your reader. Connect once with a six-character code. After that, new issues download on their own whenever Wi-Fi is on.

<p>
<img src="screenshots/color/01-issues.png" width="260" alt="Folio issues screen in KOReader: latest issue with cover, reading progress and library">
<img src="screenshots/color/03-inbox.png" width="260" alt="Folio inbox in KOReader: pick saved articles and generate an issue">
<img src="screenshots/color/00-connect.png" width="260" alt="Connect KOReader to Folio with a six-character code">
</p>

## What is Folio?

Folio is a read-it-later service built for e-ink. Instead of forty separate articles on your tablet, you get one publication.

1. **Collect what you find.** Save a link, send a tab with the [Chrome extension](https://chromewebstore.google.com/detail/folio-save-articles/hklokineicdheecpelibkipgmdnoafan?utm_source=github-koreader), forward newsletters (Substack, Beehiiv, Mailchimp, ConvertKit) to your own `@myfolio.so` address, follow RSS feeds, or upload a `.docx` or `.md` file.
2. **Folio typesets an issue.** Cover, table of contents, sections by topic, clean article pages. One file, not forty.
3. **Read it on your device.** On a schedule you pick, or whenever you want. Folio delivers to reMarkable, Kindle, Dropbox, Google Drive, email, and now any KOReader device through this plugin.

It also works with AI assistants. Connect Claude, ChatGPT, Gemini or Grok to Folio (myfolio.so/mcp) and ask them to find articles, build an issue and send it to your reader.

## What the plugin does

- **Connect without typing passwords.** Your reader shows a short code; you approve it at [myfolio.so/link](https://myfolio.so/link) on your phone.
- **New issues arrive on their own.** When Wi-Fi comes on, the newest issues download into a `Folio` folder as EPUB, so they reflow to your screen and font settings.
- **Your library, with covers.** See the latest issue, what you've read and what's waiting.
- **Make an issue from your inbox.** Tick a few saved articles and tap *Generate issue*.
- **Save links while you read.** Tap any link in a book and choose *Save to Folio inbox*.
- **Highlights in one place.** Everything you highlight in a Folio issue, grouped by article, with a Markdown export.
- **Made for e-ink.** A calm, typographic design with a warm palette on color screens (Kobo Libra Colour, PocketBook Era Color, Boox) and a crisp black-and-white one everywhere else.

<p>
<img src="screenshots/color/02-contents.png" width="200" alt="Issue contents grouped by topic">
<img src="screenshots/color/04-highlights.png" width="200" alt="Highlights from Folio issues">
<img src="screenshots/color/05-save-link.png" width="200" alt="Save a link to the Folio inbox while reading">
<img src="screenshots/color/06-settings.png" width="200" alt="Folio plugin settings">
</p>

<details>
<summary>Black &amp; white screens</summary>
<p>
<img src="screenshots/bw/00-connect.png" width="200" alt="Connect screen in black and white">
<img src="screenshots/bw/01-issues.png" width="200" alt="Issues screen in black and white">
<img src="screenshots/bw/02-contents.png" width="200" alt="Contents screen in black and white">
<img src="screenshots/bw/03-inbox.png" width="200" alt="Inbox screen in black and white">
<img src="screenshots/bw/04-highlights.png" width="200" alt="Highlights screen in black and white">
<img src="screenshots/bw/05-save-link.png" width="200" alt="Save a link in black and white">
<img src="screenshots/bw/06-settings.png" width="200" alt="Settings screen in black and white">
</p>
</details>

## Works on

Any device that runs KOReader: Kobo (Clara, Libra, Sage, Elipsa), PocketBook, jailbroken Kindles, Android e-readers like Boox, reMarkable, and KOReader on Linux or macOS.

## Install

1. Download `folio.koplugin.zip` from the [latest release](../../releases/latest).
2. Unzip it. You get a folder called `folio.koplugin`.
3. Copy that folder into KOReader's `plugins` folder on your reader:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/` on internal storage
4. Restart KOReader and open **Tools → Folio**.

You need a Folio account. [Start a trial at myfolio.so](https://myfolio.so/?utm_source=github&utm_medium=readme&utm_campaign=koreader).

## Use

| Tab | What it does |
|-----|--------------|
| Issues | Your latest issue and your library. Tap a cover to see what's inside. |
| Inbox | Saved articles. Tick a few and tap *Generate issue*. *Add link* saves a new one. |
| Highlights | What you've highlighted in your issues. *Markdown* saves them to a file. |
| Settings | Auto-download on Wi-Fi, folder, how many issues to keep, EPUB or PDF, and Disconnect. |

## FAQ

**Is Folio a Pocket alternative?** Yes. Pocket shut down in 2025, and Folio covers the same "save it, read it later" habit, but delivers to e-ink instead of a phone app. It's also an Instapaper or Wallabag alternative if you mostly read on an e-reader.

**Can I read Substack newsletters on my Kobo?** Yes. Forward them to your Folio address (or set up a Gmail/Outlook filter once) and they show up in your next issue.

**Does it work offline?** Downloaded issues are regular EPUB files, so you can read them anywhere. The plugin only needs Wi-Fi to fetch new issues and to save links.

**What does the plugin store?** One sign-in token in KOReader's `settings/folio.lua`. *Disconnect* deletes it on the reader and on Folio. The plugin only talks to `myfolio.so`.

**Is the plugin free?** The plugin is open source (MIT). Folio itself is a paid service with a trial.

## Contributing

Issues and pull requests are welcome. `tools/screenshots/run.sh` runs KOReader headless and regenerates every screenshot, so UI changes are easy to review.

## License

MIT
