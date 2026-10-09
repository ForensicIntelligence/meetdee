import Foundation

/// A compiled regular expression with the few operations the extractor needs.
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, caseSensitive: Bool = false) {
        do {
            re = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            fatalError("Bad DeeMemory pattern \(pattern): \(error)")
        }
    }

    private func range(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: range(s)) != nil }

    /// Capture groups of the first match (index 0 = whole match), nil when no match.
    func groups(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: range(s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let sr = Range(r, in: s) else { return nil }
            let v = String(s[sr])
            return v.isEmpty ? nil : v
        }
    }

    func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: range(s), withTemplate: template)
    }

    /// Pieces of `s` between matches.
    func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: range(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Every pattern the extractor uses (compiled once).
enum R {
    // Building blocks.
    static let WD = "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
    static let MON = "(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"
    static let ORD = #"\d{1,2}(?:st|nd|rd|th)?"#
    static let NUMW = "(?:\\d+|a couple of|a few|a|an|one|two|three|four|five|six|seven|eight|nine|ten)"
    static let TIME = "(?:today|tonight|this (?:morning|afternoon|evening)|the day after tomorrow|tomorrow(?: (?:morning|afternoon|evening|night))?|(?:on |this coming |this |next )?\(WD)(?: (?:morning|afternoon|evening|night))?|next week|later this week|this week|this weekend|next weekend|(?:on|at|over) the weekend|next month|in \(NUMW) (?:days?|weeks?)|(?:on )?(?:the )?\(ORD) (?:of )?\(MON)|(?:on )?\(MON) (?:the )?\(ORD))"
    static let NAME = #"([A-Za-z][A-Za-z'\-]*(?:\s+[A-Za-z][A-Za-z'\-]*){0,3})"#
    /// One to three words, none of them "from".
    static let NAME1 = #"((?!(?:from|here|speaking|again|calling)\b)[A-Za-z][A-Za-z'\-]*(?: (?!(?:from|here|speaking|again|calling)\b)[A-Za-z][A-Za-z'\-]*){0,2})"#
    static let NAMES = #"([A-Za-z][A-Za-z'\-]*(?:(?:\s*,\s*|\s+and\s+|\s*&\s*|\s+)[A-Za-z][A-Za-z'\-]*){0,5})"#
    static let ANIMAL = "(dogs?|pupp(?:y|ies)|cats?|kittens?|kitty|kitties|rabbits?|bunn(?:y|ies)|hamsters?|guinea pigs?|parrots?|birds?|budgies?|cockatiels?|canar(?:y|ies)|goldfish|fish|turtles?|tortoises?|snakes?|lizards?|geckos?|bearded dragons?|horses?|pon(?:y|ies)|ferrets?|rats?|mice|mouse|chickens?|hens?|hedgehogs?|pigs?|goats?|iguanas?|axolotls?|chinchillas?|gerbils?|ducks?|cows?|sheep|alpacas?|llamas?|labradors?|labs?|retrievers?|poodles?|beagles?|terriers?|spaniels?|collies?|huskies|husky|shepherds?|bulldogs?|pugs?|chihuahuas?|dachshunds?|corgis?|schnauzers?|rottweilers?|dobermans?|greyhounds?|whippets?|pit ?bulls?|shih tzus?|yorkies?|maine coons?|ragdolls?|sphynx|bengals?|siamese)"
    static let PETADJ = "(?:(?:little|new|old|big|small|tiny|cute|pet|black|white|ginger|orange|grey|gray|brown|tabby|rescue|lovely|fluffy|baby|young|senior|crazy|lazy|sweet|female|male|girl|boy|two|three|golden|german|french|english|border|cocker|springer|miniature|toy|standard|jack russell|yellow|chocolate|labrador|tuxedo|calico|persian|british shorthair|spotted)\\s+)*"
    static let REL = "(wife|husband|partner|spouse|girlfriend|boyfriend|fianc[eé]e?|sons?|daughters?|kids?|children|child|bab(?:y|ies)|toddlers?|mother|mom|mum|mommy|mummy|mama|father|dad|daddy|papa|parents|(?:twin |little |big |older |younger |baby |half |half-|step)?(?:brothers?|sisters?)|siblings?|twins?|grandmother|grandma|granny|nan|nana|grandfather|grandpa|granddad|grandad|grandsons?|granddaughters?|grandchildren|grandkids?|aunt|auntie|aunty|uncle|cousins?|nieces?|nephews?|best friend|(?:boy|girl)?friends?|boss|roommates?|flatmates?|housemates?|neighbou?rs?|colleagues?|coworkers?|co-workers?|step(?:son|daughter|mother|father|mom|mum|dad)s?|(?:mother|father|sister|brother|son|daughter)s?-in-law)"
    static let RELADJ = "(?:(?:little|big|older|younger|baby|eldest|oldest|youngest|middle|twin|lovely|beautiful|dear|amazing|wonderful|new|grown(?:-| )up|adult|teenage|two|three)\\s+)*"

    // Normalisation.
    static let loneI = Rx(#"(?<![\w'])i(?![\w'])"#, caseSensitive: true)
    static let spaces = Rx(#"\s+"#)
    static let contractions: [(Rx, String)] = [
        (Rx(#"\bi'm\b"#), "I am"), (Rx(#"\bim\b(?= [a-z])"#, caseSensitive: true), "I am"),
        (Rx(#"\bi've\b"#), "I have"), (Rx(#"\bi'll\b"#), "I will"), (Rx(#"\bi'd\b"#), "I would"),
        (Rx(#"\bwe've\b"#), "we have"), (Rx(#"\bwe're\b"#), "we are"),
        (Rx(#"\b(do|does|did|is|are|was|were|has|have|had|should|would|could|must)n't\b"#), "$1 not"),
        (Rx(#"\bcan't\b"#), "cannot"), (Rx(#"\bwon't\b"#), "will not"), (Rx(#"\bain't\b"#), "am not"),
        (Rx(#"\bit's\b"#), "it is"), (Rx(#"\bhe's\b"#), "he is"), (Rx(#"\bshe's\b"#), "she is"), (Rx(#"\bthat's\b"#), "that is"), (Rx(#"\bthere's\b"#), "there is"),
        (Rx(#"\b(favou?rite|fave) (\w+(?: \w+)?)'s\b"#), "$1 $2 is"),
        (Rx(#"\b(name|birthday|surname|nickname|job|hometown|exam|test|interview|appointment|party|wedding|flight|surgery)'s\b"#), "$1 is"),
        (Rx(#"\bgonna\b"#), "going to"), (Rx(#"\bwanna\b"#), "want to"), (Rx(#"\bgotta\b"#), "have got to"),
        (Rx(#"\bkinda\b"#), "kind of"), (Rx(#"\bsorta\b"#), "sort of"),
    ]

    /// "Dr. Jones" → "Dr Jones" so the sentence splitter does not cut the name.
    static let titleDot = Rx(#"\b(Dr|Mr|Mrs|Ms|Mx|St|Prof|Rev|Sr|Jr)\.(?=\s)"#)

    // Clauses.
    static let sentenceBreak = Rx(#"[.!?;\n]+(?:\s+|$)|\s+-\s+"#)
    static let clauseBreak = Rx(#"\s*,?\s+(?:and also|and then|and|but|so|because|cause|cos|though|although|plus|while)\s+(?=(?:I|my|we|our|this is|everyone|everybody|people|you can|call me)\b)|\s*,\s*(?=(?:I|my|we|our|call me|you can call me|this is)\b)"#)
    static let leadingFiller = Rx(#"^(?:(?:hey there|hi there|hello there|hi|hello|hey|hiya|howdy|yo|oh and|oh|ah|okay|ok|alright|so|well|um+|uh+|erm|er+|hmm+|actually|anyway|anyways|also|and|but|plus|then|by the way|btw|you know what|you know|listen|look|dee|good (?:morning|afternoon|evening|day)|nice to meet you|pleased to meet you|yeah|yep|yes|no|nope|sure|just so you know|fyi|for the record|fun fact|please remember(?: that)?|remember(?: that)?|do not forget(?: that)?|I want you to (?:know|remember)(?: that)?|you should know(?: that)?|I should (?:mention|tell you)(?: that)?|let me tell you(?: that)?|let me introduce myself|I (?:just )?wanted to (?:say|tell you|let you know)(?: that)?|guess what|honestly|to be honest|in fact|I mean)\b[\s,!.:\-]*)+"#)
    static let trailingFiller = Rx(#"(?:[\s,]+|^)(?:nice to meet you|pleased to meet you|good to meet you|great to meet you|by the way|btw|lol|haha+|hehe+|thanks|thank you|okay|ok|you know|dee|actually|just so you know|if you must know|remember that|remember)[\s!.,?]*$"#)
    /// "I have a cat called Whiskers and a dog called Rex": the verb to carry.
    static let possessionVerb = Rx(#"^((?:I|we) (?:have got|have|got|own|adopted|just got))\s"#)
    static let possessionAnd = Rx("\\s*,?\\s+and\\s+(?=(?:a|an|one|two|three|four|five|\\d+)\\s+(?:\(PETADJ)\(ANIMAL)|\(RELADJ)\(REL))(?:\\s+(?:called|named)\\b|$))")
    static let introContext = Rx(#"\b(?:hi|hello|hey|hiya|howdy|nice to meet you|pleased to meet you|good to meet you|introduce myself)\b"#)
    static let leadingTime = Rx("^(\(TIME)),?\\s+((?:I|we|my|our)\\b.+)$")

    // Health.
    static let allergicTo = Rx(#"^I am (?:very |really |quite |severely |deathly |super |highly |a (?:bit|little) )?allergic to (.+)$"#)
    static let allergyNoun = Rx(#"^I have (?:an? )?(?:(?:severe|serious|bad|mild|slight|nut|food) )?(?:allerg(?:y|ies) to (.+)|(.+?) allerg(?:y|ies))$"#)
    static let diet = Rx(#"^I am (?:a |an )?(?:strict |pretty much |mostly )?(vegetarian|vegan|pescatarian|gluten[- ]free|lactose[- ]intolerant|diabetic|celiac|coeliac|asthmatic|epileptic|deaf|blind|colou?r[- ]?blind|pregnant|hard of hearing|sober|teetotal|dyslexic|autistic|bipolar|schizophrenic|epileptic|anorexic|bulimic|hiv positive|in a wheelchair)(?: now)?$"#)
    static let condition = Rx(#"^I (have got|have|suffer from|was diagnosed with|live with|got) (type (?:1|2|one|two) diabetes|diabetes|asthma|arthritis|migraines|epilepsy|adhd|autism|celiac disease|coeliac disease|crohn's|anxiety|depression|ptsd|ocd|high blood pressure|low blood pressure|a bad back|back pain|chronic pain|insomnia|sleep apnea|tinnitus|a heart condition|heart disease|cancer|long covid|a cold|the flu|covid|a fever|a headache|a migraine|a sore throat|a broken \w+|hay ?fever|eczema|psoriasis|dementia|parkinson's|multiple sclerosis|a pacemaker)\b"#)
    static let cannotEat = Rx(#"^I (cannot|can not|do not|should not|am not allowed to|must not) (?:really |ever )?eat (.+)$"#)
    static let broke = Rx(#"^I (?:just |recently )?broke my (\w+)"#)
    static let wears = Rx(#"^I (?:wear|have) (glasses|hearing aids?|a hearing aid|contacts|contact lenses|braces|dentures)$"#)

    // Pets.
    static let havePetNamed = Rx("^(?:I|we) (?:have got|have|got|own|adopted|just got) (a|an|one|two|three|four|five|\\d+|my)?\\s*\(PETADJ)\(ANIMAL) (?:called|named|whose name is|whose names are|by the name of|that is called|who is called) \(NAMES)$")
    static let myPetIsCalled = Rx("^(?:my|our) \(PETADJ)\(ANIMAL)(?:'s name is|'s names are| is called| are called| is named| are named|'s called| name is| goes by| answers to) \(NAMES)$")
    static let myPetName = Rx("^(?:this is )?(?:my|our) \(PETADJ)\(ANIMAL),? \(NAMES)(?:\\b.*)?$")
    static let nameIsMyPet = Rx("^([A-Za-z][A-Za-z'\\-]*) is (?:my|our) \(PETADJ)\(ANIMAL)$")
    static let havePet = Rx("^(?:I|we) (?:have got|have|got|own) (a|an|one|two|three|four|five|six|\\d+)\\s+\(PETADJ)\(ANIMAL)$")
    static let noPets = Rx(#"^(?:I|we) (?:do not have|have no|have not got) (?:any )?pets$"#)

    // Relationships.
    static let relBirthday = Rx("^my \(REL)'s birthday is (?:on )?(.+)$")
    static let myRelIsCalled = Rx("^(?:my|our) \(RELADJ)\(REL)(?:'s name is|'s names are| is called| are called| is named| are named|'s called| name is) \(NAMES)$")
    static let myRelName = Rx("^(?:this is )?(?:my|our) \(RELADJ)\(REL)(?:,| is)? \(NAMES)(?:\\b.*)?$")
    static let relOther = Rx("^my \(RELADJ)\(REL) ((?:is|was) \\d{1,3}(?: years old)?|(?:lives|works|is from|loves|likes|hates|is allergic|studies|goes to|plays|is a|is an)\\b.+)$")
    static let nameIsMyRel = Rx("^([A-Za-z][A-Za-z'\\-]*) is (?:my|our) \(RELADJ)\(REL)$")
    static let haveRel = Rx("^(?:I|we) (?:have got|have|got) (a|an|one|two|three|four|five|six|seven|eight|\\d+)\\s+\(RELADJ)\(REL)(?: (?:called|named) \(NAMES))?(?:,? .*)?$")
    static let widow = Rx(#"^I am (?:a )?(widow|widower)$"#)
    static let marital = Rx(#"^I am (?:happily |recently |newly |just |now )?(married|engaged|divorced|single|widowed|separated)(?: to ([A-Za-z][A-Za-z'\-]*(?: [A-Za-z][A-Za-z'\-]*)?))?(?: now)?$"#)
    static let parentOf = Rx(#"^I am (?:a |an )?(?:proud |single |new |first[- ]time )?(mom|mum|mother|dad|father|parent|grandmother|grandfather|grandparent|grandma|grandpa|stepmom|stepdad)(?: of (.+))?$"#)
    static let noKids = Rx(#"^(?:I|we) (?:do not have|have no|have not got) (?:any )?(kids|children|siblings|brothers or sisters)$"#)
    static let onlyChild = Rx(#"^I am an only child$"#)

    // Birthday and age.
    static let myBirthday = Rx(#"^my birthday is (?:on )?(.+)$"#)
    static let birthdayIsToday = Rx(#"^(today|tomorrow|the day after tomorrow) is my birthday$"#)
    static let bornOn = Rx(#"^I was born on (.+)$"#)
    static let bornInYear = Rx(#"^I was born in (\d{4})$"#)
    static let bornInPlace = Rx(#"^I was born in ([A-Za-z].*)$"#)
    static let AGEW = "(\\d{1,3}|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:a |one )?hundred(?: and \\w+)?)"
    static let iAmAge = Rx("^I am \(AGEW)(?: years? old| years? of age| years?| now| this year| today| and a half)*$")
    static let turned = Rx("^I (?:just |recently )?turned \(AGEW)(?: years old)?(?: today| this year| last week| yesterday| last month)?$")

    // Names.
    static let negatedName = Rx(#"^(?:my name is not|do not call me|please do not call me)\b"#)
    static let myNameIs = Rx("^(?:my (?:first |full |real |actual )?name is(?: actually)?|the name is|name is|I am called|I am named|I go by|I usually go by) \(NAME)")
    static let callMe = Rx("^(?:you can |you may |please |just |everyone |everybody |people |most people |my friends |friends |they |all my friends |my family )?(?:call|calls) me \(NAME)")
    static let surname = Rx("^my (?:last name|surname|family name) is \(NAME)")
    static let nickname = Rx("^my nickname is \(NAME)")
    static let iAmName = Rx("^I am \(NAME1)(?: here| speaking| again)?(?:,? from (.+))?$")
    static let thisIsName = Rx("^(this is|it is)( me,?)? \(NAME1)( here| speaking| again| calling)?$")
    /// "Meet Sarah", "meet my friend Sarah", "say hi to my wife Anna", "I'd like you to meet Sam".
    static let meetSomeone = Rx("^(?:(?:I want you to|I would like you to|you should|come and|come|please|you have to|you got to|you need to) )?(?:meet|say hi to|say hello to|let me introduce(?: you to)?|I want to introduce(?: you to)?|I would like to introduce(?: you to)?|can I introduce(?: you to)?|allow me to introduce)\\s+(?:(?:my|our) \(RELADJ)\(REL),?\\s+)?\(NAME1)$")
    /// "This is my friend Sarah" — introducing someone who is here.
    static let thisIsMyRel = Rx("^this is (?:my|our) \(RELADJ)\(REL),? \(NAME1)$")
    static let nameHere = Rx(#"^([A-Za-z][A-Za-z'\-]*) here$"#)
    /// "Mike's my name", "Mike is my name", "Mike Jones is my full name".
    static let nameIsMyName = Rx(#"^([A-Za-z][A-Za-z'\-]*(?: [A-Za-z][A-Za-z'\-]*)?)(?:'s| is) my (?:first |full |real )?name$"#)
    /// "I'm the plumber, Mike", "I'm your driver, Sam", "I'm Anna's dad, Tom".
    static let roleThenName = Rx(#"^I am (?:the |your |a |an |[A-Za-z]+'s )?([a-z][a-z\- ]{1,30}?),\s*([A-Za-z][A-Za-z'\-]*(?: [A-Za-z][A-Za-z'\-]*)?)$"#)
    /// "This is Sarah, my wife" → "This is my wife Sarah" (so the relationship
    /// and the introduction are both understood). Case-sensitive: the name
    /// must be capitalised.
    static let introAppositive = Rx("\\b([Tt]his is|[Mm]eet|[Ss]ay hi to|[Ss]ay hello to) ([A-Z][a-z'\\-]+(?: [A-Z][a-z'\\-]+)?),? ([Mm]y|[Oo]ur) (\(RELADJ)\(REL))\\b", caseSensitive: true)
    /// "Meet my friend Sarah, she lives in Rome": what follows is about Sarah,
    /// not the speaker.
    static let pronounTail = Rx(#",\s*(?:she|he|they|her|his|their|who|whose)\b.*$"#)
    /// "my name is spelled J O H N" / "it is spelt J-O-H-N".
    static let spelledName = Rx(#"^(?:my name is |it is |that is |name is )?spel(?:led|t) ((?:[A-Za-z](?:[\s.\-]+|$)){2,})$"#)
    /// "My name is Bond, James Bond".
    static let bondName = Rx(#"^(?:my name is|the name is|name is|I am) ([A-Za-z][A-Za-z'\-]+), ([A-Za-z][A-Za-z'\-]+) ([A-Za-z][A-Za-z'\-]+)$"#)
    /// "His name is Rex" after "I have a dog".
    static let carryName = Rx("^(?:(?:his|her|its|their|it is) names? (?:is|are) \(NAMES)|(?:he|she|it|they) (?:is|are) (?:called|named) \(NAMES)|(?:he|she|it|they) goes? by \(NAMES))$")

    // Retractions.
    static let petDied = Rx("^(?:my|our) \(PETADJ)\(ANIMAL)(?:,? ([A-Za-z][A-Za-z'\\-]*))?,? (?:just |recently |sadly |unfortunately )?(?:died|passed away|passed on|is dead|was put down|got put down|was put to sleep|ran away|went missing)(?:\\b.*)?$")
    static let relDied = Rx("^my \(RELADJ)\(REL) (?:just |recently |sadly |unfortunately )?(?:died|passed away|passed on|is dead)(?:\\b.*)?$")
    static let nameDied = Rx(#"^([A-Z][a-z'\-]+) (?:just |recently |sadly )?(?:died|passed away)$"#, caseSensitive: true)
    static let quitJob = Rx(#"^I (?:just |recently )?(?:quit|left|lost) my (?:job|work)\b.*$|^I (?:just |recently )?(?:got|was|have been) (?:fired|laid off|let go|made redundant)\b.*$"#)
    static let retractRewrites: [(Rx, String)] = [
        (Rx(#"^I used to be (.+)$"#), "I am $1"),
        (Rx(#"^I used to (.+)$"#), "I $1"),
        (Rx(#"^I am no longer (.+)$"#), "I am $1"),
        (Rx(#"^I no longer (.+)$"#), "I $1"),
        (Rx(#"^I do not have (a|an|any) (.+?)(?: any ?more)?$"#), "I have a $2"),
        (Rx(#"^I do not (.+?) any ?more$"#), "I $1"),
        (Rx(#"^I am not (.+?)(?: any ?more)?$"#), "I am $1"),
        (Rx(#"^I had (a|an|one|two|three|four|five|\d+) (.+)$"#), "I have $1 $2"),
    ]

    // Preferences.
    static let myFavouriteIs = Rx(#"^my (?:absolute |all[- ]time |very |current )?(?:favou?rite|fave) ([a-z][a-z ]{0,30}?) (?:of all time )?(?:is|are|has to be|would be|would have to be|is probably|is definitely) (.+)$"#)
    static let isMyFavourite = Rx(#"^(.+?) (?:is|are) (?:definitely |probably |totally )?my (?:absolute |all[- ]time )?(?:favou?rite|fave)(?: ([a-z][a-z ]{0,30}))?$"#)
    static let ADV = "(?:(?:really|absolutely|just|truly|totally|kind of|sort of|also|do|still|especially|genuinely|actually|honestly|so|quite|have always|always|definitely|very much|seriously|secretly|personally|now|reeeally) )*"
    static let doNotLike = Rx("^(?:I|we) \(ADV)(?:do not|did not|never) (?:really |actually |particularly |much |even |ever )?(?:like|love|enjoy|care for|care about|fancy|dig) (.+)$")
    static let hate = Rx("^(?:I|we) \(ADV)(hate|dislike|detest|loathe|despise|cannot stand|can not stand|cannot bear|am not (?:a |really a |much of a )?(?:big |huge )?fan of|am not into|am not keen on|am not crazy about|am scared of|am afraid of|am terrified of|fear) (.+)$")
    static let like = Rx("^(?:I|we) \(ADV)(like|likes|love|loves|loved|liked|adore|enjoy|enjoyed|am into|am really into|am a (?:big |huge |massive )?fan of|am obsessed with|am crazy about|am passionate about|am mad about|am addicted to|prefer|dig|fancy|am fond of|am keen on) (.+)$")
    static let play = Rx(#"^I (?:also |still |sometimes |often |regularly |love to |like to )?(play|collect|paint|knit|sew|bake|surf|ski|snowboard|skate|climb|hike|garden|sing|dance|draw|swim|cycle|golf|crochet|meditate|practise|practice|do) (.+)$"#)
    static let junkPlay = Rx(#"^(?:with\b|along\b|outside\b|around\b|it$|a game\b|the fool\b|dumb\b|nice\b|not\b|my homework|homework|the dishes|laundry|nothing|that|this|so|too|well|it all)"#)
    static let hobbies = Rx(#"^(?:my (?:hobby is|hobbies are|hobbies include|passion is|thing is)|in my (?:free|spare) time,? I (?:like to |love to |usually )?) ?(.+)$"#)

    // Work.
    static let workFromHome = Rx(#"^I (?:mostly |usually )?work (?:from|at) home$"#)
    static let workAs = Rx(#"^I (?:currently |now |still |actually )?work as (.+)$"#)
    static let workAt = Rx(#"^I (?:currently |now |still |actually )?work (at|for|in|with) (.+)$"#)
    /// "I'm applying for a designer job at Ubisoft", "I applied for a teaching position".
    static let applyingFor = Rx(#"^I (?:am |have |have been |was |just |recently )*(applying|applied) (?:for|to) (?:a|an|the) ([a-z][a-z' -]{1,40}?) (job|position|role|post|internship|apprenticeship)(?: (?:at|with) (.{2,40}))?$"#)
    /// About the plan just mentioned: "it's for a designer job at a game studio".
    static let itsForJob = Rx(#"^(?:it|this|that|the (?:interview|job|position|role|application)) is (?:for|about) (?:a|an|the) ([a-z][a-z' -]{1,40}?) (job|position|role|post|internship|apprenticeship)(?: (?:at|with) (.{2,40}))?$"#)
    /// "it's at Pixel Forge" (the interview's company, not its time).
    static let itsAt = Rx(#"^(?:it|the interview) is (?:at|with) (.{2,40})$"#)
    /// A plan these details may refer to.
    static let jobPlan = Rx(#"\b(?:interview|interviews|job|application|audition|assessment|internship|recruiter|hiring)\b"#)
    static let interviewPlan = Rx(#"\binterviews?\b"#)
    /// "it's at 3", "it's at noon", "it's at home": a time or no company.
    static let notACompany = Rx(#"\d|\b(?:am|pm|noon|midday|midnight|morning|afternoon|evening|night|tonight|today|tomorrow|o'clock|half|quarter|home|the moment|least|most|all|first|last|monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekend|week|month|time|my place|your|you)\b"#)
    static let myJobIs = Rx(#"^my (?:job|profession|occupation|day job|career) is (?:being )?(.+)$"#)
    static let workStatus = Rx(#"^I am (?:currently |now )?(retired|semi[- ]retired|unemployed|self[- ]employed|between jobs|a stay[- ]at[- ]home (?:mom|mum|dad|parent)|out of work|on (?:maternity|paternity|parental|sick) leave|freelancing|job hunting|looking for (?:a )?(?:job|work))$"#)
    static let study = Rx(#"^I (?:am )?(?:currently )?(?:study|studying|major in|majoring in|am doing a degree in|am doing a phd in|am doing my phd in) (?!for\b)(.+?)(?: at (.+))?$"#)
    /// "I study hard" is not a subject.
    static let studyJunk = Rx(#"^(?:hard|a lot|lots|loads|every ?day|all day|all the time|at night|late|too much|a bit|sometimes|often|well|online|at home|alone|together|with (?:friends|them|my \w+)|for (?:an?|their|the|my) .+|in the (?:morning|evening|library))$"#)
    static let goToSchool = Rx(#"^I (?:go to|attend|am at|am in) ((?:the )?[A-Za-z' .\-]*?(?:school|university|college|academy|uni|kindergarten|preschool|daycare))$"#)
    static let grade = Rx(#"^I am in (grade|year|form) (\w+)$"#)
    static let teach = Rx(#"^I teach (.+)$"#)
    static let ownBusiness = Rx(#"^I (own|run) (?:a |an |my own |our own |the )((?:[a-z' ]*?)(?:business|company|shop|store|restaurant|cafe|café|bakery|bar|pub|firm|farm|practice|clinic|salon|studio|startup|agency))$"#)

    // Places.
    static let iAmFrom = Rx(#"^(?:I am|I come|we are|we come) (?:originally |actually |initially )?from (.+)$"#)
    static let liveIn = Rx(#"^(?:I|we) (?:currently |now |still |actually )?(?:live|am living|are living|reside) (in|near|on|outside of|outside|close to|just outside|by|next to) (.+)$"#)
    static let grewUp = Rx(#"^I grew up (?:in|on|near) (.+)$"#)
    static let moved = Rx(#"^(?:I|we) (?:just |recently |only )?moved (?:here |over |back )?(to|from) (.+)$"#)
    static let hometown = Rx(#"^my (?:home ?town|home city|home country) is (.+)$"#)
    static let placeTail = Rx(#"\s+(?:for (?:about |almost |over |nearly )?(?:\d+|a|an|many|a few|a couple of|several|two|three|four|five|ten|twenty)(?: \w+)? (?:years?|months?|weeks?|days?|decades?)|since .+|now|these days|right now|at the moment|currently|originally)$"#)

    // "I am a …" / "I am Canadian".
    static let iAmA = Rx(#"^I am (?:a|an) (.+)$"#)
    static let splitAt = Rx(#"^(.+?) (?:at|for|in|with) .+$"#)
    static let iAmWord = Rx(#"^I am (?:a |an )?([A-Za-z]+)$"#)

    // Events.
    static let haveEvent = Rx("^(?:I|we) (?:have got|have|got|will have|am having|are having) (.+?) (\(TIME))(?: (?:at|around|by|from) [\\w: ]+)?$")
    static let doingEvent = Rx("^(?:I am|I will be|we are) ((?:going|heading|flying|driving|travell?ing|leaving|moving|starting|turning|seeing|meeting|visiting|taking|doing|playing|running|hosting|attending|celebrating|presenting|competing|performing|sitting|getting|graduating|retiring|interviewing|singing|speaking|giving|throwing|in|at)\\b.*?) (\(TIME))(?: (?:at|around|by|from) [\\w: ]+)?$")
    static let myEventIs = Rx("^(?:my|our) ([a-z' ]{2,40}?) (?:is|are|will be|starts|begins|is on) (?:on )?(\(TIME))$")
    static let junkEventObject = Rx(#"^(?:to (?:go|sleep|leave|work|wake up|get up|be|do)\b.*|work|school|nothing|no plans|plans|time|it|that|fun|a nap|lunch|dinner|breakfast|a shower|a bath|class|homework|the day off|off)$"#)
    static let junkGoing = Rx(#"^(?:going (?:to )?(?:bed|sleep|be|do it|try|eat|have a nap|nap|the bathroom|the toilet|work|school|get up|wake up|home|out|shower|take a shower|stay)\b|(?:going|heading) home$|leaving$|having (?:lunch|dinner|breakfast|a nap)|getting up|in bed|at home|at work|in school|at school|doing (?:their |my )?homework)"#)
    static let inN = Rx("^in (\(NUMW)) (days?|weeks?)$")
    static let dayOfMonth = Rx("(\\d{1,2})(?:st|nd|rd|th)?(?: of)? (january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\\b")
    static let monthDay = Rx("\\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\\.? (?:the )?(\\d{1,2})(?:st|nd|rd|th)?\\b")
    static let factDate = Rx(#"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}\b"#, caseSensitive: true)
    static let factMonth = Rx(#"\bin ((?:January|February|March|April|May|June|July|August|September|October|November|December) \d{4})\b"#, caseSensitive: true)

    // Objects.
    static let objectTail = Rx(#"(?:\s+|^)(?:too|as well|a lot|lots|so much|very much|really much|really|though|anyway|I think|I guess|you know|lol|haha+|a bit|a little|now|these days|nowadays|right now|at the moment|at all|more than anything(?: else)?|the most|best|in general|generally|honestly|actually|also|so|much|to be honest|if I am honest|any ?more)$"#)
    static let nameListSplit = Rx(#"\s*(?:,\s*and\b|,|\band\b|&)\s*"#)
    static let thirdPerson: [(Rx, String)] = [
        (Rx(#"\bI am\b"#, caseSensitive: true), "they are"),
        (Rx(#"\bI was\b"#, caseSensitive: true), "they were"),
        (Rx(#"\bI\b"#, caseSensitive: true), "they"),
        (Rx(#"\b[Mm]yself\b"#, caseSensitive: true), "themselves"),
        (Rx(#"\b[Mm]y\b"#, caseSensitive: true), "their"),
        (Rx(#"\b[Mm]ine\b"#, caseSensitive: true), "theirs"),
        (Rx(#"\b[Mm]e\b"#, caseSensitive: true), "them"),
        (Rx(#"\b[Oo]urs\b"#, caseSensitive: true), "theirs"),
        (Rx(#"\b[Oo]ur\b"#, caseSensitive: true), "their"),
        (Rx(#"\b[Ww]e\b"#, caseSensitive: true), "they"),
        (Rx(#"\bus\b"#, caseSensitive: true), "them"),
    ]
}

/// Word lists.
enum Lex {
    static let nonNames: Set<String> = [
        "a", "an", "the", "not", "so", "very", "really", "just", "too", "also", "here", "there", "back", "home",
        "fine", "good", "great", "ok", "okay", "alright", "well", "sick", "ill", "tired", "sleepy", "hungry",
        "thirsty", "bored", "busy", "ready", "sure", "sorry", "happy", "sad", "angry", "mad", "upset", "excited",
        "nervous", "scared", "afraid", "worried", "stressed", "cold", "hot", "warm", "late", "early", "done",
        "finished", "off", "out", "in", "on", "at", "from", "with", "going", "coming", "leaving", "trying", "doing",
        "getting", "about", "still", "always", "never", "now", "glad", "lost", "confused", "curious", "single",
        "married", "divorced", "engaged", "retired", "pregnant", "alive", "awake", "asleep", "free", "available",
        "around", "over", "almost", "kind", "sort", "like", "literally", "totally", "all", "alone", "new", "old",
        "young", "broke", "rich", "poor", "cool", "right", "wrong", "serious", "joking", "kidding", "better",
        "worse", "both", "one", "two", "your", "you", "it", "this", "that", "me", "him", "her", "them", "yours",
        "allergic", "vegetarian", "vegan", "human", "someone", "somebody", "nobody", "everyone", "everybody",
        "listening", "beautiful", "lucky", "proud", "impressed", "amazed", "surprised", "thankful", "grateful",
        "interested", "obsessed", "into", "against", "for", "positive", "certain", "convinced", "able", "unable",
        "starving", "exhausted", "freezing", "feeling", "being", "having", "making", "moving", "working",
        "studying", "living", "learning", "reading", "watching", "playing", "eating", "drinking", "sitting",
        "standing", "walking", "running", "waiting", "talking", "thinking", "looking", "sleeping", "staying",
        "using", "my", "his", "our", "their", "later", "tomorrow", "tonight", "today", "sometime", "when",
        "if", "maybe", "please", "anytime", "whenever", "crazy", "what", "whatever", "anything", "nothing",
        "something", "everything", "no", "yes", "yeah", "hey", "hi", "hello", "fun", "funny", "weird", "stupid",
        "dumb", "smart", "clever", "honest", "afraid", "aware", "unsure", "certain", "quite", "pretty", "super",
        "only", "even", "again", "still", "currently", "definitely", "probably", "actually", "basically",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "sir", "madam", "dee", "gonna", "bad", "ugly", "sweet", "nice", "lovely", "awesome",
        "terrible", "fat", "thin", "tall", "short", "strong", "weak", "fit", "healthy", "online", "offline",
        "inside", "outside", "upstairs", "downstairs", "away", "near", "close", "far", "first", "last", "next",
        "hurt", "injured", "drunk", "high", "low", "full", "empty", "safe", "calm", "relaxed", "comfortable",
        "uncomfortable", "annoyed", "frustrated", "disappointed", "jealous", "lonely", "shy", "embarrassed",
        "ashamed", "guilty", "innocent", "wrong", "correct", "telling", "asking", "saying", "kinda", "back",
        "headed", "heading", "off", "sorry", "fed", "sure", "game", "down", "up", "cooking", "cleaning",
        // Moods and states that speech-to-text delivers after "hi i'm …".
        "stuck", "wet", "sore", "grumpy", "cranky", "moody", "chill", "chilled", "tipsy", "hungover",
        "sweaty", "soaked", "muddy", "dirty", "clean", "sober", "lazy", "slow", "fast", "quick",
        "fab", "meh", "blah", "grand", "brilliant", "knackered", "shattered", "wrecked", "dead",
        "poorly", "unwell", "dizzy", "itchy", "achy", "stiff", "numb", "terrified", "anxious",
        "depressed", "miserable", "content", "pleased", "delighted", "thrilled", "pumped", "stoked", "hyped",
        "psyched", "keen", "eager", "desperate", "fried", "beat", "spent", "drained", "burnt", "burned",
        "awful", "horrible", "fantastic", "wonderful", "perfect", "bored", "boring", "quiet", "loud",
        "naked", "dressed", "set", "stoned", "baked", "wasted", "hammered", "smashed", "pissed",
        "cross", "furious", "livid", "broken", "heartbroken", "obese", "overweight",
        // Pronouns ("His name is Rex and he is old" must not name "He").
        "he", "she", "they", "we", "his", "hers", "its", "who", "myself", "yourself", "himself", "herself",
        // Life circumstances ("Hi, I'm Homeless").
        "homeless", "unemployed", "jobless", "employed", "self-employed", "unemployable", "underemployed",
        "overworked", "underpaid", "skint", "bankrupt", "widowed", "separated", "adopted", "orphaned",
        "illegal", "undocumented", "famous", "retiring", "graduating", "expecting", "deployed", "incarcerated",
        "unhoused", "homesick", "new here",
    ]

    /// Health conditions that are never a person's name ("I'm Bipolar").
    static let conditionWords: Set<String> = [
        "bipolar", "schizophrenic", "autistic", "diabetic", "epileptic", "asthmatic", "dyslexic", "anorexic",
        "bulimic", "adhd", "ocd", "ptsd", "celiac", "coeliac", "deaf", "blind", "disabled", "depressed",
        "suicidal", "pregnant", "obese", "overweight", "underweight", "sober", "addicted", "alcoholic",
    ]

    /// Words that are never a PERSON's name (but may be a pet's: "a cat called
    /// Pepper"): colours, body and appearance, sexuality, brands, jokes, titles alone.
    static let notPersonNames: Set<String> = [
        "black", "white", "brown", "red", "blue", "green", "yellow", "orange", "pink", "purple", "grey", "gray",
        "beige", "tan", "golden", "silver", "dark", "pale", "fair", "blonde", "blond", "ginger", "brunette",
        "obese", "overweight", "underweight", "skinny", "slim", "chubby", "fat", "thin", "tall", "short",
        "bald", "hairy", "pregnant", "disabled", "deaf", "blind", "mute", "handicapped", "sick", "ill",
        "gay", "straight", "lesbian", "bi", "bisexual", "queer", "trans", "transgender", "nonbinary",
        "non-binary", "asexual", "ace", "pansexual", "pan", "homosexual", "heterosexual", "cis", "intersex",
        "male", "female", "man", "woman", "boy", "girl", "guy", "dude", "lady", "gentleman", "kid", "adult",
        "netflix", "youtube", "google", "alexa", "siri", "cortana", "chatgpt", "openai", "amazon", "apple",
        "microsoft", "spotify", "hulu", "disney", "pixar", "marvel", "hbo", "cnn", "bbc", "fox", "nbc", "abc",
        "cbs", "espn", "tiktok", "instagram", "facebook", "twitter", "snapchat", "uber", "nike", "adidas",
        "batman", "superman", "spiderman", "spider-man", "ironman", "groot", "spartacus", "yoda", "voldemort",
        "god", "jesus", "satan", "santa", "legend", "boss", "king", "queen",
        "prince", "princess", "lord", "chief", "captain", "doctor", "dr", "mr", "mrs", "ms", "miss", "sir",
        "madam", "professor", "prof", "officer", "nurse", "teacher", "mom", "mum", "dad", "mother", "father",
        "grandma", "grandpa", "baby", "honey", "darling", "sweetie", "buddy", "pal", "mate", "bro", "sis",
        "human", "robot", "alien", "ghost", "monster", "vampire", "zombie", "ninja", "pirate", "wizard",
        "anybody", "back", "inevitable",
    ]

    /// Titles kept in front of a name ("Dr. Jones").
    static let titles: [String: String] = [
        "dr": "Dr.", "doctor": "Dr.", "mr": "Mr.", "mrs": "Mrs.", "ms": "Ms.", "mx": "Mx.", "miss": "Miss",
        "prof": "Prof.", "professor": "Professor", "st": "St.", "rev": "Rev.", "reverend": "Reverend",
    ]

    static let nameStoppers: Set<String> = [
        "and", "from", "but", "by", "here", "there", "nice", "speaking", "the", "too", "again", "now", "btw",
        "so", "if", "who", "which", "that", "i", "or", "of", "at", "in", "with", "to", "for", "also", "right",
        "okay", "ok", "remember", "actually", "though", "dee", "haha", "lol", "please", "thanks", "is", "am",
        "are", "was", "and", "a", "an", "my", "it", "you", "your", "not", "just", "really", "please", "calling", "spelled", "spelt", "spelling", "as", "like", "with",
    ]

    static let adjectiveSuffixes = ["ing", "ed", "ful", "ous", "less", "ive", "able", "ible", "ish", "ly", "est"]

    static let pronounObjects: Set<String> = [
        "it", "that", "this", "them", "him", "her", "you", "those", "these", "there", "one", "stuff", "things",
        "something", "everything", "anything", "nothing", "that one", "this one", "you too", "it too", "both",
        "all of them", "all", "everyone", "everybody", "yours", "mine", "what", "which", "what you said",
        "that idea", "the idea", "so", "very", "much", "too", "you dee", "you so much", "it here", "this place",
        "talking to you", "you guys", "that too", "what you did", "your eyes", "it when you do that",
    ]

    static let intensifiers: Set<String> = [
        "big", "huge", "massive", "real", "true", "total", "absolute", "proper", "avid", "keen", "die-hard",
        "diehard", "lifelong", "professional", "amateur", "really", "very", "pretty", "part-time", "full-time",
        "senior", "junior", "head", "lead", "chief", "retired", "former", "trainee", "qualified", "certified",
        "registered", "licensed", "freelance", "self-employed", "new", "aspiring", "budding",
    ]

    static let fanNouns: Set<String> = [
        "fan", "lover", "person", "enthusiast", "nut", "buff", "geek", "nerd", "addict", "junkie", "fanatic",
        "aficionado", "freak", "fiend", "supporter", "gamer", "foodie", "bookworm", "runner", "cyclist",
        "swimmer", "hiker", "climber", "skier", "surfer", "golfer", "reader", "collector", "gardener",
    ]

    static let notAThing: Set<String> = [
        "bit", "little", "lot", "few", "couple", "kind", "sort", "mess", "wreck", "liar", "joke", "robot",
        "human", "guy", "girl", "boy", "man", "woman", "kid", "child", "adult", "grownup", "dog", "cat",
        "good", "bad", "great", "terrible", "nice", "fast", "slow", "quick", "total", "complete", "fan",
        "person", "very", "bit", "fool", "idiot", "genius", "winner", "loser", "baby",
    ]

    static let occupations: Set<String> = [
        "student", "nurse", "doctor", "teacher", "engineer", "developer", "programmer", "lawyer", "accountant",
        "chef", "cook", "cashier", "pilot", "firefighter", "police officer", "cop", "paramedic", "dentist",
        "pharmacist", "scientist", "artist", "musician", "writer", "author", "designer", "architect", "farmer",
        "mechanic", "electrician", "plumber", "carpenter", "builder", "contractor", "consultant", "manager",
        "ceo", "cto", "cfo", "founder", "entrepreneur", "freelancer", "journalist", "photographer", "therapist",
        "psychologist", "psychiatrist", "surgeon", "vet", "veterinarian", "professor", "lecturer", "researcher",
        "librarian", "salesperson", "salesman", "saleswoman", "realtor", "real estate agent", "banker",
        "trader", "analyst", "clerk", "receptionist", "secretary", "assistant", "waiter", "waitress",
        "bartender", "barista", "driver", "truck driver", "soldier", "officer", "sailor", "marine", "welder",
        "janitor", "cleaner", "caregiver", "nanny", "babysitter", "coach", "athlete", "actor", "actress",
        "dancer", "singer", "model", "streamer", "youtuber", "tutor", "translator", "interpreter",
        "investigator", "detective", "pentester", "hacker", "sysadmin", "technician", "intern", "apprentice",
        "volunteer", "priest", "pastor", "rabbi", "imam", "judge", "paralegal", "optometrist",
        "physiotherapist", "physio", "chiropractor", "midwife", "social worker", "carer", "housewife",
        "homemaker", "baker", "butcher", "florist", "tailor", "hairdresser", "barber", "stylist", "beautician",
        "fireman", "policeman", "policewoman", "businessman", "businesswoman", "postman", "mailman",
        "comedian", "politician", "agent", "president", "director", "executive", "producer", "editor",
        "teaching assistant", "pharmacist", "dietitian", "nutritionist", "radiologist", "anesthesiologist",
        "security guard", "guard", "machinist", "electrical engineer", "software engineer", "data scientist",
        "civil servant", "public servant", "lab technician", "dental hygienist", "personal trainer", "trainer",
        "landscaper", "painter", "roofer", "miner", "fisherman", "rancher", "logger", "courier", "pharmacy tech",
        "lifeguard", "flight attendant", "nun", "monk", "mp", "mayor", "diplomat", "ambassador", "economist",
        "mathematician", "physicist", "chemist", "biologist", "geologist", "astronomer", "doctoral student",
        "grad student", "phd student", "undergrad", "resident", "medic", "emt", "cna", "rn", "lpn",
    ]

    static let notOccupations: Set<String> = [
        "mother", "father", "brother", "sister", "daughter", "member", "beginner", "believer", "lover",
        "winner", "loser", "killer", "partner", "owner", "leader", "player", "user", "customer", "other",
        "quitter", "sinner", "dreamer", "thinker", "talker", "listener", "worrier", "fighter", "survivor",
        "optimist", "pessimist", "realist", "idealist", "perfectionist", "introvert", "extrovert", "ambivert",
        "vegetarian", "christian", "teenager", "newcomer", "foreigner", "stranger", "riser", "sleeper",
        "eater", "drinker", "smoker", "nonsmoker", "non-smoker", "gamer", "reader", "runner", "cyclist",
        "swimmer", "hiker", "climber", "skier", "surfer", "golfer", "monster", "softie", "wonder", "number",
        "señor", "senior", "junior", "minor", "major", "humanitarian", "libertarian", "vegetarian",
        "civilian", "guardian", "veteran", "widow", "widower", "atheist", "agnostic", "activist", "leo",
        "virgo", "libra", "scorpio", "sagittarius", "capricorn", "aquarius", "pisces", "aries", "taurus",
        "gemini", "cancer", "feminist", "socialist", "communist", "capitalist", "nationalist", "separatist",
        "pacifist", "environmentalist", "royalist", "loyalist", "theist", "deist", "satanist", "buddhist",
        "baptist", "methodist", "fundamentalist", "extremist", "narcissist", "masochist", "sadist",
        "hypochondriac", "insomniac", "diabetic", "alcoholic", "addict", "vaper", "sleepwalker",
        "daydreamer", "overthinker", "procrastinator", "chatterbox", "romantic", "loner", "homebody",
        "owl", "foodie", "nerd", "geek", "twin", "orphan", "immigrant", "refugee", "expat", "local",
        "tourist", "visitor", "guest", "neighbour", "neighbor", "friend", "regular", "amateur",
    ]

    static let occupationSuffixes = ["ologist", "ographer", "eer", "ist", "ian", "er", "or"]

    static let nationalities: Set<String> = [
        "american", "canadian", "mexican", "brazilian", "argentinian", "argentine", "chilean", "peruvian",
        "colombian", "venezuelan", "cuban", "jamaican", "haitian", "italian", "indian", "russian", "ukrainian",
        "romanian", "bulgarian", "hungarian", "croatian", "serbian", "bosnian", "slovenian", "slovakian",
        "czech", "polish", "german", "austrian", "swiss", "french", "belgian", "dutch", "danish", "swedish",
        "norwegian", "finnish", "icelandic", "irish", "scottish", "welsh", "english", "british", "australian",
        "kiwi", "korean", "japanese", "chinese", "vietnamese", "thai", "filipino", "filipina", "indonesian",
        "malaysian", "singaporean", "pakistani", "bangladeshi", "nepali", "iranian", "persian", "iraqi",
        "syrian", "lebanese", "turkish", "greek", "egyptian", "moroccan", "algerian", "tunisian", "nigerian",
        "ghanaian", "kenyan", "ethiopian", "somali", "african", "european", "asian", "latino", "latina",
        "hispanic", "portuguese", "spanish", "quebecois", "québécois", "newfoundlander", "texan",
        "californian", "israeli", "palestinian", "afghan", "albanian", "armenian", "georgian", "lithuanian",
        "latvian", "estonian", "maltese", "cypriot", "taiwanese", "mongolian", "cambodian", "laotian",
        "burmese", "sri lankan", "south african", "new zealander", "puerto rican", "dominican", "salvadoran",
        "guatemalan", "honduran", "nicaraguan", "panamanian", "ecuadorian", "bolivian", "paraguayan",
        "uruguayan", "trinidadian", "barbadian", "bahamian", "acadian", "metis", "métis", "inuit",
        // -ese demonyms.
        "congolese", "senegalese", "nepalese", "sudanese", "south sudanese", "togolese", "beninese", "guyanese",
        "faroese", "bhutanese", "gabonese", "javanese", "balinese", "surinamese", "timorese", "sinhalese",
        "cantonese", "pekingese", "genoese", "milanese", "viennese", "bolognese", "siamese", "nigerois",
        // Africa.
        "angolan", "cameroonian", "ivorian", "malian", "nigerien", "rwandan", "ugandan", "tanzanian", "zambian",
        "zimbabwean", "namibian", "botswanan", "motswana", "malawian", "mozambican", "liberian", "sierra leonean",
        "gambian", "guinean", "eritrean", "djiboutian", "libyan", "mauritanian", "malagasy", "mauritian",
        "seychellois", "burundian", "burkinabe", "chadian", "comorian", "cape verdean", "basotho", "swazi",
        "somalian", "zulu", "xhosa", "yoruba", "igbo", "hausa", "amhara", "berber", "amazigh",
        // Asia, Middle East, Pacific.
        "kazakh", "kazakhstani", "uzbek", "kyrgyz", "tajik", "turkmen", "azerbaijani", "azeri", "saudi",
        "emirati", "qatari", "kuwaiti", "bahraini", "omani", "yemeni", "jordanian", "kurdish", "kurd",
        "tibetan", "uyghur", "hmong", "bruneian", "maldivian", "punjabi", "gujarati", "bengali", "tamil",
        "fijian", "samoan", "tongan", "maori", "māori", "hawaiian", "papuan", "polynesian", "micronesian",
        // Europe and the Americas.
        "belarusian", "moldovan", "macedonian", "montenegrin", "kosovar", "luxembourgish", "luxembourger",
        "monegasque", "andorran", "sammarinese", "scots", "cornish", "manx", "flemish", "walloon", "basque",
        "catalan", "galician", "sicilian", "sardinian", "corsican", "breton", "bavarian", "slovak", "slovene",
        "serb", "croat", "bosniak", "greenlandic", "greenlander", "bermudian", "belizean", "costa rican",
        "grenadian", "antiguan", "vincentian", "aruban", "argentinean", "brazillian",
        "ukranian", "chicano", "chicana", "creole", "cajun", "appalachian",
    ]

    static let religions: Set<String> = [
        "christian", "catholic", "protestant", "jewish", "muslim", "buddhist", "hindu", "sikh", "atheist",
        "agnostic", "mormon", "orthodox", "baptist", "methodist", "lutheran", "anglican", "pagan", "spiritual",
    ]

    static let relationWords: Set<String> = [
        "wife", "husband", "partner", "spouse", "girlfriend", "boyfriend", "fiance", "fiancee", "fiancé",
        "fiancée", "son", "sons", "daughter", "daughters", "kid", "kids", "child", "children", "baby", "mother",
        "mom", "mum", "mommy", "mummy", "father", "dad", "daddy", "brother", "brothers", "sister", "sisters",
        "grandmother", "grandma", "grandfather", "grandpa", "aunt", "uncle", "cousin", "niece", "nephew",
        "friend", "best friend", "boss", "roommate", "parents", "siblings", "family", "grandparents",
    ]

    static let pluralRelations: Set<String> = ["children", "grandchildren", "parents", "kids", "siblings", "twins", "grandkids"]

    static let determiners: Set<String> = [
        "a", "an", "the", "my", "their", "his", "her", "our", "two", "three", "four", "several", "some", "many",
        "one", "this", "that", "another", "lots", "plenty", "no", "every",
    ]

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "a": 1,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
}
