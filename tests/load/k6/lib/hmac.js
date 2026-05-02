// HMAC SHA256 helper для постбэк-сценариев.
// Соответствует receiver.py:101-157: source=body|query-raw|path-and-body,
// format=hex|base64|sha256-prefix-hex, header configurable.
//
// Нагрузочные тесты используют: source=body, format=hex, header=X-Signature.
import crypto from 'k6/crypto';

export function signBody(secret, body) {
  // hmac → hex
  return crypto.hmac('sha256', secret, body, 'hex');
}

export function signQueryRaw(secret, queryString) {
  return crypto.hmac('sha256', secret, queryString, 'hex');
}

/**
 * Сгенерировать уникальный hex (UUID v7-ish): 12 hex (timestamp_ms) + 1 + 19 random hex = 32.
 */
export function uuid7Hex() {
  const ts = Date.now();
  const tsHex = ts.toString(16).padStart(12, '0');
  // 19 random hex symbols
  const rnd = randomHex(19);
  return tsHex + '7' + rnd;
}

function randomHex(n) {
  const buf = new Uint8Array(Math.ceil(n / 2));
  for (let i = 0; i < buf.length; i++) buf[i] = Math.floor(Math.random() * 256);
  let s = '';
  for (let i = 0; i < buf.length; i++) s += buf[i].toString(16).padStart(2, '0');
  return s.slice(0, n);
}

/**
 * Уникальный uniq_id для постбэков (не коллидирует с дедупликацией).
 */
export function uniqId() {
  return uuid7Hex().slice(0, 24);
}
