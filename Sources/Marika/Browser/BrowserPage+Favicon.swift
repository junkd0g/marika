import AppKit
@preconcurrency import WebKit

extension BrowserPage {
    func refreshFavicon() {
        guard let pageURL = url, ["http", "https"].contains(pageURL.scheme ?? "") else { return }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self else { return }
            let encoded: String? = try? await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(Self.faviconScript, arguments: [:], in: nil,
                                            in: .world(name: BrowserScripts.world)) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            guard !Task.isCancelled, url == pageURL, let encoded,
                  let data = Data(base64Encoded: encoded), data.count <= 262_144 else { return }
            favicon = NSImage(data: data)
        }
    }

    private static let faviconScript = """
    const links = [...document.querySelectorAll('link[rel~="icon"]')].map(link => link.href);
    links.push(new URL('/favicon.ico', location.href).href);
    for (const address of links) {
      const url = new URL(address, location.href);
      // Use the page's own session and origin, without contacting an icon service.
      if (url.origin !== location.origin && !url.href.startsWith('data:image/')) continue;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 4000);
      try {
        const response = await fetch(url.href, { credentials: 'same-origin', signal: controller.signal });
        if (!response.ok || Number(response.headers.get('content-length')) > 262144) continue;
        const reader = response.body.getReader();
        let length = 0, chunks = [];
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.length;
          if (length > 262144) { await reader.cancel(); throw new Error('Icon too large'); }
          chunks.push(value);
        }
        let binary = '';
        for (const chunk of chunks) for (const byte of chunk) binary += String.fromCharCode(byte);
        if (binary) return btoa(binary);
      } catch (_) {} finally { clearTimeout(timeout); }
    }
    return null;
    """
}
