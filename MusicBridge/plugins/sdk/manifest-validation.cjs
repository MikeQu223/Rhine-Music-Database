'use strict';

const schema = require('./manifest.schema.json');

function isRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

const TYPES = {
    array: Array.isArray,
    boolean: (value) => typeof value === 'boolean',
    integer: Number.isSafeInteger,
    null: (value) => value === null,
    object: isRecord,
    string: (value) => typeof value === 'string',
};

const patterns = new Map();

function matchesPattern(text, source) {
    if (!patterns.has(source)) {
        patterns.set(source, new RegExp(source, 'u'));
    }
    return patterns.get(source).test(text);
}

function itemKey(value, depth) {
    if (depth > 64) {
        throw new RangeError('manifest 嵌套过深');
    }
    if (Array.isArray(value)) {
        return `[${value.map((item) => itemKey(item, depth + 1)).join(',')}]`;
    }
    if (isRecord(value)) {
        const fields = Object.keys(value).sort();
        return `{${fields.map((key) => JSON.stringify(key) + ':' + itemKey(value[key], depth + 1)).join(',')}}`;
    }
    return JSON.stringify(value);
}

function objectProblem(value, rules, field, depth) {
    for (const key of rules.required || []) {
        if (!Object.hasOwn(value, key)) {
            return `${field}.${key} 缺失`;
        }
    }
    for (const [key, item] of Object.entries(value)) {
        const child = `${field}.${key}`;
        if (rules.propertyNames && schemaProblem(key, rules.propertyNames, child, depth + 1)) {
            return `${field} 含无效字段名`;
        }
        const declared = rules.properties && Object.hasOwn(rules.properties, key);
        const itemRules = declared ? rules.properties[key] : rules.additionalProperties;
        if (itemRules === false) {
            return `${child} 不受支持`;
        }
        if (isRecord(itemRules)) {
            const problem = schemaProblem(item, itemRules, child, depth + 1);
            if (problem) {
                return problem;
            }
        }
    }
    return '';
}

function arrayProblem(value, rules, field, depth) {
    if (value.length < rules.minItems || value.length > rules.maxItems) {
        return `${field} 数量不符合规范`;
    }
    const items = new Set();
    for (const [index, item] of value.entries()) {
        if (rules.items) {
            const problem = schemaProblem(item, rules.items, `${field}[${index}]`, depth + 1);
            if (problem) {
                return problem;
            }
        }
        if (rules.uniqueItems) {
            const key = itemKey(item, depth + 1);
            if (items.has(key)) {
                return `${field} 含重复项`;
            }
            items.add(key);
        }
    }
    return '';
}

/** 校验本地 manifest schema 使用的关键字，引用仅限同一文件内的定义。 */
function schemaProblem(value, rules, field = 'manifest', depth = 0) {
    if (depth > 64) {
        return `${field} 嵌套过深`;
    }
    if (rules.$ref) {
        return schemaProblem(value, schema.$defs[rules.$ref.slice('#/$defs/'.length)], field, depth + 1);
    }
    if (rules.type && !TYPES[rules.type](value)) {
        return `${field} 类型不符合规范`;
    }
    if (Object.hasOwn(rules, 'const') && value !== rules.const) {
        return `${field} 值不受支持`;
    }
    if (rules.enum && !rules.enum.includes(value)) {
        return `${field} 值不受支持`;
    }
    if (
        rules.oneOf &&
        rules.oneOf.filter((choice) => !schemaProblem(value, choice, field, depth + 1)).length !== 1
    ) {
        return `${field} 格式不符合规范`;
    }
    if (typeof value === 'string') {
        const length = [...value].length;
        if (
            length < rules.minLength ||
            length > rules.maxLength ||
            (rules.pattern && !matchesPattern(value, rules.pattern))
        ) {
            return `${field} 格式不符合规范`;
        }
    }
    if (typeof value === 'number' && (value < rules.minimum || value > rules.maximum)) {
        return `${field} 数值超出规范范围`;
    }
    if (Array.isArray(value)) {
        return arrayProblem(value, rules, field, depth);
    }
    if (isRecord(value)) {
        return objectProblem(value, rules, field, depth);
    }
    return '';
}

module.exports = { isRecord, schemaProblem };
