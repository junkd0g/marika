import Foundation

public enum QABrowserActions {
    public static func script(_ value: QAAction) throws -> String {
        func quote(_ string: String) throws -> String { String(decoding: try JSONValue.string(string).serialized(), as: UTF8.self) }
        let selector = try quote(value.selector), text = try quote(value.value)
        let operation: String
        switch value.kind {
        case .click: operation = """
            el.scrollIntoView({block:'center'});
            const box=el.getBoundingClientRect(), hit=document.elementFromPoint(box.x+box.width/2,box.y+box.height/2);
            if(!hit || !el.contains(hit)) return {ready:false,reason:'Element is covered by another element'};
            el.click();
            """
        case .fill:
            operation = """
            if (!['INPUT','TEXTAREA'].includes(el.tagName) || /password|secret|token|credit|card|cvv|cvc|otp/i.test([el.type,el.name,el.id,el.autocomplete].join(' ')) || ['file','hidden'].includes(el.type)) throw new Error('Protected or unsupported input requires manual testing.');
            if(el.readOnly) throw new Error('Input is read-only.');
            const proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto,'value').set.call(el,\(text));
            el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));
            """
        case .select: operation = """
            if(el.tagName!=='SELECT') throw new Error('Expected a select input.');
            const option=[...el.options].find(option=>option.value===\(text));
            if(!option || option.disabled || option.parentElement.disabled) throw new Error('Requested option is unavailable.');
            el.value=\(text); el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));
            if(el.value!==\(text)) throw new Error('The selection did not change to the requested value.');
            """
        case .check:
            guard ["true", "false"].contains(value.value) else { throw QAError("A checkbox or radio action needs true or false.") }
            operation = """
            if(!['checkbox','radio'].includes(el.type)) throw new Error('Expected a checkbox or radio.');
            if(el.type==='radio' && el.checked && \(text)==='false') throw new Error('A selected radio cannot be unchecked by clicking it.');
            if(el.checked!==\(value.value == "true")) el.click();
            if(el.checked!==\(value.value == "true")) throw new Error('The checked state did not change.');
            """
        case .submit: operation = "if(el.tagName!=='FORM') throw new Error('Expected a form.'); el.requestSubmit();"
        case .assertText: operation = "if(!(el.innerText || el.textContent || '').includes(\(text))) return {ready:false,reason:'Expected text was not found'};"
        case .assertVisible: operation = ""
        default: throw QAError("This step needs manual execution.")
        }
        return """
        const matches=document.querySelectorAll(\(selector));
        if(matches.length!==1) return {ready:false,reason:'Expected exactly one element; found '+matches.length};
        const el=matches[0], r=el.getBoundingClientRect(), s=getComputedStyle(el);
        if(r.width<=0 || r.height<=0 || s.visibility==='hidden' || s.display==='none') return {ready:false,reason:'Element is not visible'};
        \(value.isAssertion ? "" : "if(el.matches(':disabled') || el.closest('[inert]')) return {ready:false,reason:'Element is disabled'};")
        \(operation)
        return {ready:true};
        """
    }
}
