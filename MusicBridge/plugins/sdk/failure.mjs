// 仅传递上游公开的错误摘要，不复制认证记录或原始响应。
export function safeLoginDetails(body, includePrevious = true) {
    const result = {};
    for (const name of ['failureStage', 'failureReason', 'errorKey', 'upstreamErrorKey']) {
        if (typeof body?.[name] === 'string' && /^[a-z.-]{1,80}$/.test(body[name])) {
            result[name] = body[name];
        }
    }
    for (const name of [
        'retryAfterMs',
        'upstreamHttpStatus',
        'upstreamCode',
        'upstreamGlobalCode',
        'upstreamSubCode',
    ]) {
        if (typeof body?.[name] === 'number' && Number.isFinite(body[name])) {
            result[name] = body[name];
        }
    }
    if (includePrevious && body?.lastFailure) {
        result.lastFailure = safeLoginDetails(body.lastFailure, false);
    }
    if (includePrevious && body?.primaryFailure) {
        result.primaryFailure = safeLoginDetails(body.primaryFailure, false);
    }
    for (const name of ['retryable', 'writeAttempted']) {
        if (typeof body?.[name] === 'boolean') {
            result[name] = body[name];
        }
    }
    if (body?.verification === 'unconfirmed') {
        result.verification = 'unconfirmed';
    }
    return result;
}
