# Vendored third-party source: three.js (pinned)

This directory mirrors the official three.js release layout. It is vendored so the
local WebView replica slice is self-contained and never loads from a runtime CDN.

## Provenance

- package: three
- version: 0.160.0 (REVISION = '160', verified in build/three.module.js)
- source: https://unpkg.com/three@0.160.0/ (official npm release contents)
- license: MIT, see LICENSE in this directory (Copyright (c) 2010-2023 three.js authors)
- fetched: 2026-11-10 by T15-V3 for candidate E, the local WebView replica slice

## Files and SHA256

| path | bytes | sha256 |
| --- | --- | --- |
| build/three.module.js | 1272972 | 76dea8151bc9352aef3528b4262e249b2604f62543828328db978d060d61a495 |
| examples/jsm/loaders/GLTFLoader.js | 108522 | d073b438e6a07e1359741dd5d6c76c953420cc0d4fd84eb1bdde94315540e6a3 |
| examples/jsm/utils/BufferGeometryUtils.js | 31906 | 9be041e96308775d00e2695cc607645b9a9b64fd7c0e759dd8f7c00a8d92becb |
| LICENSE | 1081 | 852e0e8699169bf9f6fdc6bda3e682d078dcbc738b5d33e74df594721bff271d |

Upstream paths are preserved so GLTFLoader relative imports resolve unchanged:
GLTFLoader.js imports ../utils/BufferGeometryUtils.js, and both import the bare
specifier three, which the host page resolves with an import map.

## Why this revision

The only three.js artifact already present on this machine was an unofficial r160
bundle (see reports/T15-V3-W3.json), so the dependency was re-fetched from the
official release and pinned byte-exactly above. No file here is modified from upstream.

## Regenerating

curl -sSL -o build/three.module.js https://unpkg.com/three@0.160.0/build/three.module.js
curl -sSL -o examples/jsm/loaders/GLTFLoader.js https://unpkg.com/three@0.160.0/examples/jsm/loaders/GLTFLoader.js
curl -sSL -o examples/jsm/utils/BufferGeometryUtils.js https://unpkg.com/three@0.160.0/examples/jsm/utils/BufferGeometryUtils.js
curl -sSL -o LICENSE https://unpkg.com/three@0.160.0/LICENSE
then re-check with sha256sum against the table above.
