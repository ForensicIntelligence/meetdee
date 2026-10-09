import Foundation

/// Pure helpers that decide when two facts are "the same" (merge), when they
/// contradict (replace) and how well a fact answers a query (recall / forget).
public enum FactMerge {
    static let stopwords: Set<String> = [
        "a", "an", "the", "their", "they", "them", "is", "are", "was", "has", "have", "had", "named", "called",
        "of", "to", "and", "with", "for", "very", "really", "that", "this", "it", "be", "on", "s",
    ]

    /// Lower-cased content words, crudely singularised.
    public static func tokens(_ s: String) -> Set<String> {
        var out = Set<String>()
        for raw in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            if stopwords.contains(w) { continue }
            out.insert(stem(w))
        }
        return out
    }

    static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us") { return String(w.dropLast()) }
        return w
    }

    /// Words after which extra detail only refines a fact ("has a dog" → "has a
    /// dog named Rex", "works at Apple" → "works at Apple in Cupertino").
    static let refiners = Rx(#"\b(?:named|called|at|in|from|on|near|since|for)\b"#)

    /// Same idea in different words: Jaccard ≥ 0.8; or one fact is the other plus a
    /// refinement ("has a dog" ⊂ "has a dog named Rex"); or the smaller one is a
    /// subset with at least 3 content words. "likes dogs" vs "likes hot dogs" is
    /// NOT similar (the extra word changes the meaning).
    public static func similar(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return a.lowercased() == b.lowercased() }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        if Double(inter) / Double(union) >= 0.8 { return true }
        let (small, bigText, smallSet, bigSet) = ta.count <= tb.count ? (a, b, ta, tb) : (b, a, tb, ta)
        _ = small
        guard smallSet.isSubset(of: bigSet) else { return false }
        if smallSet.count >= 3 { return true }
        // The bigger fact must be "<smaller fact> named/at/in …".
        let lower = bigText.lowercased()
        guard let m = refiners.re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let r = Range(m.range, in: lower) else { return false }
        return tokens(String(lower[..<r.lowerBound])) == smallSet
    }

    /// Objects of "studies …" that are not a subject ("studies hard").
    static let notASubject = Rx(#"^studies (?:hard|a lot|lots|loads|every ?day|all day|all the time|at night|late|too much|a bit|sometimes|often|well|online|at home|alone|together)\b"#)

    static let positive = ["likes", "loves", "enjoys", "adores", "prefers", "is a fan of", "is into", "really likes", "really loves"]
    static let negative = ["dislikes", "hates", "doesn't like", "does not like", "can't stand", "cannot stand", "is not a fan of", "isn't a fan of", "is afraid of", "detests", "loathes", "doesn't enjoy", "really dislikes", "really hates"]

    /// "likes jazz" → ("jazz", true); "hates jazz" → ("jazz", false).
    public static func polarity(_ text: String) -> (object: String, positive: Bool)? {
        let l = text.lowercased()
        for (list, pos) in [(negative, false), (positive, true)] {
            for v in list where l.hasPrefix(v + " ") {
                let obj = normalisedObject(String(l.dropFirst(v.count + 1)))
                return obj.isEmpty ? nil : (obj, pos)
            }
        }
        return nil
    }

    static func normalisedObject(_ s: String) -> String {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !["a", "an", "the", "their", "some", "all", "kinds", "kind", "of", "types", "sorts"].contains($0) }
            .map(stem)
            .joined(separator: " ")
    }

    static let uniqueRelations = "wife|husband|partner|spouse|girlfriend|boyfriend|fianc[eé]e?|mother|mom|mum|mommy|mummy|father|dad|daddy|boss|stepmother|stepfather|stepmom|stepdad|mother-in-law|father-in-law"
    static let slotPatterns: [(Rx, String)] = [
        (Rx(#"^is \d+ years old$"#), "age"),
        (Rx(#"^was born in \d{4}$"#), "birthyear"),
        (Rx(#"^last name is "#), "lastname"),
        (Rx(#"^is called "#), "name"),
        (Rx(#"^birthday is "#), "birthday"),
        (Rx(#"^lives (?:in|near|on|outside|outside of|close to|just outside|by|next to) "#), "home"),
        (Rx(#"^is from "#), "origin"),
        (Rx(#"^grew up "#), "grewup"),
        (Rx(#"^works (?:at|for) "#), "employer"),
        (Rx(#"^studies "#), "studies"),
        (Rx(#"^is (?:married|engaged|divorced|single|widowed|separated|an? widow(?:er)?$)\b"#), "marital"),
    ]
    static let favouriteSlot = Rx(#"^favou?rite (.+?) (?:is|are) "#)
    static let uniqueRelSlot = Rx("^has an? (\(uniqueRelations)) named ")
    static let relBirthdaySlot = Rx(#"^their (.+?)'s birthday is "#)
    static let isARole = Rx(#"^is an? (.+)$"#)
    static let jobSlot = Rx(#"^(?:works as |is an? |is (?:retired|semi[- ]retired|unemployed|self[- ]employed|between jobs)\b)"#)

    /// Single-valued "slots": a new value replaces the old one (age, home, job…).
    public static func slot(_ text: String, category: Fact.Category) -> String? {
        let l = text.lowercased()
        if category == .birthday { return "birthday" }
        for (rx, key) in slotPatterns where rx.matches(l) {
            if key == "studies", notASubject.matches(l) { return nil }
            return key
        }
        if let g = favouriteSlot.groups(l), let thing = g[1] { return "fav:" + stem(thing) }
        if let g = uniqueRelSlot.groups(l), let rel = g[1] { return "rel:" + rel }
        if let g = relBirthdaySlot.groups(l), let rel = g[1] { return "relbday:" + rel }
        if category == .work, jobSlot.matches(l) {
            // "is a widower", "is an atheist" are not jobs, whatever the category says.
            if let g = isARole.groups(l), let raw = g[1] {
                let role = R.splitAt.groups(raw)?[1] ?? raw
                if !FactExtractor.isOccupation(role) && !FactExtractor.isOccupation(raw) { return nil }
            }
            return "job"
        }
        return nil
    }

    /// Relevance of `fact` to a free-text query: word overlap (with prefix and
    /// one-typo fuzziness) plus a bonus when the query names the fact's category.
    public static func score(_ fact: Fact, query: String) -> Double {
        let q = tokens(query)
        guard !q.isEmpty else { return 0 }
        let f = tokens(fact.text)
        var s = 0.0
        for w in q {
            if f.contains(w) { s += 1; continue }
            if f.contains(where: { fuzzy(w, $0) }) { s += 0.6 }
        }
        if let cats = categoryHints(q), cats.contains(fact.category) { s += 1 }
        return s
    }

    static func fuzzy(_ a: String, _ b: String) -> Bool {
        if a.count >= 4, b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if a.count >= 5, b.count >= 5, editDistance(a, b) <= 1 { return true }
        return false
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        if abs(x.count - y.count) > 1 { return 2 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    static func categoryHints(_ q: Set<String>) -> Set<Fact.Category>? {
        var out = Set<Fact.Category>()
        let map: [(Set<String>, [Fact.Category])] = [
            (["pet", "animal", "dog", "cat", "puppy", "kitten"], [.pet]),
            (["family", "kid", "child", "children", "wife", "husband", "partner", "son", "daughter", "parent", "mom", "mum", "dad", "brother", "sister", "sibling", "married", "friend", "relationship"], [.relationship]),
            (["job", "work", "career", "occupation", "school", "study", "profession", "employer"], [.work]),
            (["birthday", "born", "birth"], [.birthday]),
            (["health", "allergy", "allergie", "allergic", "medical", "diet", "food", "eat", "condition"], [.health]),
            (["like", "love", "favourite", "favorite", "preference", "hobby", "hobbie", "interest", "enjoy", "fun"], [.preference]),
            (["dislike", "hate", "afraid", "fear"], [.dislike]),
            (["live", "home", "from", "place", "city", "country", "where", "hometown"], [.place]),
            (["plan", "event", "upcoming", "schedule", "tomorrow", "week", "appointment", "exam", "trip"], [.event]),
            (["name", "age", "old", "who", "identity"], [.identity, .birthday]),
        ]
        for (words, cats) in map where !words.isDisjoint(with: q) { out.formUnion(cats) }
        return out.isEmpty ? nil : out
    }
}
