'use strict';

module.exports = {
    create(host) {
        const manifest = host.manifest || {};
        const operations = new Set(
            Object.entries(manifest.operations || {})
                .filter(([, enabled]) => enabled)
                .map(([operation]) => operation),
        );
        return {
            async dispatchNative(operation, args) {
                if (
                    !operations.has(operation) ||
                    operation !== 'search' ||
                    !Array.isArray(args)
                ) {
                    const error = new Error('unsupported operation');
                    error.code = 400;
                    throw error;
                }
                return { items: [], rawCount: 0, total: 0, more: false };
            },
            async capabilities() {
                return manifest.capabilities || {};
            },
        };
    },
};
