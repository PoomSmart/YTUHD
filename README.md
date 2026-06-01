# YTUHD

YTUHD unlocks 1440p (2K) and 2160p (4K) options in the iOS YouTube app by expanding codec/media capability paths (VP9/AV1) that YouTube may otherwise gate by device, codec support, or app behavior.

## What It Does

- Raises VP9/AV1 stream capability limits to 4K/60.
- Preserves 1440p/2160p VP9 and AV1 formats during format filtering.
- Routes VP9/AV1 decoding to a compatible path depending on device and YouTube version.
- Hooks codec support checks so software decode paths can be used correctly.

## Compatibility

- iOS 11+

## Decoder Paths

### VP9

- As of YouTube 20.47.3, the built-in software VP9 decoder (`HAMVPXVideoDecoder`) was removed.
- YTUHD provides `YTUHDVPXVideoDecoder` (libvpx-backed) and replaces the original `HAMVPXVideoDecoder` on app versions that still have it.
- On devices with hardware VP9 decode support, VideoToolbox hardware decode is used.
- On older devices, VP9 can still run through software decode (`YTUHDVPXVideoDecoder`).

### AV1

- As of YouTube 19.28.1, YTUHD adds a software AV1 decoder path (`YTUHDDav1dVideoDecoder`) for devices that do not provide native AV1 hardware decode.
- If hardware AV1 decode is unavailable and YouTube does not provide `HAMDav1dVideoDecoder`, YTUHD provides `YTUHDDav1dVideoDecoder` (dav1d-backed).
- `YTUHDDav1dVideoDecoder` replaces the original `HAMDav1dVideoDecoder` on app versions that have it.
- `Apply film grain` and decode thread controls are forwarded into the dav1d config.

## Server ABR

YTUHD can run with server-driven ABR disabled so format filtering is handled by the client ABR hooks.

- This mode is intended as a fallback/compatibility path.
- Client-ABR-only behavior is reliable only on iOS 14+ and YouTube versions that include PoToken (Proof of Origin) implementation.
- On older environments or app builds without PoToken support, server ABR should remain enabled.

## Settings (In-App)

These options are shown in the YTUHD section inside YouTube settings:

- `Use VP9/AV1`: Enables the codec capability path used by YTUHD. Restart the app after changing.
- `VP9 for all`: Keeps VP9 across all resolutions. If off, non-4K VP9/AV1 streams are filtered out.
- `Use AV1 (dav1d)`: Shows only when hardware AV1 is unavailable.
- `Apply film grain`: Shows with `Use AV1 (dav1d)` and controls AV1 grain synthesis.
- `Decode threads`: Software decode thread count (default: 2).
- `Skip loop filter`, `Loop filter optimization`, `Row threading`: VP9 software decode tuning options.

## Sideloading Notes

Sideloaded apps often lose private entitlements required for hardware VP9 decode, so software decode will be used instead (higher battery cost).

YTUHD uses [libundirect](https://github.com/opa334/libundirect). For sideload builds to work correctly with it, use:

```sh
make SIDELOAD=1
```

Using TrollStore can help preserve entitlements for sideloaded YouTube builds.

## Build

YTUHD requires [Theos](https://theos.dev). Static libraries are built automatically on first `make`:

- VP9: [libvpx](https://www.webmproject.org/code/)
- AV1: [dav1d](https://code.videolan.org/videolan/dav1d)

Install build tools for dav1d first:

```sh
brew install meson ninja
```

Build:

```sh
make package
```

Rebuild third-party static libraries explicitly:

```sh
make libvpx   # vendor/libvpx_ios/libvpx.a
make dav1d    # vendor/dav1d_ios/libdav1d.a
```

### Updating Vendor Libraries

`vendor/libvpx` and `vendor/dav1d` are git submodules.

To pull newer upstream revisions:

```sh
git submodule update --remote
```

Then rebuild the static libraries:

```sh
make libvpx
make dav1d
```

Optional (recommended) sanity step before packaging:

```sh
make package
```

## Licenses

Third-party notices are documented in `NOTICES`.
