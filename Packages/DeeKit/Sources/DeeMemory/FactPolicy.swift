import Foundation

/// Which facts are too personal to put into the system prompt. Sensitive facts
/// are still stored and returned by `recall`/`search` (the person can ask "what
/// do you know about me?"), but `promptMemories` never lists them, so Dee will
/// not bring up "John has depression" when other people are in the room.
///
/// The category is NOT trusted on its own: "is a sex worker" extracted as a job,
/// or `remember("has a court date…", category: .work)`, is still sensitive.
public enum FactSensitivity {
    /// Health facts that are harmless (and useful) to mention: allergies, diets,
    /// glasses. Every other health fact is sensitive.
    static let benignHealth = Rx(#"^(?:is allergic to|has an? .+ allerg(?:y|ies)|is (?:vegetarian|vegan|pescatarian|gluten[- ]free|lactose[- ]intolerant|teetotal)$|can't eat|cannot eat|doesn't eat|shouldn't eat|wears (?:glasses|contacts|contact lenses|braces))"#)

    /// Sensitive whatever the category (work included) and whatever the wording
    /// around it: religion and religious practice, sexuality, sex work and the
    /// sex industry, drugs and drug use, gambling, addiction and recovery,
    /// personal legal trouble, body weight, reproductive health. A few common
    /// non-sensitive uses are excluded ("Christian rock", "a son named
    /// Christian", "AA batteries", "Trans-Am", "Sex Pistols").
    static let alwaysSensitive = Rx(#"\b(?:(?<!named )(?<!called )(?<!to )(?<!and )christian(?!\s+(?:rock|music|metal|pop|band|bands|songs?|radio|bale|dior|louboutin|slater)\b)|catholic|protestant|presbyterian|jewish|jew|muslim|islam|islamic|buddhist|hindu|sikh|atheist|agnostic|mormon|baptist|methodist|lutheran|anglican|evangelical|pentecostal|episcopalian|adventist|jehovah'?s? witness\w*|quaker|amish|rastafarian|rasta|wiccan|witch|pagan|scientolog\w*|shia|shiite|sunni|religio\w*|(?:goes|go|went|going) to (?:mass|church|confession|bible study|sunday school|mosque|synagogue|temple|shul|gurdwara|mandir|services|prayers?)|ramadan|kosher|halal|sabbath|shabbat|bible|quran|koran|torah|gay|lesbian|bisexual|bi(?!-)|queer|trans(?![-\s]+(?:am|ams|fats?|siberian|atlantic|pacific|canada|alpine)\b)|transgender|nonbinary|non-binary|asexual|pansexual|homosexual|heterosexual|sexuality|sex(?!\s+(?:pistols|and the city|education|ed)\b)|sexual|sex work\w*|escort|stripper|strip ?club\w*|strip joint|gentlemen'?s club|brothel|massage parlou?r|prostitut\w*|porn\w*|onlyfans|cam ?girl|celibate|polyamor\w*|kink\w*|fetish\w*|bdsm|stoner|weed|cannabis|marijuana|drug|drugs|cocaine|heroin|meth|(?:does|do|doing|did|takes|take|took|taking|snorts?|snorting|smokes?|smoking|uses|using|is on|was on|on) (?:coke|cocaine|crack|meth|molly|mdma|ecstasy|acid|lsd|shrooms|magic mushrooms|ketamine|heroin|smack|pills|drugs|pot|dope|blow|speed|oxy|oxys|percs|xans)|gambl\w*|casino|betting|bookie|addict\w*|alcoholic|alcoholism|rehab|sober|sobriety|aa(?!\s+(?:batter(?:y|ies)|cells?)\b)|na|alcoholics anonymous|narcotics anonymous|gamblers anonymous|(?:twelve|12)[- ]step|court (?:date|case|hearing|appearance|order)|in court|on trial|lawsuit|sued|being sued|custody (?:battle|hearing|case)|restraining order|probation|parole|arrest\w*|criminal record|convicted|conviction|felon\w*|deport\w*|bail|obese|obesity|overweight|underweight|morbidly|pregnan\w*|miscarriage|abortion|ivf|infertil\w*|hiv|aids|std|sti|herpes)\b"#)

    /// Personal disclosures, sensitive in EVERY category (a job fact included):
    /// mental and physical health, medication, sexuality talk, politics and
    /// voting, immigration status, money trouble and pay, divorce and affairs,
    /// homelessness.
    static let personalWords = Rx(#"\b(?:pray\w*|god|straight|coming out|came out|depress\w*|anxiety|panic attacks?|bipolar|schizophreni\w*|ptsd|ocd|adhd|autis\w*|eating disorder|anorexi\w*|bulimi\w*|suicid\w*|self[- ]harm|antidepressant\w*|anti-depressant\w*|meds|prozac|zoloft|lexapro|celexa|paxil|effexor|cymbalta|wellbutrin|xanax|valium|klonopin|ativan|adderall|ritalin|vyvanse|concerta|lithium|seroquel|abilify|risperdal|zyprexa|lamictal|sertraline|fluoxetine|citalopram|escitalopram|paroxetine|venlafaxine|duloxetine|bupropion|quetiapine|aripiprazole|olanzapine|risperidone|lamotrigine|diazepam|lorazepam|alprazolam|clonazepam|methadone|suboxone|naltrexone|insulin|metformin|ozempic|wegovy|miscarr\w*|democrat\w*|republican\w*|gop|conservative|liberal|labour|tory|tories|ndp|communist|socialist|maga|trump|biden|left[- ]wing|right[- ]wing|leftist|politic\w*|vote[sd]?|voting|immigra\w*|undocumented|illegal(?:ly)? (?:immigrant|alien|here|in the country)|green card|work permit|asylum|refugee|no papers|overstay\w*|visa (?:status|expir\w*|ran out|issues?|problems?)|debts?|in the red|owes?|owing|bankrupt\w*|foreclos\w*|evict\w*|payday loans?|credit score|is broke|salary|income|earns?|earning|makes (?:\$|£|€)?\d|\d+ ?k (?:a|per) (?:year|month)|paid (?:\$|£|€)?\d|divorc\w*|affair|cheat(?:ed|ing) on|separated|homeless\w*|on benefits|on welfare|food bank)\b"#)

    /// Sensitive except in a job fact ("works at Visa", "works as a therapist",
    /// "works in cancer research", "is a lawyer" are jobs, not disclosures):
    /// illnesses, institutions, professions that imply a personal matter.
    static let placeWords = Rx(#"\b(?:chemo\w*|radiotherapy|dialysis|cancer|tumou?rs?|leuka?emia|lymphoma|diabetes|epilep\w*|seizures?|dementia|alzheimer'?s?|parkinson'?s?|multiple sclerosis|crohn'?s|lupus|hepatitis|cirrhosis|stroke|heart attack|heart condition|heart disease|terminal(?:ly)? ill\w*|chronic illness|disabilit\w*|disabled|diagnos\w*|church|mosque|synagogue|temple|therapy|therapist|psychiatr\w*|psycholog\w*|counsell?(?:ing|or)|medication|recovery|surgery|wheelchair|hospital|prison|jail|criminal|court|lawyer|attorney|visa|politic\w*|immigration)\b"#)

    /// A job / study fact: "works at …", "works as …", "is a nurse", "studies law".
    static let jobContext = Rx(#"^(?:works (?:at|for|in|as|with|on)|worked (?:at|for|in|as)|is (?:a|an|the) |studies|teaches|is in (?:grade|year|form)|owns|runs|goes to (?:school|university|college|uni|the university)\b)"#)

    public static func isSensitive(_ text: String, category: Fact.Category) -> Bool {
        let l = text.lowercased()
        if alwaysSensitive.matches(l) || personalWords.matches(l) { return true }
        if category == .health { return !benignHealth.matches(l) }
        if category == .work, jobContext.matches(l) { return false }
        return placeWords.matches(l)
    }
}

/// Things Dee must never store as a "fact", whoever says them.
public enum FactPolicy {
    /// Hateful / violent / drug / self-referential objects. Matched as whole words
    /// against the extracted fact text.
    static let denied = Rx(#"\b(?:jews|the jews|jewish people|muslims|christians|catholics|hindus|sikhs|buddhists|atheists|mormons|arabs|blacks|black people|whites|white people|asians|asian people|mexicans|immigrants|refugees|foreigners|gays|gay people|lesbians|queers|trans people|transgender people|homosexuals|brown people|cocaine|crack cocaine|heroin|meth|methamphetamine|crystal meth|fentanyl|opioids|opium|oxycontin|ketamine|mdma|ecstasy|lsd|shrooms|weed|marijuana|cannabis|drugs|drug|drug dealer|dealing drugs|kill|kills|killing|killed|murder(?!\s+myster)\w*|rape|raped|rapes|raping|rapist|stab|stabs|stabbed|stabbing|shoot (?:him|her|them|someone|somebody|people|everyone|everybody|their|my|his)|shooting (?:him|her|them|someone|somebody|people|everyone|everybody|their|my|his)|torture\w*|bomb|bombs|bombing|bomber|massacre|genocide|terror\w*|strangl\w*|(?:hurt|hurting|hit|hitting|punch|punching|beat|beating|beat up|attack|attacking|poison|poisoning|choke|choking) (?:him|her|them|someone|somebody|people|everyone|everybody|their (?!stride\b)\w+|my \w+|his \w+|you)|myself|themselves|himself|herself|yourself|ourselves)\b"#)

    /// The most common English slurs (any context).
    static let slurs = Rx(#"\b(?:nigg(?:er|ers|a|as|az|ah)|fag|fags|faggot\w*|dyke|dykes|trann(?:y|ies)|shemales?|retard|retards|retarded|spic|spics|spick|chink|chinks|kike|kikes|wetback\w*|gook|gooks|raghead\w*|towelhead\w*|paki|pakis|beaner\w*|sand ?nigg\w*|camel ?jockey\w*|jungle ?bunn(?:y|ies)|wog|wogs|gypo|gyppo|pikey|pikeys|kaffir\w*|zipperhead\w*|cripple|cripples|mongoloid\w*)\b"#)

    /// Extremist figures, groups and texts (any context).
    static let extremists = Rx(#"\b(?:hitler|adolf hitler|nazi|nazis|nazism|neo-?nazi\w*|third reich|the reich|ss officers?|kkk|ku klux klan|klansm[ae]n|white power|white pride|white supremac\w*|white nationalis\w*|aryan (?:nation|nations|brotherhood)|stormfront|atomwaffen|proud boys|patriot front|islamic state|isil|daesh|al[- ]qaeda|al[- ]qaida|al[- ]shabaab|boko haram|taliban|hamas|hezbollah|bin laden|mein kampf|great replacement|1488|fourteen words)\b"#)

    /// Nationalities, ethnic, religious and other protected groups, as group nouns.
    static let groupWords: [String] = {
        var w = Array(Lex.nationalities) + [
            "jew", "muslim", "christian", "catholic", "protestant", "hindu", "sikh", "buddhist", "atheist",
            "mormon", "arab", "asian", "gypsy", "gypsies", "roma", "romani",
            "native", "native american", "aboriginal", "indigenous", "first nation", "immigrant",
            "migrant", "refugee", "foreigner", "gay", "lesbian", "homosexual", "trans", "transgender", "queer",
            "bisexual", "jewish", "islamic", "slav", "slavic", "caucasian", "oriental", "westerner",
            "easterner", "northerner", "southerner", "yank", "yankee", "brit", "aussie", "chinaman",
        ]
        w = w.map { NSRegularExpression.escapedPattern(for: $0) }
        return w.sorted { $0.count > $1.count }
    }()

    /// "hates the Chinese", "hates Africans", "can't stand Muslim people":
    /// hostility towards a whole group. "hates Chinese food" is fine (the group
    /// word must end the object, optionally followed by people/folk/men…).
    static let groupHate: Rx = {
        let g = "(?:" + groupWords.joined(separator: "|") + ")"
        let tail = #"(?:\s+(?:people|persons|folks?|men|women|guys|kids|immigrants|ones|in general))"#
        let verb = #"\b(?:hates?|hated|hating|dislikes?|despises?|loathes?|detests?|can't stand|cannot stand|can not stand|does not like|doesn't like|do not like|don't like|is afraid of|is scared of|fears|resents|is disgusted by|wants to get rid of|wants to deport)\s+(?:(?:all|those|these|most|every|any|some|many|other)\s+)*"#
        // "the Chinese", "Africans", "Chinese people" — but not bare "Chinese"
        // or "English" (a language or a school subject).
        let object = "(?:the\\s+(?:(?:other|rest of the)\\s+)?\(g)(?:s|es)?\(tail)?|\(g)(?:s|es)\(tail)?|\(g)\(tail))"
        return Rx(verb + object + #"\s*$"#)
    }()

    /// "hates women", "hates fat people", "can't stand disabled people".
    static let peopleHate = Rx(#"\b(?:hates?|hated|hating|dislikes?|despises?|loathes?|detests?|can't stand|cannot stand|can not stand|does not like|doesn't like|resents|is disgusted by|wants to get rid of)\s+(?:(?:all|those|these|most|every|any|some|many)\s+)*(?:the\s+)?(?:women|men|females|males|fat (?:people|folks?|men|women|kids|guys)|fatties|old (?:people|folks?)|the elderly|elderly people|disabled (?:people|folks?)|the disabled|poor (?:people|folks?)|the poor|homeless (?:people|folks?)|the homeless|ugly (?:people|folks?)|gingers|redheads|short (?:people|men)|autistic (?:people|kids))\s*$"#)

    /// Statements that suggest self-harm or a crisis. They are never stored as a
    /// preference ("hates themselves", "hates their life", "hates being alive");
    /// the app should route them to its wellbeing handling instead
    /// (`FactExtractor.selfHarmSignal(in:)`).
    static let selfHarm = SelfHarmDetector(
        strong: Rx(#"(?:\b(?:hate|hates|loathe|loathes|despise|despises|hurt|harm|harming|cut|cutting|kill|killing|starve|starving) (?:myself|themselves|meself)\b(?! laughing)|\b(?:hate|hates|hating) (?:my|their)(?: own| whole| entire)? (?:life|existence|self)\b|\b(?:hate|hates|hating|loathe|loathes|despise|despises) (?:being alive|existing|being me|being myself|who I am|who they are|what I am|what I have become|what they have become|the person I am|(?:living|life)(?=\s*(?:$|[.!?,;])))|\bwish I (?:was|were) (?:dead|never born)\b|\bwish I (?:was|were) not (?:alive|here|born|around)\b|\bwish I (?:did|had) not (?:wake|woken) up\b|\bbetter off dead\b|\bbetter off without me\b|\bend (?:it all|my life|my own life)\b|\b(?:going to|gonna|want to|wanna|might|will|could|should just|am going to|plan to|planning to|thinking of|thinking about|about to) end (?:it|things|everything)(?: all)?(?=\s*(?:$|[.!?,;]|(?:tonight|today|now|soon|for good|this time)\b))|\bending (?:it all|my life|my own life)\b|\bending (?:things|everything)\b(?!\s+(?:with|between|off)\b)|\bending it(?=\s*(?:$|[.!?,;]|(?:tonight|today|now|soon|for good)\b))|\btake my (?:own )?life\b|\bsuicid\w*|\bself[- ]harm\w*|\bno reason to (?:live|go on|keep going)\b|\b(?:do not|does not|dont|don't) want to (?:live|be alive|exist|be here any ?more|wake up)\b|\bwant to stop (?:existing|living)\b|\bwant it all to (?:end|stop)\b|\bwant to (?:disappear|vanish)(?:\s+forever)?(?=\s*(?:$|[.!?,;]))|\b(?:nobody|no one|no-one|noone) (?:would|will|is going to|is gonna) (?:miss|notice|care about) me\b|\b(?:nobody|no one|no-one|noone) (?:would|will) (?:care|notice) if I (?:died|was gone|were gone|disappeared|was dead|killed myself)\b|\bcan ?not go on\b|\b(?:want|need) (?:someone|somebody|you) to kill me\b|\b(?:not|no longer) worth living\b|\blife is (?:not|no longer) worth it\b|\b(?:sleep|asleep) and (?:never|not) wake up\b|\bnever wake up again\b|\b(?:hope|wish) I (?:never|do not) wake up\b|\bcan ?not (?:do|take|handle|bear|stand) (?:this|it|life|living) any ?more\b|\bcan ?not (?:cope|keep going)(?: any ?more)?(?=\s*(?:$|[.!?,;]))|\bI am (?:just |such |only |nothing but |always |so )?(?:a |an )?burden\b|\b(?:being|feel like|feeling like) (?:such )?a burden\b|\ba burden (?:to|on) (?:everyone|everybody|my family|my friends|them|you all|all of you|people|the world)\b|\b(?:jump|jumping|throw myself|throwing myself) (?:off|from) (?:a|the|some) (?:bridge|building|roof|balcony|tower block|skyscraper)\b|\b(?:step|stepping|jump|jumping|throw myself|throwing myself) in front of (?:a|the) (?:train|bus|truck|car|lorry)\b|(?<![\d.] )(?<![\d.])\bkms\b|\bunaliv(?:e|ing|ed)\b)"#),
        dieWish: Rx(#"\b(?:want|wanna|going|gonna|wish|plan|planning|ready|deserve|deserves) to die\b"#),
        hyperbole: Rx(#"\b(?:of (?:embarrassment|shame|boredom|laughter|laughing|cringe|cuteness|hunger|thirst|happiness|jealousy|old age|heat|excitement)|laughing|lol|lmao|lmfao|rofl|haha\w*|hehe\w*|so (?:good|funny|cute|hot|bored|boring|hungry|embarrass\w*|beautiful|amazing|awkward|cringe\w*)|this (?:song|show|movie|film|game|meeting|class|lecture|lesson|heat|traffic|queue|line|episode|book)|another (?:meeting|class|lecture|day|minute|hour|second|email|call)|one more (?:meeting|class|lecture|minute|hour|second|day|email|call)|if I (?:have|had) to (?:sit|listen|hear|watch|go|eat|read|wait|attend)\b|if (?:she|he|they|my \w+) (?:sees|see|finds out|find out|hears|hear)|when (?:she|he|they|my \w+) (?:sees|see|finds out|find out)|in peace|someday|some day|one day|eventually|of old age|bucket list|before (?:I|we) (?:try|see|visit|go|get))\b"#)
    )

    /// True when `text` (an extracted fact) must not be stored.
    public static func isDenied(_ text: String) -> Bool {
        let l = text.lowercased()
        return denied.matches(l) || slurs.matches(l) || extremists.matches(l) || groupHate.matches(l) || peopleHate.matches(l)
    }

    /// True when `text` is a self-harm / wellbeing signal (never stored).
    public static func isSelfHarm(_ text: String) -> Bool {
        selfHarm.matches(FactExtractor.normalise(text))
    }
}

/// Strong self-harm phrasings, plus "I want to / I'm going to die" unless the
/// utterance is plainly hyperbole ("I'm going to die of embarrassment", "I
/// wanna die this song is so good", "another meeting and I'm going to die").
struct SelfHarmDetector: Sendable {
    let strong: Rx
    let dieWish: Rx
    let hyperbole: Rx

    func matches(_ s: String) -> Bool {
        if strong.matches(s) { return true }
        return dieWish.matches(s) && !hyperbole.matches(s)
    }
}

public extension FactExtractor {
    /// True for utterances such as "I hate myself", "I want to die", "nobody would
    /// miss me", "I hate my life", "they'd be better off without me", "I can't do
    /// this anymore", "I'm a burden", "kms". Nothing from such an utterance is
    /// stored; the app should respond with care. Idioms ("kill myself laughing",
    /// "Kill Me Softly", "kill me now, this meeting is boring", "I'm going to die
    /// of embarrassment", "ending things with Sarah") are not signals.
    static func selfHarmSignal(in utterance: String) -> Bool {
        FactPolicy.selfHarm.matches(normalise(utterance))
    }
}
