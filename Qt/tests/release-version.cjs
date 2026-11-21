const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { createUpdateFeed } = require('../../scripts/create-update-feed.cjs');
const {
    buildVersion,
    packageIdentity,
    sentryEnvironment,
    distributionPlatforms,
} = require('../../scripts/release-version.cjs');
assert.deepEqual(buildVersion('v1.10.2'), { version: '1.10.2', release: true });
assert.deepEqual(buildVersion('2.0.0'), { version: '2.0.0', release: true });
assert.equal(buildVersion('').release, false);
const development = buildVersion('');
assert.equal(development.version, '0.0.0');
assert.match(packageIdentity(development), /^[0-9a-f]{12,40}$/);
assert.equal(packageIdentity(buildVersion('v1.10.2')), 'v1.10.2');
assert.equal(sentryEnvironment(development, ''), 'development');
assert.equal(sentryEnvironment(buildVersion('v1.10.2'), ''), 'production');
assert.equal(sentryEnvironment(development, 'staging'), 'staging');
for (const invalid of ['v1.0', 'v01.0.0', 'v1.0.0-beta.1', '1.0.0\n', 'v65536.0.0', '$(touch bad)']) {
    assert.throws(() => buildVersion(invalid));
}
console.log('Release version injection checks passed');

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-update-feed-'));
try {
    const contents = Buffer.from('local distribution fixture');
    for (const platform of distributionPlatforms) {
        fs.writeFileSync(path.join(temporary, `RhineMusicDatabase-v1.2.3-${platform}`), contents);
    }
    const feed = createUpdateFeed(temporary, 'v1.2.3');
    assert.equal(feed.tag_name, 'v1.2.3');
    assert.equal(feed.assets.length, 4);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(temporary, 'update.json'))), feed);
    for (const asset of feed.assets) {
        assert.equal(asset.size, contents.length);
        assert.equal(asset.digest, 'sha256:' + crypto.createHash('sha256').update(contents).digest('hex'));
        assert(asset.browser_download_url.endsWith('/v1.2.3/' + asset.name));
    }
    fs.unlinkSync(path.join(temporary, feed.assets[0].name));
    assert.throws(() => createUpdateFeed(temporary, 'v1.2.3'));
} finally {
    fs.rmSync(temporary, { recursive: true, force: true });
}
console.log('Static update feed creation, package checksums and missing-package rejection passed');
