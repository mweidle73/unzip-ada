# Zip-Ada GitHub maintenance

This repository preserves the former svn2github import while following the
maintained [official Zip-Ada repository](https://github.com/zertovitch/zip-ada).
Its long-lived branches have distinct roles:

- `legacy-svn2github` preserves the former mirror history unchanged, including
  the revision that Abuild historically pinned.
- `master` is an exact, automatically fast-forwarded mirror of official
  Zip-Ada `master`.
- `abuild` is the official-history equivalent of that historical Abuild
  revision. Its source tree is byte-identical to legacy commit `fea70c4`, so
  Abuild can move its gitlink without changing the consumed source.
- `abuild-gh` adds only files below `.github/` to `abuild`.

The weekly `Upstream Sync` workflow compares the two `master` branches and
updates the mirror only when the official branch is a fast-forward. It fails
loudly on a rewrite or divergence. The write-enabled job checks out the
trusted `abuild-gh` maintenance overlay and never builds or executes mirrored
upstream code. A push made with GitHub's workflow token does not start the
other workflows; build validation remains attached to `abuild-gh`.

## Local Trixie validation

The `run` helper builds a minimal Debian Trixie image and starts it as the
invoking host user. Its root filesystem and repository mount are read-only,
its network is disabled after the image build, and a private source copy is
built below the container's temporary directory.

Run the complete build and archive round-trip check from the repository root:

```sh
.github/ci/run .github/ci/check
```

The check builds every main in `zipada.gpr`, creates an archive with Zip-Ada,
validates and extracts it with Debian's independent `unzip` implementation,
and then exercises Zip-Ada's own extraction path. The historical revision has
no central assertion-based unit-test runner; its test programs are mostly
interactive, fixture-dependent or output-only. CI therefore treats the full
compile plus the independent archive round trip as its automated gate rather
than overstating those programs as a modern unit suite.

With no command, `run` opens an interactive shell with the repository mounted
read-only at `/work`:

```sh
.github/ci/run
```

Set `ZIP_ADA_CI_IMAGE` to override the image name, `DOCKER_PLATFORM` to
override the default `linux/amd64` platform, and `ZIP_ADA_CI_NETWORK` to
override the default `none` network mode.

## Documentation

The historical `zipada.txt` file is ISO-8859-1 text rather than valid modern
AsciiDoc. `build-pages` decodes it explicitly, recognizes its underlined
sections and simple lists, and publishes structured, navigable HTML without
changing the preserved source revision. The original byte stream remains
available as a separate download:

```sh
.github/ci/build-pages
```
