import Foundation
import WebKit

final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum WebScripts {
    /// Modern ES2023–ES2026 & Web scheduling compatibility layer (100% verbatim parity with JetBrowser's WebCompatEngine).
    /// Runs in `.page` world with zero DOM observers and zero prototype conflicts.
    static func compatPolyfillScript() -> WKUserScript {
        let js = #"""
(function() {
  'use strict';
  var g = typeof globalThis !== 'undefined' ? globalThis : (typeof window !== 'undefined' ? window : self);
  if (!g || g.__jbWebCompatApplied) return;
  try {
    Object.defineProperty(g, '__jbWebCompatApplied', { value: true, configurable: false, enumerable: false, writable: false });
  } catch (_) {
    g.__jbWebCompatApplied = true;
  }

  function def(target, name, fn) {
    if (!target || (name in target && typeof target[name] === 'function')) return;
    try {
      Object.defineProperty(target, name, {
        value: fn,
        writable: true,
        configurable: true,
        enumerable: false
      });
    } catch (_) {}
  }

  // 1. Object.hasOwn & structuredClone & crypto.randomUUID (iOS 15.0-15.3 safety net)
  def(Object, 'hasOwn', function hasOwn(obj, prop) {
    if (obj == null) throw new TypeError('Cannot convert undefined or null to object');
    return Object.prototype.hasOwnProperty.call(Object(obj), prop);
  });

  if (typeof g.structuredClone !== 'function') {
    def(g, 'structuredClone', function structuredClone(val) {
      if (val === undefined || val === null || typeof val !== 'object') return val;
      if (val instanceof Date) return new Date(val.getTime());
      if (val instanceof RegExp) return new RegExp(val.source, val.flags);
      if (val instanceof Map) {
        var m = new Map();
        val.forEach(function(v, k) { m.set(structuredClone(k), structuredClone(v)); });
        return m;
      }
      if (val instanceof Set) {
        var s = new Set();
        val.forEach(function(v) { s.add(structuredClone(v)); });
        return s;
      }
      if (ArrayBuffer.isView(val)) {
        return new val.constructor(val.buffer.slice(val.byteOffset, val.byteOffset + val.byteLength));
      }
      if (val instanceof ArrayBuffer) return val.slice(0);
      return JSON.parse(JSON.stringify(val));
    });
  }

  if (g.crypto && typeof g.crypto.randomUUID !== 'function' && typeof g.crypto.getRandomValues === 'function') {
    def(g.crypto, 'randomUUID', function randomUUID() {
      var b = new Uint8Array(16);
      g.crypto.getRandomValues(b);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var h = [];
      for (var i = 0; i < 16; i++) h.push((b[i] + 0x100).toString(16).slice(1));
      return h[0]+h[1]+h[2]+h[3]+'-'+h[4]+h[5]+'-'+h[6]+h[7]+'-'+h[8]+h[9]+'-'+h[10]+h[11]+h[12]+h[13]+h[14]+h[15];
    });
  }

  // 2. requestIdleCallback / cancelIdleCallback & scheduler.postTask / scheduler.yield
  var nowFn = (g.performance && typeof g.performance.now === 'function')
    ? function() { return g.performance.now(); }
    : function() { return Date.now(); };

  if (typeof g.requestIdleCallback !== 'function') {
    def(g, 'requestIdleCallback', function requestIdleCallback(cb, opts) {
      if (typeof cb !== 'function') throw new TypeError('Callback must be a function');
      var start = nowFn();
      var timeout = (opts && typeof opts.timeout === 'number' && opts.timeout > 0) ? opts.timeout : 0;
      var delay = timeout > 0 ? Math.min(timeout, 24) : 1;
      return setTimeout(function() {
        var didTimeout = timeout > 0 && (nowFn() - start) >= timeout;
        cb({
          didTimeout: didTimeout,
          timeRemaining: function() {
            return didTimeout ? 0 : Math.max(0, 16.6 - (nowFn() - start));
          }
        });
      }, delay);
    });
    def(g, 'cancelIdleCallback', function cancelIdleCallback(id) {
      clearTimeout(id);
    });
  }

  if (!g.scheduler || typeof g.scheduler !== 'object') {
    try {
      Object.defineProperty(g, 'scheduler', { value: {}, writable: true, configurable: true, enumerable: true });
    } catch (_) {
      g.scheduler = {};
    }
  }
  if (g.scheduler) {
    def(g.scheduler, 'yield', function yieldTask() {
      return new Promise(function(resolve) { setTimeout(resolve, 0); });
    });
    def(g.scheduler, 'postTask', function postTask(cb, options) {
      var opts = options || {};
      var signal = opts.signal;
      var delay = (typeof opts.delay === 'number' && opts.delay > 0) ? opts.delay : 0;
      var prio = opts.priority || 'user-visible';
      if (delay === 0 && prio === 'background') delay = 4;
      return new Promise(function(resolve, reject) {
        if (signal && signal.aborted) {
          reject(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError'));
          return;
        }
        var timerId = null;
        var onAbort = function() {
          if (timerId !== null) clearTimeout(timerId);
          reject(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError'));
        };
        if (signal && typeof signal.addEventListener === 'function') {
          signal.addEventListener('abort', onAbort, { once: true });
        }
        timerId = setTimeout(function() {
          if (signal && typeof signal.removeEventListener === 'function') {
            signal.removeEventListener('abort', onAbort);
          }
          try {
            resolve(cb());
          } catch (err) {
            reject(err);
          }
        }, delay);
      });
    });
  }

  // 3. ReadableStream.prototype.values & [Symbol.asyncIterator] (AI streaming SSE/fetch support)
  if (typeof g.ReadableStream === 'function' && g.ReadableStream.prototype && typeof Symbol !== 'undefined' && Symbol.asyncIterator) {
    var rsProto = g.ReadableStream.prototype;
    if (typeof rsProto.values !== 'function') {
      def(rsProto, 'values', function values(options) {
        var preventCancel = !!(options && options.preventCancel);
        var stream = this;
        var reader = stream.getReader();
        var doneFlag = false;
        var iter = {
          next: function() {
            if (doneFlag) return Promise.resolve({ value: undefined, done: true });
            return reader.read().then(function(res) {
              if (res.done) {
                doneFlag = true;
                try { reader.releaseLock(); } catch (_) {}
                return { value: undefined, done: true };
              }
              return { value: res.value, done: false };
            }, function(err) {
              doneFlag = true;
              try { reader.releaseLock(); } catch (_) {}
              throw err;
            });
          },
          return: function(val) {
            if (!doneFlag) {
              doneFlag = true;
              if (!preventCancel) {
                return Promise.resolve(reader.cancel(val)).then(function() {
                  try { reader.releaseLock(); } catch (_) {}
                  return { value: val, done: true };
                });
              }
              try { reader.releaseLock(); } catch (_) {}
            }
            return Promise.resolve({ value: val, done: true });
          }
        };
        iter[Symbol.asyncIterator] = function() { return this; };
        return iter;
      });
    }
    if (typeof rsProto[Symbol.asyncIterator] !== 'function') {
      def(rsProto, Symbol.asyncIterator, rsProto.values);
    }
  }

  // 4. Promise.withResolvers & Promise.try
  def(Promise, 'withResolvers', function withResolvers() {
    var resolve, reject;
    var promise = new this(function(res, rej) {
      resolve = res;
      reject = rej;
    });
    return { promise: promise, resolve: resolve, reject: reject };
  });

  def(Promise, 'try', function promiseTry(fn) {
    var C = typeof this === 'function' ? this : Promise;
    var args = Array.prototype.slice.call(arguments, 1);
    return new C(function(resolve) {
      resolve(fn.apply(undefined, args));
    });
  });

  // 5. Object.groupBy & Map.groupBy
  def(Object, 'groupBy', function groupBy(items, callbackFn) {
    if (items == null) throw new TypeError('Object.groupBy requires an iterable');
    if (typeof callbackFn !== 'function') throw new TypeError('callbackFn must be a function');
    var out = Object.create(null);
    var k = 0;
    for (var item of items) {
      var key = String(callbackFn(item, k++));
      if (out[key] === undefined) out[key] = [item];
      else out[key].push(item);
    }
    return out;
  });

  if (typeof Map === 'function') {
    def(Map, 'groupBy', function groupBy(items, callbackFn) {
      if (items == null) throw new TypeError('Map.groupBy requires an iterable');
      if (typeof callbackFn !== 'function') throw new TypeError('callbackFn must be a function');
      var map = new Map();
      var k = 0;
      for (var item of items) {
        var key = callbackFn(item, k++);
        var bucket = map.get(key);
        if (bucket === undefined) map.set(key, [item]);
        else bucket.push(item);
      }
      return map;
    });
  }

  // 6. URL.canParse & URL.parse
  if (typeof URL === 'function') {
    def(URL, 'canParse', function canParse(url, base) {
      try {
        if (base !== undefined) new URL(url, base);
        else new URL(url);
        return true;
      } catch (_) {
        return false;
      }
    });
    def(URL, 'parse', function parse(url, base) {
      try {
        return base !== undefined ? new URL(url, base) : new URL(url);
      } catch (_) {
        return null;
      }
    });
  }

  // 7. AbortSignal.timeout & AbortSignal.any
  if (typeof AbortSignal === 'function' && typeof AbortController === 'function') {
    def(AbortSignal, 'timeout', function timeout(ms) {
      var ctrl = new AbortController();
      setTimeout(function() {
        var reason;
        try {
          reason = new DOMException('The operation timed out.', 'TimeoutError');
        } catch (_) {
          reason = new Error('TimeoutError');
          reason.name = 'TimeoutError';
        }
        ctrl.abort(reason);
      }, Number(ms) || 0);
      return ctrl.signal;
    });

    def(AbortSignal, 'any', function any(signals) {
      if (signals == null || typeof signals[Symbol.iterator] !== 'function') {
        throw new TypeError('AbortSignal.any requires an iterable of AbortSignals');
      }
      var list = Array.from(signals);
      var ctrl = new AbortController();
      for (var i = 0; i < list.length; i++) {
        var sig = list[i];
        if (!sig) continue;
        if (sig.aborted) {
          ctrl.abort(sig.reason);
          return ctrl.signal;
        }
      }
      var listeners = [];
      var cleanup = function() {
        for (var j = 0; j < listeners.length; j++) {
          listeners[j].s.removeEventListener('abort', listeners[j].fn);
        }
        listeners.length = 0;
      };
      for (var k = 0; k < list.length; k++) {
        (function(s) {
          if (!s || typeof s.addEventListener !== 'function') return;
          var fn = function() {
            cleanup();
            ctrl.abort(s.reason);
          };
          listeners.push({ s: s, fn: fn });
          s.addEventListener('abort', fn, { once: true });
        })(list[k]);
      }
      return ctrl.signal;
    });
  }

  // 8. ES2025 Set.prototype methods
  if (typeof Set === 'function' && Set.prototype) {
    var sp = Set.prototype;
    var toSetLike = function(other) {
      if (other instanceof Set) return other;
      if (other && typeof other === 'object' && typeof other.has === 'function' && typeof other.keys === 'function') {
        return other;
      }
      throw new TypeError('Argument must be a Set or Set-like object');
    };
    def(sp, 'union', function union(other) {
      var o = toSetLike(other);
      var res = new Set(this);
      var it = o.keys();
      for (var step = it.next(); !step.done; step = it.next()) res.add(step.value);
      return res;
    });
    def(sp, 'intersection', function intersection(other) {
      var o = toSetLike(other);
      var res = new Set();
      this.forEach(function(v) { if (o.has(v)) res.add(v); });
      return res;
    });
    def(sp, 'difference', function difference(other) {
      var o = toSetLike(other);
      var res = new Set();
      this.forEach(function(v) { if (!o.has(v)) res.add(v); });
      return res;
    });
    def(sp, 'symmetricDifference', function symmetricDifference(other) {
      var o = toSetLike(other);
      var res = new Set(this);
      var it = o.keys();
      for (var step = it.next(); !step.done; step = it.next()) {
        var v = step.value;
        if (this.has(v)) res.delete(v);
        else res.add(v);
      }
      return res;
    });
    def(sp, 'isSubsetOf', function isSubsetOf(other) {
      var o = toSetLike(other);
      if (typeof o.size === 'number' && this.size > o.size) return false;
      var it = this.values();
      for (var step = it.next(); !step.done; step = it.next()) {
        if (!o.has(step.value)) return false;
      }
      return true;
    });
    def(sp, 'isSupersetOf', function isSupersetOf(other) {
      var o = toSetLike(other);
      if (typeof o.size === 'number' && this.size < o.size) return false;
      var it = o.keys();
      for (var step = it.next(); !step.done; step = it.next()) {
        if (!this.has(step.value)) return false;
      }
      return true;
    });
    def(sp, 'isDisjointFrom', function isDisjointFrom(other) {
      var o = toSetLike(other);
      var it = this.values();
      for (var step = it.next(); !step.done; step = it.next()) {
        if (o.has(step.value)) return false;
      }
      return true;
    });
  }

  // 9. ES2025 Iterator Helpers (Iterator.from & IteratorPrototype methods)
  try {
    var iterProto = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
    if (iterProto) {
      var closeIter = function(it) {
        if (it && typeof it.return === 'function') {
          try { it.return(); } catch (_) {}
        }
      };
      var wrapGen = function(genFn) {
        return genFn;
      };
      def(iterProto, 'map', wrapGen(function* map(mapper) {
        if (typeof mapper !== 'function') throw new TypeError('mapper must be a function');
        var i = 0;
        var it = this;
        try {
          while (true) {
            var step = it.next();
            if (step.done) return;
            yield mapper(step.value, i++);
          }
        } catch (e) {
          closeIter(it);
          throw e;
        }
      }));
      def(iterProto, 'filter', wrapGen(function* filter(predicate) {
        if (typeof predicate !== 'function') throw new TypeError('predicate must be a function');
        var i = 0;
        var it = this;
        try {
          while (true) {
            var step = it.next();
            if (step.done) return;
            if (predicate(step.value, i++)) yield step.value;
          }
        } catch (e) {
          closeIter(it);
          throw e;
        }
      }));
      def(iterProto, 'take', wrapGen(function* take(limit) {
        var rem = Math.floor(Number(limit));
        if (Number.isNaN(rem) || rem < 0) throw new RangeError('Invalid take limit');
        var it = this;
        try {
          while (rem > 0) {
            rem--;
            var step = it.next();
            if (step.done) return;
            yield step.value;
          }
          closeIter(it);
        } catch (e) {
          closeIter(it);
          throw e;
        }
      }));
      def(iterProto, 'drop', wrapGen(function* drop(limit) {
        var rem = Math.floor(Number(limit));
        if (Number.isNaN(rem) || rem < 0) throw new RangeError('Invalid drop limit');
        var it = this;
        try {
          while (rem > 0) {
            rem--;
            var skip = it.next();
            if (skip.done) return;
          }
          while (true) {
            var step = it.next();
            if (step.done) return;
            yield step.value;
          }
        } catch (e) {
          closeIter(it);
          throw e;
        }
      }));
      def(iterProto, 'flatMap', wrapGen(function* flatMap(mapper) {
        if (typeof mapper !== 'function') throw new TypeError('mapper must be a function');
        var i = 0;
        var it = this;
        try {
          while (true) {
            var step = it.next();
            if (step.done) return;
            var mapped = mapper(step.value, i++);
            if (mapped != null && typeof mapped[Symbol.iterator] === 'function') {
              yield* mapped;
            } else if (mapped != null && typeof mapped.next === 'function') {
              while (true) {
                var inner = mapped.next();
                if (inner.done) break;
                yield inner.value;
              }
            } else {
              throw new TypeError('Iterator.prototype.flatMap mapper must return an iterable or iterator');
            }
          }
        } catch (e) {
          closeIter(it);
          throw e;
        }
      }));
      def(iterProto, 'reduce', function reduce(reducer) {
        if (typeof reducer !== 'function') throw new TypeError('reducer must be a function');
        var hasInit = arguments.length >= 2;
        var acc = arguments[1];
        var i = 0;
        var it = this;
        if (!hasInit) {
          var first = it.next();
          if (first.done) throw new TypeError('Reduce of empty iterator with no initial value');
          acc = first.value;
          i = 1;
        }
        try {
          while (true) {
            var step = it.next();
            if (step.done) return acc;
            acc = reducer(acc, step.value, i++);
          }
        } catch (e) {
          closeIter(it);
          throw e;
        }
      });
      def(iterProto, 'toArray', function toArray() {
        var out = [];
        while (true) {
          var step = this.next();
          if (step.done) return out;
          out.push(step.value);
        }
      });
      def(iterProto, 'forEach', function forEach(fn) {
        if (typeof fn !== 'function') throw new TypeError('fn must be a function');
        var i = 0;
        try {
          while (true) {
            var step = this.next();
            if (step.done) return;
            fn(step.value, i++);
          }
        } catch (e) {
          closeIter(this);
          throw e;
        }
      });
      def(iterProto, 'some', function some(predicate) {
        if (typeof predicate !== 'function') throw new TypeError('predicate must be a function');
        var i = 0;
        try {
          while (true) {
            var step = this.next();
            if (step.done) return false;
            if (predicate(step.value, i++)) {
              closeIter(this);
              return true;
            }
          }
        } catch (e) {
          closeIter(this);
          throw e;
        }
      });
      def(iterProto, 'every', function every(predicate) {
        if (typeof predicate !== 'function') throw new TypeError('predicate must be a function');
        var i = 0;
        try {
          while (true) {
            var step = this.next();
            if (step.done) return true;
            if (!predicate(step.value, i++)) {
              closeIter(this);
              return false;
            }
          }
        } catch (e) {
          closeIter(this);
          throw e;
        }
      });
      def(iterProto, 'find', function find(predicate) {
        if (typeof predicate !== 'function') throw new TypeError('predicate must be a function');
        var i = 0;
        try {
          while (true) {
            var step = this.next();
            if (step.done) return undefined;
            if (predicate(step.value, i++)) {
              closeIter(this);
              return step.value;
            }
          }
        } catch (e) {
          closeIter(this);
          throw e;
        }
      });

      if (typeof g.Iterator !== 'function') {
        var IterCtor = function Iterator() {
          if (new.target === IterCtor || this instanceof IterCtor) {
            throw new TypeError('Abstract class Iterator not directly constructable');
          }
        };
        IterCtor.prototype = iterProto;
        def(g, 'Iterator', IterCtor);
      }
      if (g.Iterator) {
        def(g.Iterator, 'from', function from(O) {
          if (O == null) throw new TypeError('Iterator.from requires an object');
          if (typeof O[Symbol.iterator] === 'function') {
            var iter = O[Symbol.iterator]();
            if (iterProto.isPrototypeOf(iter)) return iter;
            O = iter;
          }
          if (typeof O.next === 'function') {
            if (iterProto.isPrototypeOf(O)) return O;
            var wrapper = Object.create(iterProto);
            wrapper.next = function(v) { return O.next(v); };
            wrapper.return = function(v) {
              return typeof O.return === 'function' ? O.return(v) : { value: v, done: true };
            };
            return wrapper;
          }
          throw new TypeError('Object is not iterable or an iterator');
        });
      }
    }
  } catch (_) {}

  // 10. Array.prototype immutable & search methods fallback
  var ap = Array.prototype;
  def(ap, 'at', function at(index) {
    var len = this.length >>> 0;
    var k = Math.trunc(Number(index) || 0);
    if (k < 0) k += len;
    return (k < 0 || k >= len) ? undefined : this[k];
  });
  def(String.prototype, 'at', function at(index) {
    var s = String(this);
    var len = s.length;
    var k = Math.trunc(Number(index) || 0);
    if (k < 0) k += len;
    return (k < 0 || k >= len) ? undefined : s.charAt(k);
  });
  def(ap, 'findLast', function findLast(pred, thisArg) {
    if (typeof pred !== 'function') throw new TypeError('predicate must be a function');
    for (var i = (this.length >>> 0) - 1; i >= 0; i--) {
      var val = this[i];
      if (pred.call(thisArg, val, i, this)) return val;
    }
    return undefined;
  });
  def(ap, 'findLastIndex', function findLastIndex(pred, thisArg) {
    if (typeof pred !== 'function') throw new TypeError('predicate must be a function');
    for (var i = (this.length >>> 0) - 1; i >= 0; i--) {
      if (pred.call(thisArg, this[i], i, this)) return i;
    }
    return -1;
  });
  def(ap, 'toReversed', function toReversed() {
    var len = this.length >>> 0;
    var out = new Array(len);
    for (var i = 0; i < len; i++) out[i] = this[len - 1 - i];
    return out;
  });
  def(ap, 'toSorted', function toSorted(compareFn) {
    if (compareFn !== undefined && typeof compareFn !== 'function') {
      throw new TypeError('Comparator must be a function');
    }
    var copy = Array.from(this);
    return compareFn ? copy.sort(compareFn) : copy.sort();
  });
  def(ap, 'toSpliced', function toSpliced(start, deleteCount) {
    var copy = Array.from(this);
    var args = Array.prototype.slice.call(arguments);
    Array.prototype.splice.apply(copy, args);
    return copy;
  });
  def(ap, 'with', function arrayWith(index, value) {
    var len = this.length >>> 0;
    var k = Math.trunc(Number(index) || 0);
    if (k < 0) k += len;
    if (k < 0 || k >= len) throw new RangeError('Invalid index');
    var copy = Array.from(this);
    copy[k] = value;
    return copy;
  });

  // 11. RegExp.escape & Error.isError
  def(RegExp, 'escape', function escape(str) {
    if (typeof str !== 'string') throw new TypeError('RegExp.escape requires a string');
    if (str.length === 0) return '';
    var out = '';
    for (var i = 0; i < str.length; i++) {
      var ch = str[i];
      var code = str.charCodeAt(i);
      if (i === 0 && ((code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122))) {
        out += '\\x' + code.toString(16).padStart(2, '0');
      } else if ('\\^$.*+?()[]{}|/'.indexOf(ch) !== -1) {
        out += '\\' + ch;
      } else if (ch === '-') {
        out += '\\x2d';
      } else if (ch === '\n') {
        out += '\\n';
      } else if (ch === '\r') {
        out += '\\r';
      } else if (ch === '\t') {
        out += '\\t';
      } else {
        out += ch;
      }
    }
    return out;
  });

  def(Error, 'isError', function isError(arg) {
    if (!arg || typeof arg !== 'object') return false;
    if (arg instanceof Error) return true;
    var tag = Object.prototype.toString.call(arg);
    return tag === '[object Error]' || tag === '[object DOMException]';
  });

  // 12. Uint8Array Base64 & Hex methods (ES2025/2026)
  if (typeof Uint8Array === 'function') {
    var b64Std = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var b64Url = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

    def(Uint8Array.prototype, 'toBase64', function toBase64(options) {
      if (!(this instanceof Uint8Array)) throw new TypeError('Expected Uint8Array');
      var opts = options || {};
      var alphabet = opts.alphabet === 'base64url' ? b64Url : b64Std;
      var omitPad = !!opts.omitPadding;
      var out = '';
      var len = this.length;
      for (var i = 0; i < len; i += 3) {
        var b0 = this[i];
        var has1 = (i + 1) < len;
        var has2 = (i + 2) < len;
        var b1 = has1 ? this[i + 1] : 0;
        var b2 = has2 ? this[i + 2] : 0;
        out += alphabet[b0 >> 2];
        out += alphabet[((b0 & 3) << 4) | (b1 >> 4)];
        if (has1) out += alphabet[((b1 & 15) << 2) | (b2 >> 6)];
        else if (!omitPad) out += '=';
        if (has2) out += alphabet[b2 & 63];
        else if (!omitPad) out += '=';
      }
      return out;
    });

    def(Uint8Array, 'fromBase64', function fromBase64(str, options) {
      if (typeof str !== 'string') throw new TypeError('Expected string');
      var opts = options || {};
      var isUrl = opts.alphabet === 'base64url';
      var clean = str.replace(/[\r\n\t ]+/g, '');
      if (isUrl) clean = clean.replace(/-/g, '+').replace(/_/g, '/');
      while (clean.length % 4 !== 0) clean += '=';
      var bin = g.atob(clean);
      var out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    });

    def(Uint8Array.prototype, 'toHex', function toHex() {
      if (!(this instanceof Uint8Array)) throw new TypeError('Expected Uint8Array');
      var out = '';
      for (var i = 0; i < this.length; i++) {
        out += (this[i] + 0x100).toString(16).slice(1);
      }
      return out;
    });

    def(Uint8Array, 'fromHex', function fromHex(str) {
      if (typeof str !== 'string') throw new TypeError('Expected string');
      if (str.length % 2 !== 0 || /[^0-9a-fA-F]/.test(str)) {
        throw new SyntaxError('Invalid hex string');
      }
      var out = new Uint8Array(str.length / 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = parseInt(str.slice(i * 2, i * 2 + 2), 16);
      }
      return out;
    });
  }
})();
"""#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    /// Event-driven input contrast guard running strictly in `.page` (main frame only) so WebKit
    /// never allocates a duplicate `.defaultClient` DOMWrapperWorld across large SPA DOM trees.
    static func inputContrastFixScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwContrastFixInstalled)return;
        window.__jwContrastFixInstalled=true;
        var SKIP_TYPES={hidden:1,checkbox:1,radio:1,button:1,submit:1,reset:1,image:1,file:1,range:1,color:1};
        var patched=new WeakMap();
        var patchedRefs=[];
        function isTextInput(el){
          if(!el||el.nodeType!==1)return false;
          var tag=el.tagName;
          if(tag==='TEXTAREA')return true;
          if(tag==='INPUT'){var t=(el.getAttribute('type')||'text').toLowerCase();return !SKIP_TYPES[t];}
          return false;
        }
        function parseColor(str){
          if(!str||typeof str!=='string')return null;
          str=str.trim().toLowerCase();
          if(str==='transparent')return{r:0,g:0,b:0,a:0};
          var m=str.match(/^rgba?\(([^)]+)\)$/);
          if(m){
            var body=m[1].trim();
            var alpha=1;
            var slash=body.split('/');
            if(slash.length===2){
              var aStr=slash[1].trim();
              alpha=aStr.endsWith('%')?parseFloat(aStr)/100:parseFloat(aStr);
              body=slash[0].trim();
            }
            var parts=body.indexOf(',')!==-1?body.split(','):body.split(/\s+/);
            if(parts.length<3)return null;
            var r=parseFloat(parts[0]),g=parseFloat(parts[1]),b=parseFloat(parts[2]);
            if(parts.length>=4&&slash.length===1){
              var a4=parts[3].trim();
              alpha=a4.endsWith('%')?parseFloat(a4)/100:parseFloat(a4);
            }
            if(isNaN(r)||isNaN(g)||isNaN(b)||isNaN(alpha))return null;
            return{r:Math.max(0,Math.min(255,r)),g:Math.max(0,Math.min(255,g)),b:Math.max(0,Math.min(255,b)),a:Math.max(0,Math.min(1,alpha))};
          }
          var srgb=str.match(/^color\(\s*srgb\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)(?:\s*\/\s*([\d.e+%-]+))?\s*\)$/);
          if(srgb){
            var a=1;
            if(srgb[4]!==undefined){a=srgb[4].endsWith('%')?parseFloat(srgb[4])/100:parseFloat(srgb[4]);}
            return{r:Math.max(0,Math.min(255,parseFloat(srgb[1])*255)),g:Math.max(0,Math.min(255,parseFloat(srgb[2])*255)),b:Math.max(0,Math.min(255,parseFloat(srgb[3])*255)),a:isNaN(a)?1:Math.max(0,Math.min(1,a))};
          }
          return null;
        }
        function compositeOver(fg,bg){
          var a=fg.a;
          return{r:fg.r*a+bg.r*(1-a),g:fg.g*a+bg.g*(1-a),b:fg.b*a+bg.b*(1-a),a:1};
        }
        function baseCanvasColor(){
          try{
            var isDark=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches;
            if(isDark&&document.documentElement){
              var cs=(getComputedStyle(document.documentElement).colorScheme||'').toLowerCase();
              if(cs.indexOf('dark')!==-1&&cs!=='only light')return{r:18,g:18,b:18,a:1};
            }
          }catch(_){}
          return{r:255,g:255,b:255,a:1};
        }
        function effectiveBackground(el){
          var layers=[],node=el,depth=0;
          while(node&&node.nodeType===1&&depth<32){
            var bg=parseColor(getComputedStyle(node).backgroundColor);
            if(bg&&bg.a>0.01){
              layers.push(bg);
              if(bg.a>=0.99)break;
            }
            var next=node.parentElement;
            if(!next&&node.getRootNode){var rn=node.getRootNode();if(rn&&rn.host)next=rn.host;}
            node=next;
            depth++;
          }
          var cur=(layers.length>0&&layers[layers.length-1].a>=0.99)?layers.pop():baseCanvasColor();
          for(var i=layers.length-1;i>=0;i--){cur=compositeOver(layers[i],cur);}
          return cur;
        }
        function luminance(c){
          function lin(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);}
          return 0.2126*lin(c.r)+0.7152*lin(c.g)+0.0722*lin(c.b);
        }
        function contrastRatio(c1,c2){
          var l1=luminance(c1),l2=luminance(c2);
          return(Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05);
        }
        function restoreOriginal(el){
          var orig=patched.get(el);
          if(!orig)return;
          if(orig.color)el.style.setProperty('color',orig.color,orig.colorPrio);
          else el.style.removeProperty('color');
          if(orig.fill)el.style.setProperty('-webkit-text-fill-color',orig.fill,orig.fillPrio);
          else el.style.removeProperty('-webkit-text-fill-color');
          if(orig.caret)el.style.setProperty('caret-color',orig.caret,orig.caretPrio);
          else el.style.removeProperty('caret-color');
        }
        function saveOriginal(el){
          if(patched.has(el))return;
          patched.set(el,{
            color:el.style.getPropertyValue('color'),
            colorPrio:el.style.getPropertyPriority('color'),
            fill:el.style.getPropertyValue('-webkit-text-fill-color'),
            fillPrio:el.style.getPropertyPriority('-webkit-text-fill-color'),
            caret:el.style.getPropertyValue('caret-color'),
            caretPrio:el.style.getPropertyPriority('caret-color')
          });
          if(patchedRefs.length<16&&patchedRefs.indexOf(el)===-1){
            patchedRefs.push(el);
          }
        }
        function checkAndFix(el){
          try{
            if(!isTextInput(el))return;
            var wasPatched=patched.has(el);
            if(wasPatched)restoreOriginal(el);
            var cs=getComputedStyle(el);
            if(!cs||cs.display==='none'||cs.visibility==='hidden'){if(wasPatched)patched.delete(el);return;}
            var op=parseFloat(cs.opacity);
            if(!isNaN(op)&&op<0.05){if(wasPatched)patched.delete(el);return;}
            var fs=parseFloat(cs.fontSize);
            if(!isNaN(fs)&&fs<1){if(wasPatched)patched.delete(el);return;}
            var rect=el.getBoundingClientRect();
            if(rect.width<=2||rect.height<=2){if(wasPatched)patched.delete(el);return;}
            var rawColor=parseColor(cs.color);
            var rawFill=parseColor(cs.getPropertyValue('-webkit-text-fill-color'));
            if((rawColor&&rawColor.a<0.05)||(rawFill&&rawFill.a<0.05)){if(wasPatched)patched.delete(el);return;}
            var selfBg=parseColor(cs.backgroundColor);
            if((!selfBg||selfBg.a<0.05)&&cs.backgroundImage&&cs.backgroundImage!=='none'){if(wasPatched)patched.delete(el);return;}
            var fg=rawFill||rawColor;
            if(!fg){if(wasPatched)patched.delete(el);return;}
            var bg=effectiveBackground(el);
            var effFg=(fg.a<0.99)?compositeOver(fg,bg):fg;
            var ratio=contrastRatio(effFg,bg);
            if(ratio<2.6){
              saveOriginal(el);
              var target=luminance(bg)>0.35?'#111827':'#f8fafc';
              el.style.setProperty('color',target,'important');
              el.style.setProperty('-webkit-text-fill-color',target,'important');
              el.style.setProperty('caret-color',target,'important');
            }else if(wasPatched){
              patched.delete(el);
            }
          }catch(_){}
        }
        function eventTarget(ev){
          if(ev&&typeof ev.composedPath==='function'){var p=ev.composedPath();if(p&&p.length)return p[0];}
          return ev?ev.target:null;
        }
        document.addEventListener('focusin',function(ev){
          var t=eventTarget(ev);
          if(!isTextInput(t))return;
          checkAndFix(t);
          requestAnimationFrame(function(){checkAndFix(t);});
        },true);
        document.addEventListener('input',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('change',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('blur',function(ev){
          var t=eventTarget(ev);
          if(isTextInput(t)&&patched.has(t)){checkAndFix(t);}
        },true);
        window.__jwRecheckInputs=function(){
          try{
            if(document.activeElement&&isTextInput(document.activeElement)){
              checkAndFix(document.activeElement);
            }
            for(var i=patchedRefs.length-1;i>=0;i--){
              var el=patchedRefs[i];
              if(!el||!el.isConnected){patchedRefs.splice(i,1);continue;}
              checkAndFix(el);
            }
          }catch(_){}
        };
        try{
          var mq=window.matchMedia('(prefers-color-scheme: dark)');
          if(mq&&mq.addEventListener)mq.addEventListener('change',function(){setTimeout(window.__jwRecheckInputs,60);});
        }catch(_){}
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .page
        )
    }

    static func diagnosticJSErrorScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwDiagInstalled)return;
        window.__jwDiagInstalled=true;
        var count=0;
        function post(kind,msg){
          if(count>=25)return;
          count++;
          try{
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.jwDiag){
              window.webkit.messageHandlers.jwDiag.postMessage({k:kind,m:String(msg||'')});
            }
          }catch(_){}
        }
        window.addEventListener('error',function(ev){
          var m=(ev&&ev.message?ev.message:'error')+(ev&&ev.filename?' @'+ev.filename+':'+(ev.lineno||0):'');
          post('error',m);
        });
        window.addEventListener('unhandledrejection',function(ev){
          var r=ev?ev.reason:null;
          var m=r?(r.message||String(r)):'unhandledrejection';
          post('promise',m);
        });
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// Zero-foreground-overhead background conversation monitor:
    /// - Attaches ZERO `MutationObserver`s and runs ZERO DOM layout queries during page load,
    ///   SPA hydration, scrolling, or foreground viewing (`isUserWatching() == true`).
    /// - Does NOT override `window.Notification` or `Element.prototype.attachShadow`, preserving
    ///   100% stock Safari / JetBrowser global API parity for Google / Lit / React SPAs.
    /// - Connects a bounded `MutationObserver` ONLY while the tab is in the background or unselected,
    ///   and disconnects it immediately upon returning to foreground.
    static func conversationMonitorScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwNotifyInstalled)return;
        window.__jwNotifyInstalled=true;

        var hostState={appActive:true,tabSelected:true};
        var lastComposerText='';
        var lastComposerInputAt=0;
        var lastUserSentAt=0;
        var lastBaselineTail='';
        var lastNotifiedSnippet='';
        var lastNotifiedAt=0;
        var lastStreamPingAt=0;
        var pendingReply=false;
        var streamStartedAt=0;
        var settleTimer=null;
        var dotScanTimer=null;
        var knownUnreadTitles=new Set();
        var lastTitleCount=0;
        var sharedMutObs=null;
        var obsConnected=false;
        var bgEnteredAt=0;

        function postNative(payload){
          try{
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.jwNotify){
              window.webkit.messageHandlers.jwNotify.postMessage(payload);
            }
          }catch(_){}
        }

        function isUserWatching(){
          return !!(hostState.appActive && hostState.tabSelected && document.visibilityState!=='hidden');
        }

        function normShortText(s){
          if(!s)return '';
          var clipped=s.length>420?s.slice(0,420):s;
          return clipped.replace(/\s+/g,' ').trim();
        }

        function safeLeafText(el,maxChildren){
          if(!el||el.nodeType!==1)return '';
          var lim=maxChildren||5;
          if(typeof el.childElementCount==='number'&&el.childElementCount>lim)return '';
          var raw=el.textContent;
          if(!raw||raw.length>1800)return '';
          return normShortText(raw);
        }

        function isTrivialStatusOrTime(t){
          if(!t||t.length<2)return true;
          if(/^(\d+\s*(s|sec|m|min|h|hr|d|秒|分钟|小时|天)(\s*ago|前)?|just now|刚刚|剛剛|\d{1,2}:\d{2}(\s*[ap]m)?)$/i.test(t))return true;
          if(/^(thinking|analyzing|generating|loading|working|running|searching|思考中|正在输入|加载中)[.…·\s]*$/i.test(t))return true;
          return false;
        }

        function isInsideIgnoredChrome(el){
          var cur=el,d=0;
          while(cur&&cur.nodeType===1&&d<14){
            var tag=cur.tagName;
            if(tag==='NAV'||tag==='ASIDE'||tag==='HEADER'||tag==='FOOTER'||tag==='SCRIPT'||tag==='STYLE'||tag==='SVG'||tag==='TEXTAREA'||tag==='INPUT'||tag==='BUTTON'){
              return true;
            }
            if(cur.isContentEditable)return true;
            var role=(cur.getAttribute('role')||'').toLowerCase();
            if(role==='navigation'||role==='textbox'||role==='combobox'||role==='dialog')return true;
            cur=cur.parentElement;
            d++;
          }
          return false;
        }

        function captureLatestChatSnippet(){
          try{
            if(!document.body)return '';
            var root=document.querySelector('main,[role="main"],[role="log"]')||document.body;
            var blocks=root.querySelectorAll('p,li,pre,blockquote,[data-message-author-role="assistant"] p,[class*="markdown" i] p,[class*="prose" i] p');
            var best='';
            for(var i=blocks.length-1;i>=Math.max(0,blocks.length-28);i--){
              var el=blocks[i];
              if(isInsideIgnoredChrome(el))continue;
              var txt=safeLeafText(el,6);
              if(txt.length>=4&&!isTrivialStatusOrTime(txt)&&txt!==lastComposerText){
                best=txt;
                break;
              }
            }
            if(best.length>120){
              best=best.slice(0,120)+'…';
            }
            return best;
          }catch(_){
            return '';
          }
        }

        function extractRowTitleForDot(dotEl){
          var cur=dotEl.parentElement,d=0;
          while(cur&&cur.nodeType===1&&cur!==document.body&&d<5){
            var raw=safeLeafText(cur,5);
            if(raw.length>=2&&raw.length<=95){
              raw=raw.replace(/\b\d+\s*(s|m|h|d|min|hr)\b$/i,'').trim();
              if(raw.length>=2&&!isTrivialStatusOrTime(raw))return raw;
            }
            cur=cur.parentElement;
            d++;
          }
          return '';
        }

        function scanUnreadDots(allowEmit){
          try{
            if(!document.body)return;
            var currentSet=new Set();
            var explicit=document.querySelectorAll('[aria-label*="unread" i],[data-unread="true"],[title*="未读"]');
            var lim=Math.min(explicit.length,40);
            for(var i=0;i<lim;i++){
              var rt=extractRowTitleForDot(explicit[i])||safeLeafText(explicit[i],4);
              if(rt.length>=2&&rt.length<=95)currentSet.add(rt);
            }
            if(allowEmit&&!isUserWatching()&&(Date.now()-bgEnteredAt)>1500){
              currentSet.forEach(function(title){
                if(!knownUnreadTitles.has(title)&&(Date.now()-lastNotifiedAt)>=6000){
                  lastNotifiedAt=Date.now();
                  postNative({
                    k:'unread_dot',
                    sub:'新对话动态',
                    body:'「'+title+'」有新回复待查看'
                  });
                }
              });
            }
            knownUnreadTitles=currentSet;
          }catch(_){}
        }

        function isBusyGenerating(){
          if(streamStartedAt>0&&(Date.now()-streamStartedAt)>600000)return false;
          try{
            if(!document.body)return false;
            var btns=document.querySelectorAll('button[aria-label*="stop" i],button[aria-label*="停止"],button[title*="stop" i],button[title*="停止"],[role="button"][aria-label*="stop" i]');
            for(var i=0;i<btns.length&&i<12;i++){
              if(!btns[i].disabled)return true;
            }
          }catch(_){}
          return false;
        }

        function checkReplySettled(){
          settleTimer=null;
          if(!pendingReply||isUserWatching()){
            pendingReply=false;
            streamStartedAt=0;
            return;
          }
          if(isBusyGenerating()){
            settleTimer=setTimeout(checkReplySettled,2200);
            return;
          }
          pendingReply=false;
          streamStartedAt=0;
          var snippet=captureLatestChatSnippet();
          if(!snippet||snippet===lastBaselineTail||snippet===lastNotifiedSnippet||snippet===lastComposerText){
            return;
          }
          if(Date.now()-lastNotifiedAt<6000)return;
          lastNotifiedAt=Date.now();
          lastNotifiedSnippet=snippet;
          lastBaselineTail=snippet;
          postNative({
            k:'reply_done',
            sub:'收到新回复',
            body:snippet
          });
        }

        function scheduleReplySettle(){
          if(isUserWatching())return;
          if(!pendingReply){
            pendingReply=true;
            streamStartedAt=Date.now();
          }
          if((Date.now()-lastStreamPingAt)>12000){
            lastStreamPingAt=Date.now();
            postNative({k:'streaming'});
          }
          if(settleTimer)clearTimeout(settleTimer);
          settleTimer=setTimeout(checkReplySettled,3200);
        }

        function checkTitleBadge(){
          var t=normShortText(document.title||'');
          var m=t.match(/^(?:\((\d+)\)|\[(\d+|新消息)\])\s*(.*)$/);
          if(!m){
            lastTitleCount=0;
            return;
          }
          var n=parseInt(m[1]||m[2]||'1',10);
          if(isNaN(n))n=1;
          if(n>lastTitleCount&&!isUserWatching()&&(Date.now()-lastNotifiedAt)>=6000){
            lastTitleCount=n;
            lastNotifiedAt=Date.now();
            postNative({
              k:'title_badge',
              sub:'有 '+n+' 条未读消息',
              body:m[3]||t
            });
          }else{
            lastTitleCount=n;
          }
        }

        function ensureBackgroundObserver(){
          if(isUserWatching()){
            if(obsConnected&&sharedMutObs){
              sharedMutObs.disconnect();
              obsConnected=false;
            }
            if(settleTimer){clearTimeout(settleTimer);settleTimer=null;}
            if(dotScanTimer){clearTimeout(dotScanTimer);dotScanTimer=null;}
            pendingReply=false;
            streamStartedAt=0;
            return;
          }
          if(obsConnected||!document.body)return;
          if(!sharedMutObs){
            sharedMutObs=new MutationObserver(function(mutations){
              if(isUserWatching()){
                ensureBackgroundObserver();
                return;
              }
              var hasMeaningfulText=false;
              var hasElementAdded=false;
              var lim=Math.min(mutations.length,60);
              for(var i=0;i<lim;i++){
                var m=mutations[i];
                if(m.target&&m.target.nodeName==='TITLE'){
                  checkTitleBadge();
                  continue;
                }
                if(m.type==='characterData'){
                  var p=m.target?m.target.parentElement:null;
                  if(p&&!isInsideIgnoredChrome(p)){
                    var t=normShortText(m.target.nodeValue||'');
                    if(t.length>=3&&!isTrivialStatusOrTime(t)){
                      hasMeaningfulText=true;
                      break;
                    }
                  }
                }else if(m.type==='childList'&&m.addedNodes&&m.addedNodes.length>0){
                  hasElementAdded=true;
                  if(!hasMeaningfulText&&m.target&&m.target.nodeType===1&&!isInsideIgnoredChrome(m.target)){
                    var nLim=Math.min(m.addedNodes.length,8);
                    for(var k=0;k<nLim;k++){
                      var nd=m.addedNodes[k];
                      var nt=(nd.nodeType===3)?normShortText(nd.nodeValue||''):safeLeafText(nd,5);
                      if(nt.length>=4&&!isTrivialStatusOrTime(nt)){
                        hasMeaningfulText=true;
                        break;
                      }
                    }
                  }
                }
              }
              if(hasMeaningfulText){
                scheduleReplySettle();
              }
              if(hasElementAdded&&!dotScanTimer){
                dotScanTimer=setTimeout(function(){
                  dotScanTimer=null;
                  if(!isUserWatching())scanUnreadDots(true);
                },3500);
              }
            });
          }
          try{
            sharedMutObs.observe(document.body,{childList:true,subtree:true,characterData:true});
            var titleEl=document.querySelector('head > title');
            if(titleEl)sharedMutObs.observe(titleEl,{childList:true,subtree:true,characterData:true});
            obsConnected=true;
          }catch(_){}
        }

        function emitUserSentIfNeeded(){
          var now=Date.now();
          if(now-lastUserSentAt<2500)return;
          lastUserSentAt=now;
          postNative({k:'user_sent'});
        }

        function getEventPath(ev){
          if(ev&&typeof ev.composedPath==='function'){
            var p=ev.composedPath();
            if(p&&p.length)return p;
          }
          var out=[],cur=ev?ev.target:null,d=0;
          while(cur&&d<10){out.push(cur);cur=cur.parentElement;d++;}
          return out;
        }

        function isEditableTarget(el){
          if(!el||el.nodeType!==1)return false;
          var tag=el.tagName;
          if(tag==='TEXTAREA'||tag==='INPUT'||el.isContentEditable)return true;
          var role=(el.getAttribute('role')||'').toLowerCase();
          return role==='textbox';
        }

        document.addEventListener('input',function(ev){
          var path=getEventPath(ev);
          var lim=Math.min(path.length,6);
          for(var i=0;i<lim;i++){
            var el=path[i];
            if(isEditableTarget(el)){
              var raw=(typeof el.value==='string')?el.value:(el.textContent||'');
              var v=normShortText(raw);
              lastComposerInputAt=Date.now();
              if(v.length>=2){
                lastComposerText=v.length>120?(v.slice(0,120)+'…'):v;
              }
              break;
            }
          }
        },{capture:true,passive:true});

        document.addEventListener('keydown',function(ev){
          if(!ev||ev.key!=='Enter'||ev.shiftKey||ev.isComposing)return;
          var path=getEventPath(ev);
          var lim=Math.min(path.length,6);
          for(var i=0;i<lim;i++){
            if(isEditableTarget(path[i])){
              emitUserSentIfNeeded();
              break;
            }
          }
        },{capture:true,passive:true});

        function checkButtonSendFromEvent(ev){
          var path=getEventPath(ev);
          var lim=Math.min(path.length,8);
          for(var i=0;i<lim;i++){
            var cur=path[i];
            if(!cur||cur.nodeType!==1)continue;
            if(cur.tagName==='BUTTON'||cur.getAttribute('role')==='button'){
              var tp=(cur.getAttribute('type')||'').toLowerCase();
              var lb=((cur.getAttribute('aria-label')||'')+' '+(cur.getAttribute('title')||'')+' '+(cur.getAttribute('data-testid')||'')+' '+safeLeafText(cur,3)).toLowerCase();
              if(tp==='submit'||/send|submit|发送|提交|ask|up-arrow|arrow_upward|north/.test(lb)){
                emitUserSentIfNeeded();
              }else if((Date.now()-lastComposerInputAt)<60000&&!/cancel|close|attach|upload|voice|mic|menu|sidebar|copy|stop|more|add|plus|取消|关闭|上传|菜单|复制|停止|更多/.test(lb)){
                emitUserSentIfNeeded();
              }
              break;
            }
          }
        }
        document.addEventListener('click',checkButtonSendFromEvent,{capture:true,passive:true});
        document.addEventListener('pointerup',checkButtonSendFromEvent,{capture:true,passive:true});

        window.__jwUpdateHostState=function(st){
          var wasWatching=isUserWatching();
          if(st&&typeof st.appActive==='boolean')hostState.appActive=st.appActive;
          if(st&&typeof st.tabSelected==='boolean')hostState.tabSelected=st.tabSelected;
          var nowWatching=isUserWatching();
          if(wasWatching&&!nowWatching){
            bgEnteredAt=Date.now();
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
            ensureBackgroundObserver();
            if(isBusyGenerating()||(Date.now()-lastUserSentAt)<180000){
              scheduleReplySettle();
            }
          }else if(!nowWatching&&!obsConnected&&document.body){
            bgEnteredAt=Date.now();
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
            ensureBackgroundObserver();
          }else if(nowWatching&&obsConnected){
            ensureBackgroundObserver();
          }
        };

        document.addEventListener('visibilitychange',function(){
          if(document.visibilityState==='hidden'){
            bgEnteredAt=Date.now();
            if(!pendingReply)lastBaselineTail=captureLatestChatSnippet();
            ensureBackgroundObserver();
          }else{
            ensureBackgroundObserver();
          }
        });
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// SPA-safe page-level JS retention cleanup invoked right before WebKit/JSC memory pressure GC.
    static func memoryReliefHelperScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwMemReliefInstalled)return;
        window.__jwMemReliefInstalled=true;
        window.__jwTrimPageMemory=function(opts){
          try{
            var o=opts||{};
            if(window.performance){
              if(typeof performance.clearResourceTimings==='function')performance.clearResourceTimings();
              if(o.aggressive){
                if(typeof performance.clearMarks==='function')performance.clearMarks();
                if(typeof performance.clearMeasures==='function')performance.clearMeasures();
              }
            }
            if(o.aggressive&&typeof console!=='undefined'&&console&&typeof console.clear==='function'){
              try{console.clear();}catch(_){}
            }
            if(o.hiddenTab&&window.getSelection){
              var ae=document.activeElement;
              var tag=ae&&ae.tagName?ae.tagName:'';
              var editing=!!(ae&&(tag==='INPUT'||tag==='TEXTAREA'||ae.isContentEditable));
              if(!editing){
                var sel=window.getSelection();
                if(sel&&sel.rangeCount>0&&sel.isCollapsed){sel.removeAllRanges();}
              }
            }
          }catch(_){}
        };
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}
