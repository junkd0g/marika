import Foundation
import MarikaCore

enum BrowserScripts {
    static let world = "MarikaBrowser"
    static let bootstrap = #"""
    (() => {
      window.__marikaRefs = new Map();
      window.__marikaAnnotating = false;
      let highlighted, previousOutline;
      function clear() {
        if (highlighted) highlighted.style.outline = previousOutline;
        highlighted = null;
      }
      function selector(el) {
        if (el.id) return '#' + CSS.escape(el.id);
        const parts = [];
        for (let node = el; node && node.nodeType === 1 && parts.length < 6; node = node.parentElement) {
          let part = node.tagName.toLowerCase();
          if (node.parentElement) {
            const siblings = [...node.parentElement.children].filter(e => e.tagName === node.tagName);
            if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
          }
          parts.unshift(part);
          if (node.tagName === 'BODY') break;
        }
        return parts.join(' > ');
      }
      document.addEventListener('mousemove', event => {
        if (!window.__marikaAnnotating) return;
        clear();
        highlighted = event.target;
        previousOutline = highlighted.style.outline;
        highlighted.style.outline = '2px solid #168bff';
      }, true);
      document.addEventListener('click', event => {
        if (!window.__marikaAnnotating) return;
        event.preventDefault(); event.stopImmediatePropagation();
        const el = event.target, rect = el.getBoundingClientRect();
        window.__marikaAnnotating = false;
        window.webkit.messageHandlers.marikaElement.postMessage({
          selector: selector(el), tag: el.tagName.toLowerCase(),
          text: (el.innerText || el.getAttribute('aria-label') || el.getAttribute('alt') || '').slice(0, 300),
          x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)
        });
      }, true);
      window.__marikaClearHighlight = clear;
    })();
    """#

    static let snapshot = #"""
    const refs = new Map(), elements = [];
    const visible = el => {
      const r = el.getBoundingClientRect(), style = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && r.bottom >= 0 && r.right >= 0 && r.top < innerHeight && r.left < innerWidth && style.visibility !== 'hidden' && style.display !== 'none';
    };
    for (const el of document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]')) {
      if (!visible(el) || elements.length >= 150) continue;
      const ref = 'e' + (elements.length + 1);
      refs.set(ref, el);
      elements.push({ref, tag:el.tagName.toLowerCase(), role:el.getAttribute('role'), type:el.getAttribute('type'),
        label:(el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.getAttribute('alt') || '').trim().slice(0,200),
        disabled:!!el.disabled});
    }
    window.__marikaRefs = refs;
    return {url:location.href,title:document.title,viewport:{width:innerWidth,height:innerHeight},
      text:(document.body?.innerText || '').slice(0,24000),elements};
    """#

    static func action(_ name: String, arguments: JSONValue) throws -> String {
        func quoted(_ key: String) throws -> String {
            guard let string = arguments[key]?.string else { throw BrowserError.message("Missing \(key).") }
            return String(decoding: try JSONValue.string(string).serialized(), as: UTF8.self)
        }
        switch name {
        case "browser_click":
            return "const el=window.__marikaRefs?.get(\(try quoted("ref"))); if(!el?.isConnected) throw new Error('Take a new snapshot to get a current element ref.'); el.scrollIntoView({block:'center'}); el.click(); return {clicked:true};"
        case "browser_fill":
            return """
            const el=window.__marikaRefs?.get(\(try quoted("ref")));
            if(!el?.isConnected) throw new Error('Take a new snapshot to get a current element ref.');
            if(!['INPUT','TEXTAREA'].includes(el.tagName) || ['password','file','hidden'].includes(el.type)) throw new Error('Use a normal text input; handle passwords and file uploads manually.');
            const proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto,'value').set.call(el,\(try quoted("text")));
            el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); return {filled:true};
            """
        case "browser_scroll":
            guard let pixels = arguments["pixels"]?.double, pixels.isFinite, abs(pixels) <= 100_000 else {
                throw BrowserError.message("Scroll by a finite number of pixels between -100000 and 100000.")
            }
            return "window.scrollBy(0,\(pixels)); return {scrolled:true};"
        default: throw BrowserError.message("Unknown browser action.")
        }
    }
}
