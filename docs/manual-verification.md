# Manual verification with a real Google account

Everything that doesn't need Google is covered by automated tests (see
[development.md](development.md)). The steps below need your own OAuth
client and Google account, so they were left for you to run.

## 1. Check the OAuth client in GCP project `itsalex`

The Drive API is enabled. Still unverified: the client's type and consent
setup. In the [Google Auth Platform](https://console.cloud.google.com/auth/clients?project=itsalex):

- [ ] The client type is **Desktop app** (a *Web* or *Android* client won't
      accept rclone's `http://127.0.0.1:53682/` redirect). If it isn't, create
      a Desktop client as in [google-oauth-client.md](google-oauth-client.md#4-create-the-oauth-client).
- [ ] The scope `https://www.googleapis.com/auth/drive` is listed under
      [Data access](https://console.cloud.google.com/auth/scopes?project=itsalex).
- [ ] alex.marre.fr@gmail.com is a test user, or the app is published
      (see the note on 7-day tokens in Testing mode).

## 2. Laptop (Linux)

```sh
mise run native:linux
cd app && flutter run -d linux     # or run the AppImage from CI
```

- [ ] Paste the client ID and secret, click **Sign in with Google**, accept in
      the browser, and the app moves on to step 2.
- [ ] Create a vault (folder `CryptDrive`, a password).
- [ ] Open [drive.google.com](https://drive.google.com): the `CryptDrive`
      folder only contains encrypted names.

## 3. Phone (Android)

```sh
mise run native:android
cd app && flutter run -d <device>   # or install the APK from CI
```

- [ ] Same client ID/secret, **Sign in with Google**. If the phone's browser
      can't come back to the app, use **Or paste a token from another computer**
      with the output of `rclone authorize "drive" "<id>" "<secret>"`.
- [ ] **Existing vault**, folder `CryptDrive`, same password (and salt).
- [ ] From the Photos app, **Share → CryptDrive** a photo, confirm the upload.

## 4. Back on the laptop

- [ ] Refresh: the photo is listed with its real name; tap it to open it.
- [ ] drive.google.com still shows only encrypted names and sizes.

## 5. rclone CLI compatibility

- [ ] **Settings → Export rclone.conf**, save it as `exported.conf`.
- [ ] `rclone --config exported.conf ls vault:` lists the photo, and
      `rclone --config exported.conf copy vault: ./check` decrypts it.
