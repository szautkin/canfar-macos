# Privacy and your data

Verbinal has no server of its own. It collects nothing about you, sends nothing to its developer, and has
no analytics, tracking or advertising. Your data stays on your Mac, or goes to the CADC and CANFAR
services you use, over HTTPS.

## What is kept on your Mac

| What | Where |
|---|---|
| Your CADC session, username and, with **Remember me**, your password | The macOS Keychain, on this Mac only |
| Registry secrets (Image Discovery, AI Compute) | The macOS Keychain |
| Your Research observations, notes, tags and ratings; saved queries and recent searches; FITS bookmarks; marks; workflows; the batch job history | Verbinal's own folder, as a database and files |
| Assistant session logs | Verbinal's own folder, 10 days and 10 MB at most |
| Image Discovery results, the image list, the data train, the service addresses | Caches in Verbinal's own folder |
| Your settings | Verbinal's preferences |
| Files you download, figures and exports | Where you choose, or your Downloads folder |
| Your Research observations' names, collections and instruments | The Mac's Spotlight index |

Verbinal's own folder is inside its sandbox: `~/Library/Containers/com.codebg.Verbinal`. Nothing there
is shared with other apps.

## What leaves your Mac, and to whom

Verbinal talks only to these, and only when you (or an assistant you allowed) use them:

- **CADC and CANFAR services**: sign-in and your account, the science platform (sessions, batch jobs,
  images, platform load), your VOSpace storage, the archive (search, metadata, previews, downloads and
  cutouts), the name resolver, and the registry that lists the services. Their addresses are in
  **Settings ▸ Endpoints**.
- **CANFAR's image registry** (`images.canfar.net`, or the registry you set): to test your registry
  credentials and to search for images.
- **VizieR at CDS**: only when an AI assistant searches a VizieR catalogue.

Links such as **View on CADC** or **Report an Issue** open in your browser, which is outside Verbinal.

## AI assistants

The MCP server is off until you turn on **Allow external AI agents**, and only programs on this Mac can
reach it. An assistant you allow reads what its tools return: your observations, notes, sessions or
files, as you let it. What it sends to its own service is between you and that service. The session log
records what it did, and never your password. See
[Working with an AI assistant](12-ai-assistant.md#what-stays-private).

## Removing your data

- **Sign Out** removes your saved session and password from the Keychain.
- In Research, **Remove File…** deletes a file and **Delete** an observation; your notes are kept until
  you clear them.
- **Clear** empties recent searches, saved queries, recent launches, the batch job history and the
  activity list, each in its own place.
- **Settings** clears the caches (**Portal ▸ Clear Cache**, **Image Discovery ▸ Image Discovery Cache**),
  removes registry secrets (**Remove Secret**, **Reset to Defaults**), and deletes session logs
  (**AI Agent ▸ Session Logs**).
- To remove everything, quit Verbinal, move it to the Trash, and delete its folder
  `~/Library/Containers/com.codebg.Verbinal`.

Your files in VOSpace are on CANFAR, not on your Mac: they stay until you delete them in
[Storage](09-storage.md).
