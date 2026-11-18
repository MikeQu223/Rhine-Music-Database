// 只检查自维护脚本；上游、依赖和生成文件保留原样。
export default [
    {
        ignores: [
            'node_modules/**',
            'output/**',
            '**/*.app/**',
            'vendor/**',
            'third_party/**',
            'FidelityFX-SDK/**',
            'MusicBridge/upstream/**',
            // 本地插件包及其单文件 bundle 是独立发布物，不参与 core lint。
            'MusicBridge/local-plugins/**',
        ],
    },
    {
        files: [
            'Qt/tests/**/*.{mjs,cjs}',
            'MusicBridge/*.cjs',
            'MusicBridge/client/**/*.mjs',
            'MusicBridge/core/**/*.cjs',
            'MusicBridge/plugins/sdk/**/*.mjs',
            'scripts/*.{cjs,mjs}',
            'eslint.config.mjs',
        ],
        languageOptions: {
            ecmaVersion: 'latest',
            sourceType: 'module',
        },
        rules: {
            curly: ['error', 'all'],
            'one-var': ['error', 'never'],
            'no-nested-ternary': 'error',
            'no-sequences': ['error', { allowInParentheses: false }],
            // 能力探测和可选回调允许空 catch，其他空块仍然报错。
            'no-empty': ['error', { allowEmptyCatch: true }],
        },
    },
];
