import Foundation

/// Cheap, deterministic fact extraction from one utterance (no LLM, no network).
///
/// Pipeline: normalise (curly quotes, contractions, lone "i"), split into clauses
/// (sentences, then "… and I …" / ", my …"), strip conversational filler ("hi Dee,",
/// "by the way", "remember that"), then try an ordered list of narrow rules; the
/// first rule that fires wins for that clause. Every fact is phrased in the third
/// person without a subject ("likes jazz", "has a cat named Miso") so it can be
/// prefixed with the person's name later. Precision is preferred over recall: a
/// missed fact is harmless, a wrong one ("is called Tired") is embarrassing.
public enum FactExtractor {
    /// Cheap, deterministic extraction from one utterance (no LLM).
    public static func extract(from utterance: String) -> [ExtractedFact] {
        extract(from: utterance, now: Date())
    }

    /// As above with an explicit clock, so relative dates ("tomorrow", "on Friday")
    /// resolve deterministically in tests.
    public static func extract(from utterance: String, now: Date, calendar: Calendar = .current) -> [ExtractedFact] {
        let text = normalise(utterance)
        guard !text.isEmpty else { return [] }
        // "I hate myself", "I want to die": never stored as a fact (see selfHarmSignal).
        if FactPolicy.selfHarm.matches(text) { return [] }
        let ctx = Ctx(now: now, calendar: calendar, intro: R.introContext.matches(text))
        var out: [ExtractedFact] = []
        // The last pet / relative mentioned without a name, so "I have a dog. His
        // name is Rex" names it.
        var unnamed: (index: Int, build: ([String]) -> ExtractedFact)?
        for raw in clauses(text) {
            var c = strip(raw)
            c = moveLeadingTime(c)
            guard c.count >= 3 else { continue }
            if let g = R.carryName.groups(c) {
                if let u = unnamed, let names = petNames(g[1] ?? g[2] ?? g[3], strict: false, person: false) {
                    out[u.index] = u.build(names)
                }
                unnamed = nil
                continue
            }
            var produced: [ExtractedFact]?
            if let r = deathRetraction(c) { produced = r }
            if produced == nil {
                for rule in rules {
                    if let facts = rule(c, ctx) { produced = facts; break }
                }
            }
            if produced == nil { produced = retraction(c, ctx) }
            var added: [ExtractedFact] = []
            for f in produced ?? [] where !FactPolicy.isDenied(f.text) && !out.contains(f) {
                out.append(f)
                added.append(f)
            }
            unnamed = nil
            if added.count == 1, let f = added.first, !f.retracts, !f.text.contains(" named ") {
                let index = out.count - 1
                if f.category == .pet, let g = R.havePet.groups(c), let animal = g[2] {
                    let count = g[1]
                    unnamed = (index, { petFact(count: count, animal: animal, names: $0) })
                } else if f.category == .relationship, let g = R.haveRel.groups(c), let rel = g[2], g[3] == nil {
                    let count = g[1]
                    unnamed = (index, { relFact(count: count, rel: rel, names: $0) })
                }
            }
        }
        return out
    }

    // MARK: - Retractions

    /// "My dog died", "my dog Rex passed away", "my mom passed away", "Rex died".
    static func deathRetraction(_ c: String) -> [ExtractedFact]? {
        if let g = R.petDied.groups(c), let animal = g[1] {
            let a = singularise(animal.lowercased())
            if let n = parseName(g[2], mode: .loose, person: false) {
                return [ExtractedFact(text: "has \(article(a)) \(a) named \(n)", category: .pet, retracts: true)]
            }
            return [ExtractedFact(text: "has \(article(a)) \(a)", category: .pet, retracts: true)]
        }
        if let g = R.relDied.groups(c), let rel = g[1] {
            let r = rel.lowercased()
            return [ExtractedFact(text: "has \(article(r)) \(r)", category: .relationship, retracts: true)]
        }
        if let g = R.nameDied.groups(c), let n = parseName(g[1], mode: .strict, person: false) {
            return [ExtractedFact(text: "named \(n)", category: .other, retracts: true)]
        }
        return nil
    }

    /// "I used to like jazz", "I no longer live in Toronto", "I don't have a dog
    /// (anymore)", "I'm not a doctor", "I had a dog named Rex", "I quit my job":
    /// the clause is rewritten positively, run through the rules, and whatever
    /// comes out is returned as a retraction (names and events excluded).
    static func retraction(_ c: String, _ ctx: Ctx) -> [ExtractedFact]? {
        if R.quitJob.matches(c) { return [ExtractedFact(text: "job", category: .work, retracts: true)] }
        for (rx, template) in R.retractRewrites {
            guard rx.matches(c) else { continue }
            let positive = rx.replace(c, with: template)
            for rule in rules {
                guard let facts = rule(positive, ctx) else { continue }
                let r = facts.filter { $0.name == nil && $0.category != .event && !$0.retracts }
                    .map { ExtractedFact(text: $0.text, category: $0.category, retracts: true) }
                return r.isEmpty ? nil : r
            }
            return nil
        }
        return nil
    }

    // MARK: - Context

    struct Ctx: Sendable {
        var now: Date
        var calendar: Calendar
        /// A greeting or "nice to meet you" appears: lowercase "i'm john" counts as a name.
        var intro: Bool
    }

    typealias Rule = @Sendable (String, Ctx) -> [ExtractedFact]?

    // MARK: - Normalisation

    static func normalise(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\"", with: "")
        t = R.loneI.replace(t, with: "I")
        // "Dr. Jones" must not end the sentence at "Dr".
        t = R.titleDot.replace(t, with: "$1")
        for (rx, rep) in R.contractions { t = rx.replace(t, with: rep) }
        t = R.spaces.replace(t, with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clauses(_ text: String) -> [String] {
        var parts: [String] = []
        for sentence in R.sentenceBreak.split(text) {
            for clause in R.clauseBreak.split(sentence) {
                parts.append(contentsOf: splitPossessions(clause))
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "I have a cat called Whiskers and a dog called Rex" → "I have a cat called
    /// Whiskers" + "I have a dog called Rex" (the subject and verb are carried).
    static func splitPossessions(_ clause: String) -> [String] {
        guard let g = R.possessionVerb.groups(clause), let verb = g[1] else { return [clause] }
        let pieces = R.possessionAnd.split(clause)
        guard pieces.count > 1 else { return [clause] }
        return [pieces[0]] + pieces.dropFirst().map { "\(verb) \($0.trimmingCharacters(in: .whitespaces))" }
    }

    static func strip(_ clause: String) -> String {
        var c = clause
        var previous = ""
        while previous != c {
            previous = c
            c = R.leadingFiller.replace(c, with: "")
            c = R.trailingFiller.replace(c, with: "")
            c = c.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:;-"))
        }
        return c
    }

    /// "Tomorrow I have an exam" → "I have an exam tomorrow".
    static func moveLeadingTime(_ c: String) -> String {
        guard let g = R.leadingTime.groups(c), let time = g[1], let rest = g[2] else { return c }
        return "\(rest) \(time)"
    }

    // MARK: - Rules (order matters: the first match wins for a clause)

    static let rules: [Rule] = [
        healthRule, petRule, relationshipRule, birthdayRule, ageRule, nameRule,
        favouriteRule, dislikeRule, likeRule, hobbyRule, workRule, placeRule,
        iAmARule, nationalityRule, eventRule,
    ]

    // Health: allergies, diets, conditions.
    static let healthRule: Rule = { c, _ in
        if let g = R.allergicTo.groups(c), let obj = cleanObject(g[1]) {
            return [fact("is allergic to \(obj)", .health)]
        }
        if let g = R.allergyNoun.groups(c) {
            if let obj = cleanObject(g[1]) { return [fact("is allergic to \(obj)", .health)] }
            if let obj = cleanObject(g[2]) { return [fact("has \(article(obj)) \(obj) allergy", .health)] }
        }
        if let g = R.diet.groups(c), let what = g[1] {
            return [fact("is \(what.lowercased())", .health)]
        }
        if let g = R.condition.groups(c), let what = g[2] {
            let w = what.lowercased()
            return [fact("has \(["adhd", "ptsd", "ocd"].contains(w) ? w.uppercased() : w)", .health)]
        }
        if let g = R.cannotEat.groups(c), let verb = g[1], let obj = cleanObject(g[2]) {
            let v = verb.lowercased()
            let phrase = v.hasPrefix("do") ? "doesn't eat" : v.hasPrefix("should") ? "shouldn't eat" : "can't eat"
            return [fact("\(phrase) \(obj)", .health)]
        }
        if let g = R.broke.groups(c), let part = g[1] {
            return [fact("broke their \(part.lowercased())", .health)]
        }
        if let g = R.wears.groups(c), let what = g[1] {
            return [fact("wears \(what.lowercased())", .health)]
        }
        return nil
    }

    // Pets with (or without) names.
    static let petRule: Rule = { c, _ in
        if let g = R.havePetNamed.groups(c), let animal = g[2], let names = petNames(g[3], strict: false, person: false) {
            return [petFact(count: g[1], animal: animal, names: names)]
        }
        if let g = R.myPetIsCalled.groups(c), let animal = g[1], let names = petNames(g[2], strict: false, person: false) {
            return [petFact(count: nil, animal: animal, names: names)]
        }
        if let g = R.myPetName.groups(c), let animal = g[1], let names = petNames(g[2], strict: true, person: false) {
            return [petFact(count: nil, animal: animal, names: names)]
        }
        if let g = R.nameIsMyPet.groups(c), let name = parseName(g[1], mode: .strict, person: false), let animal = g[2] {
            return [petFact(count: nil, animal: animal, names: [name])]
        }
        if let g = R.havePet.groups(c), let animal = g[2] {
            return [petFact(count: g[1], animal: animal, names: [])]
        }
        if R.noPets.matches(c) { return [fact("has no pets", .pet)] }
        return nil
    }

    // Family and other people in their life.
    static let relationshipRule: Rule = { c, _ in
        if let g = R.relBirthday.groups(c), let rel = g[1], let date = g[2], let when = birthdayText(date) {
            return [fact("their \(rel.lowercased())'s birthday is \(when)", .relationship)]
        }
        if let g = R.myRelIsCalled.groups(c), let rel = g[1], let names = petNames(g[2], strict: false) {
            return [relFact(count: nil, rel: rel, names: names)]
        }
        if let g = R.myRelName.groups(c), let rel = g[1], let names = petNames(g[2], strict: true) {
            return [relFact(count: nil, rel: rel, names: names)]
        }
        if let g = R.nameIsMyRel.groups(c), let name = parseName(g[1], mode: .strict), let rel = g[2] {
            return [relFact(count: nil, rel: rel, names: [name])]
        }
        if let g = R.relOther.groups(c), let rel = g[1], let rawRest = g[2], let rest = cleanObject(rawRest) {
            var r = rest
            if r.range(of: #"^(is|was) \d{1,3}$"#, options: .regularExpression) != nil { r += " years old" }
            return [fact("their \(rel.lowercased()) \(r)", .relationship)]
        }
        if let g = R.haveRel.groups(c), let rel = g[2] {
            let names = petNames(g[3], strict: false) ?? []
            return [relFact(count: g[1], rel: rel, names: names)]
        }
        if let g = R.widow.groups(c), let w = g[1] {
            return [fact("is a \(w.lowercased())", .relationship)]
        }
        if let g = R.marital.groups(c), let status = g[1] {
            var text = "is \(status.lowercased())"
            if let n = parseName(g[2], mode: .loose) { text += " to \(n)" }
            return [fact(text, .relationship)]
        }
        if let g = R.parentOf.groups(c), let role = g[1] {
            var text = "is \(article(role.lowercased())) \(role.lowercased())"
            if let of = cleanObject(g[2]) { text += " of \(of)" }
            return [fact(text, .relationship)]
        }
        if let g = R.noKids.groups(c), let what = g[1] {
            return [fact("has no \(what.lowercased())", .relationship)]
        }
        if R.onlyChild.matches(c) { return [fact("is an only child", .relationship)] }
        return nil
    }

    static let birthdayRule: Rule = { c, ctx in
        if let g = R.birthdayIsToday.groups(c), let when = g[1], let rel = resolveTime(when, ctx), let d = rel.date {
            return [fact("birthday is \(monthDay(d, ctx.calendar))", .birthday)]
        }
        if let g = R.myBirthday.groups(c), let date = g[1] {
            if let rel = resolveTime(date, ctx), let d = rel.date {
                return [fact("birthday is \(monthDay(d, ctx.calendar))", .birthday)]
            }
            if let when = birthdayText(date) { return [fact("birthday is \(when)", .birthday)] }
            return nil
        }
        if let g = R.bornOn.groups(c), let date = g[1], let when = birthdayText(date) {
            return [fact("birthday is \(when)", .birthday)]
        }
        if let g = R.bornInYear.groups(c), let year = g[1] {
            return [fact("was born in \(year)", .identity)]
        }
        if let g = R.bornInPlace.groups(c), let place = cleanObject(g[1]) {
            if let first = place.split(separator: " ").first, monthIndex(String(first)) != nil {
                return [fact("was born in \(capitalised(place))", .identity)]
            }
            return [fact("was born in \(place)", .place)]
        }
        return nil
    }

    static let ageRule: Rule = { c, _ in
        if let g = R.iAmAge.groups(c), let n = parseNumber(g[1]), (1...120).contains(n) {
            return [fact("is \(n) years old", .identity)]
        }
        if let g = R.turned.groups(c), let n = parseNumber(g[1]), (1...120).contains(n) {
            return [fact("is \(n) years old", .identity)]
        }
        return nil
    }

    // Self-introductions.
    static let nameRule: Rule = { c, ctx in
        if R.negatedName.matches(c) { return [] }
        if let g = R.spelledName.groups(c), let letters = g[1] {
            let joined = letters.filter(\.isLetter)
            guard joined.count >= 2 else { return [] }
            let name = capitalised(joined.lowercased())
            return [fact("is called \(name)", .identity, name: name)]
        }
        if let g = R.bondName.groups(c), let last = g[1], let first = g[2], g[3]?.lowercased() == last.lowercased(),
           let name = parseName("\(first) \(last)", mode: .loose) {
            return [fact("is called \(name)", .identity, name: name)]
        }
        if let g = R.myNameIs.groups(c), let name = parseName(g[1], mode: .loose) {
            return [fact("is called \(name)", .identity, name: name)]
        }
        if let g = R.callMe.groups(c), let name = parseName(g[1], mode: .loose) {
            return [fact("goes by \(name)", .identity, name: name)]
        }
        if let g = R.surname.groups(c), let name = parseName(g[1], mode: .loose) {
            return [fact("last name is \(name)", .identity)]
        }
        if let g = R.nickname.groups(c), let name = parseName(g[1], mode: .loose) {
            return [fact("goes by \(name)", .identity)]
        }
        if let g = R.iAmName.groups(c), let raw = g[1] {
            if let name = parseName(raw, mode: ctx.intro ? .intro : .strict) {
                var out = [fact("is called \(name)", .identity, name: name)]
                if let from = cleanObject(g[2]) { out.append(fact("is from \(from)", .place)) }
                return out
            }
            return nil
        }
        if let g = R.thisIsName.groups(c), g[1] != nil || g[3] != nil || ctx.intro, let name = parseName(g[2], mode: .strict) {
            return [fact("is called \(name)", .identity, name: name)]
        }
        if let g = R.nameHere.groups(c), let name = parseName(g[1], mode: .strict) {
            return [fact("is called \(name)", .identity, name: name)]
        }
        return nil
    }

    static let favouriteRule: Rule = { c, _ in
        if let g = R.myFavouriteIs.groups(c), let thing = g[1], let value = cleanObject(g[2]) {
            return [fact("favourite \(thing.lowercased()) is \(value)", .preference)]
        }
        if let g = R.isMyFavourite.groups(c), let value = cleanObject(g[1]) {
            if let thing = g[2], !thing.isEmpty { return [fact("favourite \(thing.lowercased()) is \(value)", .preference)] }
            return [fact("loves \(value)", .preference)]
        }
        return nil
    }

    static let dislikeRule: Rule = { c, _ in
        if let g = R.doNotLike.groups(c), let obj = cleanObject(g[1]) {
            return [fact("dislikes \(obj)", .dislike)]
        }
        if let g = R.hate.groups(c), let verb = g[1], let obj = cleanObject(g[2]) {
            let v = verb.lowercased()
            let phrase: String
            if v.hasPrefix("hate") { phrase = "hates" }
            else if v.contains("scared") || v.contains("afraid") || v.contains("terrified") || v == "fear" { phrase = "is afraid of" }
            else { phrase = "dislikes" }
            return [fact("\(phrase) \(obj)", .dislike)]
        }
        return nil
    }

    static let likeRule: Rule = { c, _ in
        guard let g = R.like.groups(c), let verb = g[1], let obj = cleanObject(g[2]) else { return nil }
        let v = verb.lowercased()
        let phrase: String
        if v.hasPrefix("lov") || v.hasPrefix("ador") || v.contains("obsessed") || v.contains("crazy") || v.contains("passionate") || v.contains("mad about") { phrase = "loves" }
        else if v.hasPrefix("enjoy") { phrase = "enjoys" }
        else if v.hasPrefix("prefer") { phrase = "prefers" }
        else { phrase = "likes" }
        return [fact("\(phrase) \(obj)", .preference)]
    }

    static let hobbyRule: Rule = { c, _ in
        if let g = R.play.groups(c), let verb = g[1], let obj = cleanObject(g[2]), !R.junkPlay.matches(obj) {
            return [fact("\(thirdPersonVerb(verb.lowercased())) \(obj)", .preference)]
        }
        if let g = R.hobbies.groups(c), let obj = cleanObject(g[1]) {
            if c.lowercased().hasPrefix("in my") { return [fact("likes to \(obj)", .preference)] }
            return [fact("enjoys \(obj)", .preference)]
        }
        return nil
    }

    static let workRule: Rule = { c, _ in
        if R.workFromHome.matches(c) { return [fact("works from home", .work)] }
        if let g = R.workAs.groups(c), let obj = cleanObject(g[1]) {
            return [fact("works as \(withArticle(obj))", .work)]
        }
        if let g = R.workAt.groups(c), let prep = g[1], let obj = cleanObject(g[2]) {
            return [fact("works \(prep.lowercased()) \(obj)", .work)]
        }
        if let g = R.myJobIs.groups(c), let obj = cleanObject(g[1]), isOccupation(obj) {
            return [fact("works as \(withArticle(obj))", .work)]
        }
        if let g = R.workStatus.groups(c), let status = g[1] {
            return [fact("is \(status.lowercased())", .work)]
        }
        if let g = R.study.groups(c), let obj = cleanObject(g[1]), !R.studyJunk.matches(obj) {
            var text = "studies \(obj)"
            if let at = cleanObject(g[2]) { text += " at \(at)" }
            return [fact(text, .work)]
        }
        if let g = R.goToSchool.groups(c), let obj = cleanObject(g[1]) {
            return [fact("goes to \(obj)", .work)]
        }
        if let g = R.grade.groups(c), let kind = g[1], let n = g[2] {
            return [fact("is in \(kind.lowercased()) \(n.lowercased())", .work)]
        }
        if let g = R.teach.groups(c), let obj = cleanObject(g[1]) {
            return [fact("teaches \(obj)", .work)]
        }
        if let g = R.ownBusiness.groups(c), let verb = g[1], let obj = cleanObject(g[2]) {
            return [fact("\(verb.lowercased() == "own" ? "owns" : "runs") \(withArticle(obj))", .work)]
        }
        return nil
    }

    static let placeRule: Rule = { c, _ in
        if let g = R.iAmFrom.groups(c), let obj = cleanPlace(g[1]) {
            return [fact("is from \(obj)", .place)]
        }
        if let g = R.liveIn.groups(c), let prep = g[1], let obj = cleanPlace(g[2]) {
            return [fact("lives \(prep.lowercased()) \(obj)", .place)]
        }
        if let g = R.grewUp.groups(c), let obj = cleanPlace(g[1]) {
            return [fact("grew up in \(obj)", .place)]
        }
        if let g = R.moved.groups(c), let dir = g[1], let obj = cleanPlace(g[2]) {
            let d = dir.lowercased()
            return [fact(d == "from" ? "moved from \(obj)" : "lives in \(obj)", .place)]
        }
        if let g = R.hometown.groups(c), let obj = cleanPlace(g[1]) {
            return [fact("is from \(obj)", .place)]
        }
        return nil
    }

    /// "I'm a nurse" (work), "I'm a big jazz fan" (preference), "I'm a tennis player".
    static let iAmARule: Rule = { c, _ in
        guard let g = R.iAmA.groups(c), let rawObj = g[1], let obj = cleanObject(rawObj) else { return nil }
        let words = obj.lowercased().split(separator: " ").map(String.init)
        guard let last = words.last, words.count <= 5 else { return nil }
        if Lex.notAThing.contains(words[0]) { return nil }
        if Lex.fanNouns.contains(last) {
            return [fact("is \(withArticle(obj))", .preference)]
        }
        if last == "player", words.count >= 2 {
            let sport = words.dropLast().filter { !Lex.intensifiers.contains($0) }.joined(separator: " ")
            return sport.isEmpty ? nil : [fact("plays \(sport)", .preference)]
        }
        if let at = R.splitAt.groups(obj), let role = at[1], isOccupation(role) {
            return [fact("is \(withArticle(obj))", .work)]
        }
        if isOccupation(obj) { return [fact("is \(withArticle(obj))", .work)] }
        return nil
    }

    static let nationalityRule: Rule = { c, ctx in
        guard let g = R.iAmWord.groups(c), let w = g[1] else { return nil }
        let lw = w.lowercased()
        if Lex.nationalities.contains(lw) || lw.hasSuffix("ese") && w.first?.isUppercase == true {
            return [fact("is \(capitalised(lw))", .place)]
        }
        if Lex.religions.contains(lw), !(ctx.intro && w.first?.isUppercase == true) {
            if ["atheist", "agnostic", "pagan"].contains(lw) { return [fact("is \(article(lw)) \(lw)", .other)] }
            if ["spiritual", "orthodox"].contains(lw) { return [fact("is \(lw)", .other)] }
            return [fact("is \(capitalised(lw))", .other)]
        }
        return nil
    }

    static let eventRule: Rule = { c, ctx in
        if let g = R.haveEvent.groups(c), let obj = cleanObject(g[1]), let timeRaw = g[2], let time = resolveTime(timeRaw, ctx) {
            if R.junkEventObject.matches(obj) { return nil }
            return [fact("has \(obj) \(time.text)", .event)]
        }
        if let g = R.doingEvent.groups(c), let verb = g[1], let timeRaw = g[2], let time = resolveTime(timeRaw, ctx) {
            let phrase = thirdPerson(verb)
            if R.junkGoing.matches(phrase) { return nil }
            return [fact("is \(phrase) \(time.text)", .event)]
        }
        if let g = R.myEventIs.groups(c), let thing = g[1], let timeRaw = g[2], let time = resolveTime(timeRaw, ctx) {
            let t = thing.lowercased()
            if Lex.relationWords.contains(t) || R.junkEventObject.matches(t) { return nil }
            return [fact("has \(withArticle(t)) \(time.text)", .event)]
        }
        return nil
    }

    // MARK: - Builders

    static func fact(_ text: String, _ category: Fact.Category, name: String? = nil) -> ExtractedFact {
        ExtractedFact(text: text, category: category, name: name)
    }

    static func petFact(count: String?, animal: String, names: [String]) -> ExtractedFact {
        let a = animal.lowercased()
        let n = count?.lowercased()
        let plural = names.count > 1 || (n != nil && !["a", "an", "one", "my"].contains(n!))
        let noun = plural ? pluralise(a) : singularise(a)
        var text: String
        if let n, plural, !["a", "an", "one", "my"].contains(n) {
            text = "has \(n) \(noun)"
        } else if plural {
            text = "has \(noun)"
        } else {
            text = "has \(article(noun)) \(noun)"
        }
        if !names.isEmpty { text += " named \(joinNames(names))" }
        return fact(text, .pet)
    }

    static func relFact(count: String?, rel: String, names: [String]) -> ExtractedFact {
        let r = rel.lowercased()
        let n = count?.lowercased()
        let pluralWord = Lex.pluralRelations.contains(r) || (r.hasSuffix("s") && !r.hasSuffix("ss") && r != "boss")
        var text: String
        if let n, !["a", "an", "one", "my"].contains(n) {
            text = "has \(n) \(pluralWord ? r : pluralise(r))"
        } else if pluralWord || names.count > 1 {
            text = "has \(pluralWord ? r : pluralise(r))"
        } else {
            text = "has \(article(r)) \(r)"
        }
        if !names.isEmpty { text += " named \(joinNames(names))" }
        return fact(text, .relationship)
    }

    static func joinNames(_ names: [String]) -> String {
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: - Names

    enum NameMode {
        /// "my name is …", "call me …": lowercase allowed.
        case loose
        /// Bare "I'm …": must be capitalised.
        case strict
        /// Bare "I'm …" after a greeting: lowercase single word allowed.
        case intro
    }

    /// `person`: the name is a human's (stricter: colours, moods, body words,
    /// sexuality, brands and joke names are rejected). Pet names may be "Pepper".
    static func parseName(_ raw: String?, mode: NameMode, person: Bool = true) -> String? {
        guard let raw else { return nil }
        var words = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        // "J O H N" (spelled out) → "John".
        if words.count >= 3, words.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) {
            words = [words.joined()]
            return capitalised(words[0].lowercased())
        }
        // "Dr Jones", "Mrs Patel": keep the title, but only with a real name after it.
        var title: String?
        if let f = words.first, let t = Lex.titles[f.lowercased()] {
            guard words.count >= 2, words[1].first?.isUppercase == true || mode == .loose else { return nil }
            title = t
            words.removeFirst()
        }
        guard let first = words.first else { return nil }
        let lowerFirst = first.lowercased()
        if Lex.nonNames.contains(lowerFirst) || Lex.nameStoppers.contains(lowerFirst) { return nil }
        if person, Lex.notPersonNames.contains(lowerFirst) { return nil }
        if Lex.nationalities.contains(lowerFirst) || Lex.religions.contains(lowerFirst) && mode == .strict { return nil }
        guard first.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }), first.first?.isLetter == true,
              !lowerFirst.hasSuffix("'s"), !lowerFirst.hasSuffix("'") else { return nil }
        let firstCapital = first.first?.isUppercase == true
        switch mode {
        case .strict:
            guard firstCapital else { return nil }
        case .intro:
            // Lower case after a greeting ("hi i'm priya"): only a known first name,
            // and only on its own ("hi i'm miles away" is not Miles).
            if !firstCapital {
                guard title == nil, words.count == 1, FirstNames.contains(lowerFirst) else { return nil }
            }
        case .loose:
            break
        }
        let allLower = raw == raw.lowercased()
        var kept = [first]
        for w in words.dropFirst() {
            let lw = w.lowercased()
            if kept.count >= 3 || Lex.nameStoppers.contains(lw) || Lex.nonNames.contains(lw) { break }
            if person, Lex.notPersonNames.contains(lw) { break }
            guard w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { break }
            if w.first?.isUppercase == true || (mode == .loose && allLower && kept.count < 2) {
                kept.append(w)
            } else {
                break
            }
        }
        if mode == .intro && !firstCapital && kept.count > 1 { kept = [first] }
        guard first.count >= 2 || firstCapital else { return nil }
        let name = kept.map(capitalised).joined(separator: " ")
        return title.map { "\($0) \(name)" } ?? name
    }

    static func petNames(_ raw: String?, strict: Bool, person: Bool = true) -> [String]? {
        guard let raw else { return nil }
        let pieces = R.nameListSplit.split(raw)
        var names: [String] = []
        for (i, p) in pieces.enumerated() {
            guard let n = parseName(p, mode: strict ? .strict : .loose, person: person) else {
                if i == 0 { return nil }
                break
            }
            names.append(n)
        }
        return names.isEmpty ? nil : names
    }

    static func capitalised(_ w: String) -> String {
        guard let f = w.first else { return w }
        return String(f).uppercased() + w.dropFirst()
    }

    // MARK: - Objects

    /// Trims filler, rejects bare pronouns and over-long captures, converts to third person.
    static func cleanObject(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        var previous = ""
        while previous != s {
            previous = s
            s = R.objectTail.replace(s, with: "")
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:-"))
        }
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        let acronym = s.count >= 2 && s.allSatisfy { $0.isUppercase }
        if Lex.pronounObjects.contains(lower), !acronym { return nil }
        let words = lower.split(separator: " ")
        if words.count > 8 { return nil }
        // About Dee, not about the person ("I like your eyes", "I hate when you do that").
        if words.contains(where: { $0 == "you" || $0 == "your" || $0 == "yours" }) { return nil }
        if let f = words.first, f == "when" || f == "how" || (f == "it" && words.count > 1 && words[1] == "when") { return nil }
        if let f = words.first, ["you", "it", "that", "this", "them", "him", "her"].contains(String(f)), words.count <= 2, !acronym { return nil }
        return thirdPerson(s)
    }

    static func cleanPlace(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = R.placeTail.replace(raw, with: "")
        return cleanObject(s)
    }

    static func thirdPerson(_ s: String) -> String {
        var t = s
        for (rx, rep) in R.thirdPerson { t = rx.replace(t, with: rep) }
        return t
    }

    static func thirdPersonVerb(_ v: String) -> String {
        if v.hasSuffix("s") || v.hasSuffix("sh") || v.hasSuffix("ch") || v.hasSuffix("x") || v.hasSuffix("o") { return v + "es" }
        if v.hasSuffix("y"), let p = v.dropLast().last, !"aeiou".contains(p) { return v.dropLast() + "ies" }
        return v + "s"
    }

    static func article(_ word: String) -> String {
        guard let f = word.lowercased().first else { return "a" }
        if word.lowercased().hasPrefix("uni") || word.lowercased().hasPrefix("one") || word.lowercased().hasPrefix("eu") { return "a" }
        if word.lowercased().hasPrefix("hour") || word.lowercased().hasPrefix("honest") { return "an" }
        return "aeiou".contains(f) ? "an" : "a"
    }

    /// Adds "a"/"an" unless the phrase already starts with a determiner or is plural/mass.
    static func withArticle(_ phrase: String) -> String {
        let lower = phrase.lowercased()
        let first = lower.split(separator: " ").first.map(String.init) ?? lower
        if Lex.determiners.contains(first) { return phrase }
        if lower.hasSuffix("s") && !lower.hasSuffix("ss") && !lower.hasSuffix("ics") { return phrase }
        return "\(article(phrase)) \(phrase)"
    }

    static func pluralise(_ w: String) -> String {
        if w.hasSuffix("s") || w == "fish" || w == "sheep" || w == "mice" || w == "children" || w == "goldfish" { return w }
        if w == "mouse" { return "mice" }
        if w == "child" { return "children" }
        if w.hasSuffix("y"), let p = w.dropLast().last, !"aeiou".contains(p) { return w.dropLast() + "ies" }
        if w.hasSuffix("sh") || w.hasSuffix("ch") || w.hasSuffix("x") { return w + "es" }
        return w + "s"
    }

    static func singularise(_ w: String) -> String {
        if w == "mice" { return "mouse" }
        if w.hasSuffix("ies"), w.count > 4 { return w.dropLast(3) + "y" }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { return String(w.dropLast()) }
        return w
    }

    static func isOccupation(_ phrase: String) -> Bool {
        let words = phrase.lowercased().split(separator: " ").map(String.init).filter { !Lex.intensifiers.contains($0) && !Lex.determiners.contains($0) }
        guard let last = words.last else { return false }
        let joined = words.joined(separator: " ")
        if Lex.occupations.contains(joined) || Lex.occupations.contains(last) { return true }
        if Lex.notOccupations.contains(last) || Lex.relationWords.contains(last) { return false }
        return Lex.occupationSuffixes.contains { last.hasSuffix($0) && last.count > $0.count + 2 }
    }

    static func parseNumber(_ raw: String?) -> Int? {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        if let n = Int(raw) { return n }
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init).filter { $0 != "and" }
        var total = 0
        for p in parts {
            if let v = Lex.units[p] { total += v }
            else if let v = Lex.tens[p] { total += v }
            else if p == "hundred" { total = max(total, 1) * 100 }
            else { return nil }
        }
        return parts.isEmpty ? nil : total
    }

    // MARK: - Dates

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static func monthIndex(_ s: String) -> Int? {
        let l = s.lowercased()
        if l == "sept" { return 9 }
        return monthNames.firstIndex { $0 == l || (l.count >= 3 && $0.hasPrefix(l)) }.map { $0 + 1 }
    }

    /// "March 3rd", "the 3rd of March", "3 March", "March the 3rd" → (3, 3).
    static func parseMonthDay(_ s: String) -> (month: Int, day: Int)? {
        if let g = R.dayOfMonth.groups(s), let d = g[1].flatMap({ Int($0) }), let m = g[2].flatMap(monthIndex), (1...31).contains(d) {
            return (m, d)
        }
        if let g = R.monthDay.groups(s), let m = g[1].flatMap(monthIndex), let d = g[2].flatMap({ Int($0) }), (1...31).contains(d) {
            return (m, d)
        }
        return nil
    }

    static func birthdayText(_ raw: String) -> String? {
        guard let md = parseMonthDay(raw) else { return nil }
        return "\(capitalised(monthNames[md.month - 1])) \(md.day)"
    }

    static func monthDay(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(capitalised(monthNames[(c.month ?? 1) - 1])) \(c.day ?? 1)"
    }

    struct ResolvedTime {
        var text: String
        var date: Date?
    }

    /// Turns a time phrase into fact text: "on Fri 9 Oct 2026", "the week of
    /// Mon 12 Oct 2026", "in November 2026". Weekday names mean the next such day
    /// after today ("on Friday" said on a Friday means a week later).
    static func resolveTime(_ raw: String, _ ctx: Ctx) -> ResolvedTime? {
        let p = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let cal = ctx.calendar
        let today = cal.startOfDay(for: ctx.now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today) ?? today }
        func onDay(_ d: Date) -> ResolvedTime { ResolvedTime(text: "on \(DateText.format(d, cal))", date: d) }

        if p.hasPrefix("today") || p.hasPrefix("tonight") || p.hasPrefix("this morning") || p.hasPrefix("this afternoon") || p.hasPrefix("this evening") {
            return onDay(today)
        }
        if p.contains("day after tomorrow") { return onDay(day(2)) }
        if p.hasPrefix("tomorrow") { return onDay(day(1)) }
        let weekdayIdx = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].firstIndex { p.contains($0) }
        if let w = weekdayIdx {
            let current = cal.component(.weekday, from: today) - 1
            var delta = (w - current + 7) % 7
            if delta == 0 { delta = 7 }
            return onDay(day(delta))
        }
        if p.contains("weekend") {
            let current = cal.component(.weekday, from: today) - 1 // 0 = Sunday
            var delta = (6 - current + 7) % 7
            if current == 0 { delta = -1 } // Sunday: this weekend began yesterday
            if p.hasPrefix("next") { delta += 7 }
            return onDay(day(max(delta, 0)))
        }
        if p == "this week" || p == "later this week" {
            return ResolvedTime(text: "the week of \(DateText.format(startOfWeek(today, cal), cal))", date: startOfWeek(today, cal))
        }
        if p == "next week" {
            let d = startOfWeek(day(7), cal)
            return ResolvedTime(text: "the week of \(DateText.format(d, cal))", date: d)
        }
        if p == "next month" {
            guard let d = cal.date(byAdding: .month, value: 1, to: today) else { return nil }
            return ResolvedTime(text: "in \(DateText.monthYear(d, cal))", date: d)
        }
        if let g = R.inN.groups(p), let n = parseNumber(g[1]) ?? (g[1] == "a" || g[1] == "an" ? 1 : g[1] == "a couple of" ? 2 : g[1] == "a few" ? 3 : nil), let unit = g[2] {
            let days = unit.hasPrefix("week") ? n * 7 : n
            return onDay(day(days))
        }
        if let md = parseMonthDay(p) {
            let year = cal.component(.year, from: today)
            var comps = DateComponents(year: year, month: md.month, day: md.day)
            guard var d = cal.date(from: comps) else { return nil }
            if d < day(-1) {
                comps.year = year + 1
                d = cal.date(from: comps) ?? d
            }
            return onDay(d)
        }
        return nil
    }

    static func startOfWeek(_ d: Date, _ cal: Calendar) -> Date {
        let weekday = cal.component(.weekday, from: d) // 1 = Sunday
        let back = (weekday + 5) % 7                  // days since Monday
        return cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: d)) ?? d
    }
}

/// Fixed, locale-independent date text used inside facts (and parsed back by the store).
enum DateText {
    static func formatter(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = format
        return f
    }

    static func format(_ d: Date, _ cal: Calendar) -> String { formatter("EEE d MMM yyyy", cal).string(from: d) }
    static func monthYear(_ d: Date, _ cal: Calendar) -> String { formatter("MMMM yyyy", cal).string(from: d) }

    /// Finds the first "Fri 9 Oct 2026" or "in November 2026" in a fact's text.
    static func date(in text: String, _ cal: Calendar) -> Date? {
        if let g = R.factDate.groups(text), let s = g[0] {
            return formatter("EEE d MMM yyyy", cal).date(from: s)
        }
        if let g = R.factMonth.groups(text), let s = g[1] {
            return formatter("MMMM yyyy", cal).date(from: s)
        }
        return nil
    }
}
