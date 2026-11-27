# Prebuilt app

`Parasite.app.zip` is a compiled, ready-to-run build of whatever commit it was
last built at. Unzip it and drag `Parasite.app` to `/Applications`.

## It is ad-hoc signed, so a download will be quarantined

The app is signed with an ad-hoc signature, not a Developer ID, because it is
never distributed through the App Store or notarised. That is fine when you build
it locally, but anything **downloaded** from GitHub gets macOS's quarantine
attribute, and Gatekeeper will refuse to open an unnotarised app that carries it.

Clear it after unzipping:

```bash
xattr -dr com.apple.quarantine /Applications/Parasite.app
```

If you would rather not do that, build from source instead — same result, no
quarantine:

```bash
./scripts/build.sh --install
```

## After installing

```bash
./scripts/install-monitor.sh        # start the always-on usage study
./scripts/install-privileges.sh     # optional: thermal/power telemetry (needs sudo)
```
