import Foundation

/// Which facts are too personal to put into the system prompt. Sensitive facts
/// are still stored and returned by `recall`/`search` (the person can ask "what
/// do you know about me?"), but `promptMemories` never lists them, so Dee will
/// not bring up "John has depression" when other people are in the room.
public enum FactSensitivity {
    /// Health facts that are harmless (and useful) to mention: allergies, diets,
    /// glasses. Every other health fact is sensitive.
    static let benignHealth = Rx(#"^(?:is allergic to|has an? .+ allerg(?:y|ies)|is (?:vegetarian|vegan|pescatarian|gluten[- ]free|lactose[- ]intolerant|teetotal)$|can't eat|cannot eat|doesn't eat|shouldn't eat|wears (?:glasses|contacts|contact lenses|braces))"#)

    static let sensitiveWords = Rx(#"\b(?:christian|catholic|protestant|jewish|jew|muslim|islam|islamic|buddhist|hindu|sikh|atheist|agnostic|mormon|baptist|methodist|lutheran|anglican|evangelical|pagan|religio\w*|church|mosque|synagogue|temple|pray\w*|god|gay|lesbian|bisexual|bi|queer|trans|transgender|nonbinary|non-binary|asexual|pansexual|straight|sexuality|sexual|sex|coming out|came out|pregnan\w*|miscarriage|abortion|ivf|fertility|depress\w*|anxiety|bipolar|schizophreni\w*|ptsd|ocd|adhd|autis\w*|eating disorder|anorexi\w*|bulimi\w*|suicid\w*|self[- ]harm|therapy|psychiatrist|medication|meds|antidepressant\w*|rehab|addict\w*|alcoholic|sober|recovery|cancer|hiv|aids|std|diagnos\w*|disabilit\w*|disabled|wheelchair|chemo\w*|surgery|democrat\w*|republican\w*|conservative|liberal|labour|tory|communist|socialist|maga|trump|biden|politic\w*|vote[sd]?|voting|immigra\w*|undocumented|visa|asylum|refugee|arrest\w*|prison|jail|criminal|probation|parole|debt|bankrupt\w*|divorc\w*|affair|salary|income)\b"#)

    public static func isSensitive(_ text: String, category: Fact.Category) -> Bool {
        let l = text.lowercased()
        if category == .health { return !benignHealth.matches(l) }
        // "works as a therapist", "works at Visa": jobs are not disclosures.
        if category == .work { return false }
        return sensitiveWords.matches(l)
    }
}

/// Things Dee must never store as a "fact", whoever says them.
public enum FactPolicy {
    /// Hateful / violent / drug / self-referential objects. Matched as whole words
    /// against the extracted fact text.
    static let denied = Rx(#"\b(?:jews|the jews|jewish people|muslims|christians|catholics|hindus|sikhs|buddhists|atheists|mormons|arabs|blacks|black people|whites|white people|asians|asian people|mexicans|immigrants|refugees|foreigners|gays|gay people|lesbians|queers|trans people|transgender people|homosexuals|cocaine|crack cocaine|heroin|meth|methamphetamine|crystal meth|fentanyl|opioids|opium|oxycontin|ketamine|mdma|ecstasy|lsd|shrooms|weed|marijuana|cannabis|drugs|drug|drug dealer|dealing drugs|kill|kills|killing|killed|murder(?!\s+myster)\w*|rape|raped|rapes|raping|rapist|stab|stabs|stabbed|stabbing|shoot (?:him|her|them|someone|somebody|people|everyone|everybody|their|my|his)|shooting (?:him|her|them|someone|somebody|people|everyone|everybody|their|my|his)|torture\w*|bomb|bombs|bombing|bomber|massacre|genocide|terror\w*|strangl\w*|(?:hurt|hurting|hit|hitting|punch|punching|beat|beating|beat up|attack|attacking|poison|poisoning|choke|choking) (?:him|her|them|someone|somebody|people|everyone|everybody|their (?!stride\b)\w+|my \w+|his \w+|you)|myself|themselves|himself|herself|yourself|ourselves)\b"#)

    /// Statements that suggest self-harm or a crisis. They are never stored as a
    /// preference ("hates themselves"); the app should route them to its
    /// wellbeing handling instead (`FactExtractor.selfHarmSignal(in:)`).
    static let selfHarm = Rx(#"\b(?:(?:hate|loathe|despise|hurt|harm|cut|kill|starve) (?:myself|themselves|meself)|(?:want|wanna|going) to die|wish I (?:was|were) dead|wish I (?:was|were) never born|better off dead|end (?:it all|my life)|take my (?:own )?life|suicid\w*|self[- ]harm\w*|no reason to live|do not want to (?:live|be alive|be here anymore)|can ?not go on|kill me)\b"#)

    /// True when `text` (an extracted fact) must not be stored.
    public static func isDenied(_ text: String) -> Bool {
        denied.matches(text.lowercased())
    }
}

public extension FactExtractor {
    /// True for utterances such as "I hate myself" or "I want to die". Nothing
    /// from such an utterance is stored; the app should respond with care.
    static func selfHarmSignal(in utterance: String) -> Bool {
        FactPolicy.selfHarm.matches(normalise(utterance))
    }
}
