import Foundation

/// The JavaScript half of the LX Music 2.0 user-API host. It runs before an
/// imported script and installs `globalThis.lx` (`EVENT_NAMES`, `request`,
/// `on`, `send`, `utils`), forwarding everything that needs the network or
/// native crypto to `LXScriptRuntime` through a keyed bridge.
///
/// Written for Coda after the protocol LX Music defines for custom sources
/// (lyswhut/lx-music-mobile, Apache-2.0); no upstream code is copied.
enum LXHostPreload {
    static let script = #"""
'use strict'
globalThis.__coda_setup__ = (key, scriptInfo) => {
  delete globalThis.__coda_setup__
  const host = globalThis.__coda_host__
  delete globalThis.__coda_host__

  const send = (action, data) => host.call(key, action, JSON.stringify(data === undefined ? null : data))
  const MAX_TEXT = 4 * 1024 * 1024
  const checked = (text) => {
    if (typeof text === 'string' && text.length > MAX_TEXT) throw new Error('Input too long')
    return text
  }

  // UTF-8 and Base64, in plain JavaScript: JavaScriptCore has no TextEncoder or atob.
  const utf8Encode = (text) => {
    const bytes = []
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i)
      if (code >= 0xd800 && code < 0xdc00 && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1)
        if (next >= 0xdc00 && next < 0xe000) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00)
          i++
        }
      }
      if (code < 0x80) bytes.push(code)
      else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63))
      else if (code < 0x10000) bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63))
      else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63))
    }
    return bytes
  }
  const utf8Decode = (bytes) => {
    let out = ''
    for (let i = 0; i < bytes.length;) {
      const b = bytes[i]
      let code
      if (b < 0x80) { code = b; i += 1 }
      else if (b >= 0xf0) { code = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63); i += 4 }
      else if (b >= 0xe0) { code = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); i += 3 }
      else if (b >= 0xc0) { code = ((b & 31) << 6) | (bytes[i + 1] & 63); i += 2 }
      else { code = 0xfffd; i += 1 }
      out += String.fromCodePoint(code)
    }
    return out
  }
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  const b64Encode = (bytes) => {
    let out = ''
    for (let i = 0; i < bytes.length; i += 3) {
      const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0)
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63]
      out += i + 1 < bytes.length ? B64[(n >> 6) & 63] : '='
      out += i + 2 < bytes.length ? B64[n & 63] : '='
    }
    return out
  }
  const b64Decode = (text) => {
    const clean = String(text).replace(/[^A-Za-z0-9+/_-]/g, '').replace(/-/g, '+').replace(/_/g, '/')
    const bytes = []
    let buffer = 0
    let bits = 0
    for (const ch of clean) {
      buffer = (buffer << 6) | B64.indexOf(ch)
      bits += 6
      if (bits >= 8) {
        bits -= 8
        bytes.push((buffer >> bits) & 0xff)
      }
    }
    return new Uint8Array(bytes)
  }
  const toBytes = (data) => {
    if (typeof data === 'string') return utf8Encode(data)
    if (Array.isArray(data) || ArrayBuffer.isView(data)) return Array.from(data)
    if (data instanceof ArrayBuffer) return Array.from(new Uint8Array(data))
    throw new Error('Unsupported data type: ' + typeof data)
  }

  // Timers run on the native queue.
  const timers = new Map()
  let timerSeq = 1
  const setTimeout_ = (callback, delay = 0, ...args) => {
    if (typeof callback !== 'function') throw new Error('callback required a function')
    const id = timerSeq++
    timers.set(id, { callback, args, repeat: 0 })
    host.setTimeout(key, id, Math.max(0, Number(delay) || 0))
    return id
  }
  const setInterval_ = (callback, delay = 0, ...args) => {
    if (typeof callback !== 'function') throw new Error('callback required a function')
    const id = timerSeq++
    const interval = Math.max(10, Number(delay) || 0)
    timers.set(id, { callback, args, repeat: interval })
    host.setTimeout(key, id, interval)
    return id
  }
  const clearTimer = (id) => { timers.delete(id) }
  const fireTimer = (id) => {
    const timer = timers.get(id)
    if (!timer) return
    if (timer.repeat) host.setTimeout(key, id, timer.repeat)
    else timers.delete(id)
    timer.callback(...timer.args)
  }

  // HTTP, performed by the host.
  const pendingRequests = new Map()
  let requestSeq = 1
  const request = (url, options, callback) => {
    if (typeof options === 'function') { callback = options; options = {} }
    const { method = 'get', timeout, headers, body, form, formData, binary } = options || {}
    const id = String(requestSeq++)
    pendingRequests.set(id, callback)
    send('request', {
      id,
      url: String(url),
      method: String(method).toUpperCase(),
      timeout: typeof timeout === 'number' && timeout > 0 ? timeout : 0,
      headers: headers || {},
      body: body === undefined ? null : body,
      form: form || null,
      formData: formData || null,
      binary: binary === true,
    })
    return () => {
      if (pendingRequests.delete(id)) send('cancel', { id })
    }
  }
  const handleResponse = ({ id, error, response }) => {
    const callback = pendingRequests.get(id)
    if (!pendingRequests.delete(id) || typeof callback !== 'function') return
    if (error) return callback(new Error(error), null, null)
    if (response.bodyBase64 != null) {
      response.body = b64Decode(response.bodyBase64)
      delete response.bodyBase64
    }
    callback(null, response, response.body)
  }

  // Events.
  const EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' }
  const PLATFORMS = ['kw', 'kg', 'tx', 'wy', 'mg']
  let requestHandler = null
  let isInited = false
  let isAlerted = false

  const handleInited = (info) => {
    const sources = {}
    const declared = (info && info.sources) || {}
    for (const platform of PLATFORMS) {
      const source = declared[platform]
      if (!source || source.type !== 'music') continue
      sources[platform] = {
        name: typeof source.name === 'string' ? source.name : '',
        actions: Array.isArray(source.actions) ? source.actions.filter(a => typeof a === 'string') : [],
        qualitys: Array.isArray(source.qualitys) ? source.qualitys.filter(q => typeof q === 'string') : [],
      }
    }
    send('inited', { sources })
  }

  const handleCall = ({ id, source, action, info }) => {
    const fail = (err) => send('reply', { id, ok: false, error: String((err && err.message) || err || 'failed').slice(0, 300) })
    if (!requestHandler) return fail('The script did not register a request handler')
    try {
      Promise.resolve(requestHandler.call(globalThis.lx, { source, action, info })).then(result => {
        if (action !== 'musicUrl') throw new Error('Unsupported action')
        if (typeof result !== 'string' || result.length > 4096 || !/^https?:/i.test(result)) throw new Error('Invalid music URL')
        send('reply', { id, ok: true, url: result })
      }).catch(fail)
    } catch (err) {
      fail(err)
    }
  }

  const utils = {
    crypto: {
      md5(text) {
        if (typeof text !== 'string') throw new Error('param required a string')
        return host.md5(checked(text))
      },
      randomBytes(size) {
        const bytes = new Uint8Array(size)
        for (let i = 0; i < size; i++) bytes[i] = Math.floor(Math.random() * 256)
        return bytes
      },
      aesEncrypt(buffer, mode, keyBytes, iv) {
        const result = host.aesEncrypt(b64Encode(toBytes(buffer)), b64Encode(toBytes(keyBytes)),
                                       iv == null ? '' : b64Encode(toBytes(iv)), String(mode))
        if (result == null) throw new Error('aesEncrypt failed')
        return b64Decode(result)
      },
      rsaEncrypt(buffer, publicKey) {
        if (typeof publicKey !== 'string') throw new Error('Invalid RSA key')
        const result = host.rsaEncrypt(b64Encode(toBytes(buffer)), publicKey)
        if (result == null) throw new Error('rsaEncrypt failed')
        return b64Decode(result)
      },
    },
    buffer: {
      from(input, encoding) {
        if (typeof input === 'string') {
          switch (encoding) {
            case 'base64': return b64Decode(input)
            case 'hex': return new Uint8Array((input.match(/.{1,2}/g) || []).map(byte => parseInt(byte, 16)))
            case 'binary':
            case 'latin1': return new Uint8Array(Array.from(input, ch => ch.charCodeAt(0) & 0xff))
            default: return new Uint8Array(utf8Encode(input))
          }
        }
        if (Array.isArray(input) || ArrayBuffer.isView(input)) return new Uint8Array(input)
        if (input instanceof ArrayBuffer) return new Uint8Array(input)
        throw new Error('Unsupported input type')
      },
      bufToString(buf, format) {
        const bytes = toBytes(buf)
        switch (format) {
          case 'hex': return bytes.map(byte => byte.toString(16).padStart(2, '0')).join('')
          case 'base64': return b64Encode(bytes)
          case 'binary':
          case 'latin1': return bytes.map(byte => String.fromCharCode(byte)).join('')
          default: return utf8Decode(bytes)
        }
      },
    },
  }

  const lx = {
    EVENT_NAMES,
    request,
    send(eventName, data) {
      return new Promise((resolve, reject) => {
        switch (eventName) {
          case EVENT_NAMES.inited:
            if (isInited) return reject(new Error('Script is inited'))
            isInited = true
            handleInited(data)
            return resolve()
          case EVENT_NAMES.updateAlert:
            if (isAlerted) return reject(new Error('The update alert can only be called once.'))
            isAlerted = true
            if (!data || typeof data.log !== 'string') return reject(new Error('log is required.'))
            send('updateAlert', {
              log: data.log.slice(0, 1024),
              updateUrl: typeof data.updateUrl === 'string' && /^https?:\/\//i.test(data.updateUrl) ? data.updateUrl.slice(0, 1024) : null,
            })
            return resolve()
          default:
            return reject(new Error('The event is not supported: ' + eventName))
        }
      })
    },
    on(eventName, handler) {
      if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + eventName))
      requestHandler = handler
      return Promise.resolve()
    },
    utils,
    currentScriptInfo: scriptInfo,
    version: '2.0.0',
    env: 'mobile',
  }
  const deepFreeze = (value) => {
    if (value == null || (typeof value !== 'object' && typeof value !== 'function') || Object.isFrozen(value)) return
    Object.freeze(value)
    for (const child of Object.values(value)) deepFreeze(child)
  }
  deepFreeze(lx)
  Object.defineProperty(globalThis, 'lx', { value: lx, writable: false, configurable: false, enumerable: true })
  globalThis.setTimeout = setTimeout_
  globalThis.clearTimeout = clearTimer
  globalThis.setInterval = setInterval_
  globalThis.clearInterval = clearTimer

  Object.defineProperty(globalThis, '__coda_native__', {
    enumerable: false,
    configurable: false,
    writable: false,
    value: (callerKey, action, payload) => {
      if (callerKey !== key) return
      const data = payload == null ? null : JSON.parse(payload)
      switch (action) {
        case 'timer': return fireTimer(data)
        case 'response': return handleResponse(data)
        case 'call': return handleCall(data)
      }
    },
  })
}
"""#
}
