// WP login flow.
// Стенд: цикл — получить wp-login.php (cookie test_cookie), POST credentials,
// затем у нас есть wordpress_logged_in_* в jar.
// Для REST добавляем X-Cashback-Extension: 1, чтобы пройти origin-check
// (см. class-cashback-rest-api.php:208-231 — короткое замыкание nonce-check).
import http from 'k6/http';
import { check } from 'k6';
import { cfg } from './config.js';

/**
 * Логинимся как user.login + cfg.loadtestPass. Возвращаем cookie jar и
 * хеллпер запроса с правильными заголовками для REST API кэшбэк-плагина.
 */
export function login(user) {
  const jar = http.cookieJar();

  // 1. GET /wp-login.php — поставит test_cookie + nonce
  const r1 = http.get(`${cfg.baseUrl}/wp-login.php`, {
    tags: { name: 'auth_get_login' },
  });
  check(r1, { 'login page 200': (r) => r.status === 200 });

  // 2. POST credentials.
  const body = {
    log: user.login,
    pwd: cfg.loadtestPass,
    'wp-submit': 'Log In',
    redirect_to: `${cfg.baseUrl}/my-account/`,
    testcookie: '1',
  };
  const r2 = http.post(`${cfg.baseUrl}/wp-login.php`, body, {
    redirects: 5,
    tags: { name: 'auth_post_login' },
  });

  // Успех = есть cookie wordpress_logged_in_*
  const cookies = jar.cookiesForURL(cfg.baseUrl);
  const isLogged = Object.keys(cookies).some((k) => k.startsWith('wordpress_logged_in_'));
  check(r2, {
    'login redirected to my-account': (r) => r.url.includes('/my-account'),
    'logged_in cookie set': () => isLogged,
  });

  return { jar, isLogged };
}

/**
 * Базовые headers для REST API (имитируем браузерное расширение).
 */
export function restHeaders() {
  return {
    'X-Cashback-Extension': '1',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };
}
