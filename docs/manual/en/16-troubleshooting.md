# Troubleshooting

When something does not work, the activity bar at the bottom of the window is the first place to look:
it says what Verbinal is doing, and what failed and why. Click it for the **Activity** list.

## Signing in

- **The sign-in is refused.** Check your CADC username and password on the CADC website. Verbinal signs
  in with your CADC account; a registry (Harbor) secret is not your password.
- **You are asked to sign in again and again.** Tick **Remember me** when you sign in: Verbinal then signs
  you in again by itself when your session with CADC expires.
- **Verbinal started offline.** It waits for the network and checks your session then; the tiles that
  need an account unlock by themselves.

## CADC or CANFAR is slow or down

- A search shows **Waiting for CADC** with the seconds; **Cancel** stops it, and you can try again later.
- **Settings ▸ Endpoints ▸ Test Connections** asks each service whether it answers, and how fast.
- If you changed an address in **Settings ▸ Endpoints**, **Reset All to Defaults** puts the usual ones
  back; addresses apply after a restart.
- If **Storage** shows the files of another folder than the one in its path, open Storage again (from
  Home, or ⌘6).

## A session does not start

- Open its **Events**: they say whether CANFAR is waiting for room, cannot pull the image, or stopped it.
- **Platform Load** shows how busy CANFAR is. A **Fixed** size waits until that much is free; a smaller
  size, or **Flexible**, starts sooner.
- A notification tells you when the session is ready, or that it failed to start.

## A batch job waits or fails

- A job waits in **Pending** until CANFAR has room for its size; a smaller size starts sooner.
- **View Events & Logs** on the job says why it failed, and what it printed.
- A job CANFAR has removed is still in **History**, with how it ended.

## Remote Compute is not ready

**Not ready** means the session exists but its image cannot be pulled. Check, in
**Settings ▸ AI Compute**: the **Compute image** name, that the image is registered for the contributed
session type, and, for a private image, the registry **Username** and **Secret** (**Test Connection**).
Then **Stop Session** and **Start Session** again. See [Remote Compute](10-remote-compute.md).

## Image Discovery

A probe that fails says why; **View probe logs** shows what the probe job printed. For private images,
set your registry credentials in **Settings ▸ Image Discovery** and **Test Connection**: the most common
mistake is the CADC password in place of the Harbor CLI secret.

## The viewers

- **"… is no longer available"**: the file was moved or deleted since you opened it. Open it again from
  where it is now.
- **WCS approximate**: the file has no standard world coordinates; positions are estimated.
- **Cube Viewer, volume**: on an Intel Mac, or a Mac without a suitable GPU, a banner says why the volume
  cannot be drawn. Slice mode still works.
- **Cube Viewer, spectrum probe**: a very large cube is read from disk (**Streamed**), and its spectrum
  probe is not available.

## An AI assistant cannot connect

1. Is Verbinal running? The assistant's connection only relays to the app; it cannot start it.
2. Is **Allow external AI agents** on, in **Settings ▸ AI Agent**?
3. Does the client point at the Verbinal you have now? An app that was moved or deleted cannot be
   started. **Settings ▸ MCP Clients** shows the current command, and copies it.
4. **Settings ▸ MCP Clients ▸ Diagnostics** checks each link and fixes what it can.
5. Quit the assistant's app completely and open it again.

If the assistant connects but cannot do anything, it is waiting for you to allow its session: look for
the window **An assistant wants to start a session**. A change it proposed waits in **Pending**, and
expires after three hours. See [Working with an AI assistant](12-ai-assistant.md).

## The language did not change

macOS applies an app's language when it starts: after changing **Settings ▸ General ▸ Language**, click
**Restart Now**.

## Reporting a problem

1. Open **About Verbinal** and click **Copy Details**: the app version, macOS, the Mac and how Verbinal was
   installed.
2. Choose **Help ▸ Report an Issue**, and paste the details with what you did and what happened.
3. For a problem with an assistant, export its session log (**Settings ▸ AI Agent ▸ Session Logs** ▸
   **Export**) and attach it: it holds what happened, not your data.
