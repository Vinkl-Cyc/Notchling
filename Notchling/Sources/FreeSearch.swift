import Foundation

/// Free web search with no API key: DuckDuckGo results + DuckDuckGo Instant Answers + Wikipedia.
/// Every source is best-effort; if one fails the others still count.
struct SearchHit: Hashable {
    let title: String
    let snippet: String
    let url: URL
}

enum FreeSearch {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Notchling/1.1"

    /// Returns up to `limit` hits, best first, de-duplicated by URL.
    static func search(_ query: String, limit: Int = 6) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        async let instant = instantAnswer(q)
        async let web = duckDuckGo(q)
        async let wiki = wikipedia(q)
        let all = await instant + web + wiki

        var seen = Set<String>()
        var out: [SearchHit] = []
        for hit in all where !hit.snippet.isEmpty {
            let key = hit.url.absoluteString.lowercased()
            if seen.insert(key).inserted { out.append(hit) }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Sources

    private static func fetch(_ url: URL, timeout: TimeInterval = 8) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s
    }

    /// DuckDuckGo Instant Answer API (official, free). Great for definitions & quick facts.
    private static func instantAnswer(_ q: String) async -> [SearchHit] {
        guard let url = URL(string: "https://api.duckduckgo.com/?q=\(encode(q))&format=json&no_html=1&skip_disambig=1&t=notchling"),
              let data = await fetch(url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var hits: [SearchHit] = []
        let answer = json["Answer"] as? String ?? ""
        let abstract = json["AbstractText"] as? String ?? ""
        let heading = json["Heading"] as? String ?? q
        if let s = json["AbstractURL"] as? String, let u = URL(string: s), !abstract.isEmpty {
            hits.append(SearchHit(title: heading, snippet: abstract, url: u))
        }
        if !answer.isEmpty, let u = URL(string: "https://duckduckgo.com/?q=\(encode(q))") {
            hits.insert(SearchHit(title: "DuckDuckGo answer", snippet: answer, url: u), at: 0)
        }
        return hits
    }

    /// Regular web results from DuckDuckGo's lightweight HTML page.
    private static func duckDuckGo(_ q: String) async -> [SearchHit] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encode(q))"),
              let data = await fetch(url),
              let html = String(data: data, encoding: .utf8) else { return [] }

        let blocks = html.components(separatedBy: "class=\"result__body")
        var hits: [SearchHit] = []
        for block in blocks.dropFirst() {
            guard !block.contains("result--ad"), !block.contains("badge--ad"),
                  let href = firstMatch(#"class="result__a"[^>]*href="([^"]+)""#, in: block)
                            ?? firstMatch(#"href="([^"]+)"[^>]*class="result__a""#, in: block),
                  let titleHTML = firstMatch(#"class="result__a"[^>]*>(.*?)</a>"#, in: block),
                  let target = resolveDuckLink(href) else { continue }
            let snippetHTML = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block) ?? ""
            let title = cleanHTML(titleHTML)
            let snippet = cleanHTML(snippetHTML)
            guard !title.isEmpty else { continue }
            hits.append(SearchHit(title: title, snippet: snippet, url: target))
            if hits.count >= 5 { break }
        }
        return hits
    }

    /// Wikipedia search + page summary (free; asks for a descriptive User-Agent, which we send).
    private static func wikipedia(_ q: String) async -> [SearchHit] {
        guard let searchURL = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=1&format=json&srsearch=\(encode(q))"),
              let data = await fetch(searchURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = (json["query"] as? [String: Any])?["search"] as? [[String: Any]],
              let title = results.first?["title"] as? String else { return [] }
        let pathTitle = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? title
        guard let sumURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(pathTitle)"),
              let sData = await fetch(sumURL),
              let sum = (try? JSONSerialization.jsonObject(with: sData)) as? [String: Any],
              let extract = sum["extract"] as? String, !extract.isEmpty else { return [] }
        let page = ((sum["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        guard let u = URL(string: page ?? "https://en.wikipedia.org/wiki/\(pathTitle)") else { return [] }
        return [SearchHit(title: "Wikipedia: \(title)", snippet: extract, url: u)]
    }

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func resolveDuckLink(_ href: String) -> URL? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        let full = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        if let comps = URLComponents(string: full), full.contains("duckduckgo.com/l/"),
           let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: target)
        }
        if full.contains("duckduckgo.com/y.js") { return nil } // ad redirect
        return URL(string: full)
    }

    static func cleanHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<",
                        "&gt;": ">", "&nbsp;": " ", "&hellip;": "…", "&ndash;": "–", "&mdash;": "—"]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
