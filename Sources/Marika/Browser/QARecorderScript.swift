import Foundation
import MarikaCore

enum QARecorderScript {
    static let source = #"""
    (() => {
      const selector = el => {
        for (const attr of ['data-testid', 'id', 'name', 'aria-label']) {
          const value = el.getAttribute(attr);
          if (value) {
            const candidate = el.tagName.toLowerCase() + '[' + attr + '=' + JSON.stringify(value) + ']';
            if (document.querySelectorAll(candidate).length === 1) return candidate;
          }
        }
        const parts = [];
        for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
          let part = node.tagName.toLowerCase();
          if (node.parentElement) {
            const siblings = [...node.parentElement.children].filter(e => e.tagName === node.tagName);
            if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
          }
          parts.unshift(part);
          if (node.tagName === 'BODY') break;
        }
        return parts.join(' > ');
      };
      const sensitive = el => /password|secret|token|credit|card|cvv|cvc|otp/i.test(
        [el.type, el.name, el.id, el.autocomplete].join(' '));
      const send = (kind, el, value = '') => window.webkit.messageHandlers.marikaQA.postMessage({kind, selector:selector(el), value:String(value).slice(0,4000)});
      window.addEventListener('error', e => {
        const text = e.message || ('Resource failed: ' + (e.target?.tagName || 'unknown'));
        window.webkit.messageHandlers.marikaQADiagnostic.postMessage(String(text).slice(0,2000));
      }, true);
      window.addEventListener('unhandledrejection', () => window.webkit.messageHandlers.marikaQADiagnostic.postMessage('Unhandled promise rejection'));
      let listeners;
      window.__marikaSetQARecording = enabled => {
        listeners?.abort();
        listeners = undefined;
        if (!enabled) return;
        listeners = new AbortController();
        const options = {capture:true, signal:listeners.signal};
        document.addEventListener('click', e => {
          if (!e.isTrusted || window.__marikaAnnotating) return;
          const el = e.target.closest('button,a,[role="button"],input[type="submit"],input[type="button"]');
          if (el) send('click', el);
        }, options);
        document.addEventListener('input', e => {
          if (!e.isTrusted || !['INPUT','TEXTAREA'].includes(e.target.tagName)) return;
          const el = e.target;
          if (sensitive(el) || ['file','hidden'].includes(el.type)) { send('manual',el,'Enter protected input manually'); return; }
          if (!['checkbox','radio','submit','button'].includes(el.type)) send('fill',el,el.value);
        }, options);
        document.addEventListener('change', e => {
          if (!e.isTrusted) return;
          const el = e.target;
          if (el.tagName === 'SELECT') send('select',el,el.value);
          else if (['checkbox','radio'].includes(el.type)) send('check',el,String(el.checked));
        }, options);
        document.addEventListener('keydown', e => {
          if(e.isTrusted && e.key==='Enter' && e.target.tagName==='INPUT' && e.target.form) send('submit',e.target.form);
        }, options);
      };
    })();
    """#

}
