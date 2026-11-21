// The `kalao` host object (EXTENSIONS.md §4), built over one native call.
// Evaluated once per runtime before the extension's modules; `host` is never
// reachable from extension code.
(function (host) {
  "use strict";
  const call = (op, args) => JSON.parse(host(op, JSON.stringify(args === undefined ? null : args)));

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function base64ToBytes(text) {
    const clean = String(text).replace(/[^A-Za-z0-9+/]/g, "");
    const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
    let buffer = 0, bits = 0, index = 0;
    for (let i = 0; i < clean.length; i++) {
      buffer = (buffer << 6) | B64.indexOf(clean[i]);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[index++] = (buffer >> bits) & 0xff;
      }
    }
    return out.subarray(0, index);
  }
  function utf8Bytes(text) {
    const out = [];
    for (const ch of String(text)) {
      let c = ch.codePointAt(0);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  class Response {
    constructor(raw) {
      this.status = raw.status;
      this.ok = raw.status >= 200 && raw.status < 300;
      this.url = raw.url;
      this.headers = raw.headers;
      this._text = raw.text;
      this._base64 = raw.base64;
    }
    header(name) {
      const values = this.headers[String(name).toLowerCase()];
      return values && values.length ? values[0] : null;
    }
    text() { return this._text; }
    json() { return JSON.parse(this._text); }
    bytes() { return this._base64 !== undefined ? base64ToBytes(this._base64) : utf8Bytes(this._text); }
  }

  function wrapElement(raw) {
    return Object.freeze({
      text: () => raw.text,
      html: () => raw.html,
      outerHtml: () => raw.outerHtml,
      attr: (name) => (Object.prototype.hasOwnProperty.call(raw.attrs, name) ? raw.attrs[name] : null),
      attrs: () => Object.assign({}, raw.attrs),
      select: (selector) => select(raw.outerHtml, selector, true),
      selectFirst: (selector) => select(raw.outerHtml, selector, true)[0] || null,
    });
  }
  function select(html, selector, fragment) {
    return call("html.select", { html: html, selector: String(selector), fragment: fragment }).map(wrapElement);
  }

  const digest = (algorithm) => (data, options) =>
    call("crypto.digest", { algorithm, data: String(data), encoding: options && options.encoding });

  const kalao = {
    fetch: async (url, options) => {
      const o = options || {};
      return new Response(call("fetch", {
        url: String(url),
        method: o.method,
        headers: o.headers,
        body: o.body === undefined || o.body === null ? undefined
          : typeof o.body === "string" ? o.body : JSON.stringify(o.body),
        timeoutMs: o.timeoutMs,
      }));
    },
    settings: {
      get: (key) => call("settings.get", { key: String(key) }),
      set: (key, value) => { call("settings.set", { key: String(key), value: value === undefined ? null : value }); },
    },
    storage: {
      get: (key) => call("storage.get", { key: String(key) }),
      set: (key, value) => { call("storage.set", { key: String(key), value: value === undefined ? null : value }); },
      remove: (key) => { call("storage.remove", { key: String(key) }); },
    },
    auth: {
      callbackUrl: () => call("auth.callbackUrl"),
      openBrowser: async (url) => { call("auth.openBrowser", { url: String(url) }); },
      waitForCallback: async (options) => call("auth.waitForCallback", { timeoutMs: options && options.timeoutMs }),
    },
    html: {
      parse: (text) => {
        const html = String(text);
        return Object.freeze({
          select: (selector) => select(html, selector, false),
          selectFirst: (selector) => select(html, selector, false)[0] || null,
        });
      },
    },
    crypto: {
      sha1: digest("sha1"),
      sha256: digest("sha256"),
      md5: digest("md5"),
      hmac: (algorithm, key, data, options) => call("crypto.hmac", {
        algorithm: String(algorithm), key: String(key), data: String(data),
        keyEncoding: options && options.keyEncoding, encoding: options && options.encoding,
      }),
      aes: {
        gcmEncrypt: (options) => call("crypto.aesGcm", Object.assign({ encrypt: true }, options)),
        gcmDecrypt: (options) => call("crypto.aesGcm", Object.assign({ encrypt: false }, options)),
      },
      base64: {
        encode: (text) => call("base64.encode", { data: String(text) }),
        decode: (text) => call("base64.decode", { data: String(text) }),
        toBytes: base64ToBytes,
      },
    },
    log: {
      debug: (...parts) => call("log", { level: "debug", message: parts.map(String).join(" ") }),
      info: (...parts) => call("log", { level: "info", message: parts.map(String).join(" ") }),
      warn: (...parts) => call("log", { level: "warn", message: parts.map(String).join(" ") }),
      error: (...parts) => call("log", { level: "error", message: parts.map(String).join(" ") }),
    },
    url: {
      params: (object) => Object.keys(object || {})
        .filter((key) => object[key] !== undefined && object[key] !== null)
        .map((key) => encodeURIComponent(key) + "=" + encodeURIComponent(String(object[key])))
        .join("&"),
    },
    time: { now: () => Date.now() },
  };
  const freeze = (object) => {
    Object.values(object).forEach((value) => { if (value && typeof value === "object") freeze(value); });
    return Object.freeze(object);
  };
  Object.defineProperty(globalThis, "kalao", { value: freeze(kalao), enumerable: false });
  Object.defineProperty(globalThis, "console", {
    value: Object.freeze({ log: kalao.log.info, info: kalao.log.info, warn: kalao.log.warn, error: kalao.log.error, debug: kalao.log.debug }),
  });

  // No code from strings (EXTENSIONS.md §4): eval and the Function
  // constructors are removed once the package's own modules are compiled.
  const refuse = function () { throw new TypeError("code generation from strings is disabled"); };
  delete globalThis.eval;
  for (const sample of [function () {}, async function () {}, function* () {}, async function* () {}]) {
    Object.defineProperty(Object.getPrototypeOf(sample), "constructor", { value: refuse });
  }
  Object.defineProperty(globalThis, "Function", { value: refuse });
});
