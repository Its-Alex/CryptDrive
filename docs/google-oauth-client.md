# Create your own Google OAuth client

CryptDrive talks to Google Drive with **your own** OAuth client. rclone's shared
client ID is being retired during 2026
([rclone docs](https://rclone.org/drive/#making-your-own-client-id),
[RSAF #320](https://github.com/chenxiaolong/RSAF/issues/320)), and shipping a
bundled client to other people would require Google's restricted-scope
verification and a CASA security assessment. With your own client, the app
only ever accesses your own Drive, and nothing is shared with anyone.

It takes about five minutes. You need a Google account and a web browser.

## 1. Create (or pick) a Google Cloud project

1. Open the [Google Cloud console](https://console.cloud.google.com/).
2. In the project picker at the top, choose **New project**, give it any name
   (for example `cryptdrive`), and create it. An existing personal project
   works too.

## 2. Enable the Google Drive API

1. Open [APIs & Services → Library](https://console.cloud.google.com/apis/library)
   for that project.
2. Search for **Google Drive API**, open it and click **Enable**.

## 3. Configure the consent screen (Google Auth Platform)

1. Open [Google Auth Platform → Branding](https://console.cloud.google.com/auth/branding)
   and fill in the app name (e.g. `CryptDrive`) and your email address.
2. Under **Audience**, choose **External** and leave the publishing status on
   **Testing**.
3. Under **Audience → Test users**, add the Google account whose Drive will
   hold the vault. Only test users can sign in while the app is in Testing.
4. Under [Data access](https://console.cloud.google.com/auth/scopes), add the
   scope `https://www.googleapis.com/auth/drive`.

> **Testing mode and token lifetime.** Google expires refresh tokens of apps in
> *Testing* after 7 days, so you would have to sign in again every week. To avoid
> it, click **Publish app** under *Audience*. For a personal app used only by you,
> Google lets you use it unverified: the consent screen shows an
> "unverified app" warning that you can click through (**Advanced → Go to …**).

## 4. Create the OAuth client

1. Open [Google Auth Platform → Clients](https://console.cloud.google.com/auth/clients)
   and click **Create client**.
2. Application type: **Desktop app**. Name: anything.
3. Click **Create**, then copy the **Client ID** and **Client secret**.

Use the *Desktop app* type on every platform, including Android: CryptDrive
signs in through rclone's loopback redirect (`http://127.0.0.1:53682/`), which
Google only accepts for desktop clients. The client secret of a desktop client
is not confidential by Google's own definition; it is still stored only in the
app's encrypted configuration.

## 5. Which scope, and why

CryptDrive asks for the full `drive` scope. The narrower `drive.file` scope
only shows files created by the same OAuth client, so a vault written by the
rclone CLI, RSAF, Round Sync or a previous client ID would look empty, and
the vault could not be opened again after you change client. rclone crypt
also needs to list and read its own folder freely. The trade-off: the token
can read your whole Drive, which is why it never leaves your devices.

## 6. Paste it into CryptDrive

In the onboarding screen (or **Settings → Change OAuth client ID / secret**):

1. Paste the client ID and secret.
2. Tap **Sign in with Google**: your browser opens Google's consent page; after
   you accept, it lands on rclone's local page and CryptDrive continues.

### Signing in from another computer

If the browser can't reach the app (for example a phone whose browser kills the
app in the background), sign in on any computer with the
[rclone CLI](https://rclone.org/downloads/):

```sh
rclone authorize "drive" "YOUR_CLIENT_ID" "YOUR_CLIENT_SECRET"
```

Copy everything it prints between the arrows (a JSON object with an
`access_token` and a `refresh_token`) into **Or paste a token from another
computer**, then tap **Connect**.

## Changing the client later

Tokens belong to the client that issued them, so changing the client ID in
**Settings** signs you in again. Your vault is unaffected: it only depends on
the vault password and salt.
