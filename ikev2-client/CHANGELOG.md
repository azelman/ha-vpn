# Changelog

## 1.0.2

- Fix decoding of PKCS#12 bundles that use an empty import password.

## 1.0.1

- Add safe PKCS#12 decoding diagnostics without logging passwords or certificate contents.

## 1.0.0

- Initial release.
- Check tunnel health every five minutes by default and recover stale sessions
  before reconnecting.
- Migrate image builds from the retired Home Assistant builder configuration to
  a Dockerfile-based build.
- Add CI validation for shell, YAML, app metadata, and image builds.
- PKCS#12 certificate, EAP-MSCHAPv2, and PSK authentication.
- Split-tunnel and full-tunnel traffic selectors.
- Automatic health checks and reconnects.
