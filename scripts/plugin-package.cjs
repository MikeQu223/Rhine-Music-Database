#!/usr/bin/env node
'use strict';

// 兼容入口：实现随发布包进入 MusicBridge，CLI 仍从 scripts 调用。
require('../MusicBridge/plugin-package.cjs').runCli(process.argv.slice(2));
