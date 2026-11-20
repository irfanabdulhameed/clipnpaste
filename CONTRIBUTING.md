# Contributing to Clipnpaste

Thanks for helping. The friendly version of this guide lives at
<https://irfanabdulhameed.github.io/clipnpaste/#contribute>.

## Set up

```bash
xcode-select --install                                  # Command Line Tools, no Xcode needed
git clone https://github.com/<you>/clipnpaste.git
cd clipnpaste
./scripts/build.sh --run                                # build, install, open
./scripts/test.sh                                       # run the tests
```

Requires macOS 26. Set `CLIPNPASTE_SIGN_ID` to a certificate of your own to keep the
Accessibility permission across rebuilds.

## Where things go

- `Sources/ClipnpasteCore/` – logic with no UI. Changes here come with a test in `Tests/`.
- `Sources/Clipnpaste/` – the app: panel, cards, drag, settings. UI changes come with a GIF or screenshot in the PR.

## Rules we review against

1. **Local only.** No clipboard data leaves the Mac. The GitHub update check is the only network request.
2. **Zero dependencies.** Apple frameworks and system SQLite only.
3. **Calm motion.** Springs with no overshoot; respect Reduce Motion.
4. **Never steal focus** from the app the user is pasting into.
5. **Plain words** in UI copy and docs.

## Pull requests

- One change per PR, with a sentence on why.
- For anything bigger than a bug fix, open an issue first so we can agree on the shape.
- Make sure `./scripts/test.sh` passes.

## Reporting bugs

Open an [issue](https://github.com/irfanabdulhameed/clipnpaste/issues/new) with your macOS
version, the app you copied from or pasted into, and steps to reproduce.
