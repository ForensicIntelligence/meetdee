import Foundation
import Testing
@testable import DeeMemory

/// Table-driven checks of the rule-based extractor. Each case lists EVERY fact
/// expected (order-insensitive); `[]` means "must extract nothing".
struct XCase: Sendable, CustomTestStringConvertible {
    let utterance: String
    let expected: [Expect]
    var testDescription: String { utterance }

    struct Expect: Sendable, Equatable {
        let text: String
        let category: Fact.Category
        let name: String?
    }

    init(_ u: String, _ e: [(String, Fact.Category)], name: String? = nil) {
        utterance = u
        expected = e.enumerated().map { Expect(text: $0.element.0, category: $0.element.1, name: $0.offset == 0 ? name : nil) }
    }
}

let thursdayNoon: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 10; c.day = 8; c.hour = 12
    return utc.date(from: c)!
}()

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func extract(_ s: String) -> [XCase.Expect] {
    FactExtractor.extract(from: s, now: thursdayNoon, calendar: utc).map { .init(text: $0.text, category: $0.category, name: $0.name) }
}

enum Cases {
    static let names: [XCase] = [
        XCase("My name is John", [("is called John", .identity)], name: "John"),
        XCase("my name is john", [("is called John", .identity)], name: "John"),
        XCase("Hi Dee, I'm John", [("is called John", .identity)], name: "John"),
        XCase("Hello! I'm Sarah, nice to meet you.", [("is called Sarah", .identity)], name: "Sarah"),
        XCase("hi, i'm priya", [("is called Priya", .identity)], name: "Priya"),
        XCase("I'm John", [("is called John", .identity)], name: "John"),
        XCase("I’m John Smith", [("is called John Smith", .identity)], name: "John Smith"),
        XCase("Call me Johnny", [("goes by Johnny", .identity)], name: "Johnny"),
        XCase("You can call me Liz.", [("goes by Liz", .identity)], name: "Liz"),
        XCase("Everyone calls me Bob", [("goes by Bob", .identity)], name: "Bob"),
        XCase("It's John here", [("is called John", .identity)], name: "John"),
        XCase("This is John speaking", [("is called John", .identity)], name: "John"),
        // Introducing someone else, not the speaker's name (FactExtractor.introductions).
        XCase("Hey, this is Maria", []),
        XCase("Hi, Maria here", [("is called Maria", .identity)], name: "Maria"),
        XCase("John here!", [("is called John", .identity)], name: "John"),
        XCase("My name's Anne-Marie", [("is called Anne-Marie", .identity)], name: "Anne-Marie"),
        XCase("Hi there, I'm Sam from Toronto", [("is called Sam", .identity), ("is from Toronto", .place)], name: "Sam"),
        XCase("My last name is Czlonka", [("last name is Czlonka", .identity)]),
        XCase("By the way, my name is Ahmed and I love football", [("is called Ahmed", .identity), ("loves football", .preference)], name: "Ahmed"),
    ]

    static let notNames: [XCase] = [
        XCase("I'm tired", []),
        XCase("I'm going to the shop", []),
        XCase("I'm fine thanks", []),
        XCase("I'm so hungry", []),
        XCase("I'm back", []),
        XCase("I'm not John", []),
        XCase("I'm sorry", []),
        XCase("This is great", []),
        XCase("It's Monday", []),
        XCase("call me later", []),
        XCase("Call me when you're ready", []),
        XCase("My name is not important", []),
        XCase("I am ready", []),
        XCase("i'm bored", []),
        XCase("I'm here", []),
        XCase("I'm doing well", []),
        XCase("What's the weather like?", []),
        XCase("I love you", []),
        XCase("I like it", []),
        XCase("I'd like a coffee", []),
        XCase("I have to go now", []),
    ]

    static let places: [XCase] = [
        XCase("I'm from Canada", [("is from Canada", .place)]),
        XCase("I'm originally from Glasgow", [("is from Glasgow", .place)]),
        XCase("I live in Toronto", [("lives in Toronto", .place)]),
        XCase("We live near the lake", [("lives near the lake", .place)]),
        XCase("I've lived in Ottawa for 10 years", []),
        XCase("I live in Ottawa now", [("lives in Ottawa", .place)]),
        XCase("I grew up in Montreal", [("grew up in Montreal", .place)]),
        XCase("We just moved to Halifax", [("lives in Halifax", .place)]),
        XCase("I'm Canadian", [("is Canadian", .place)]),
        XCase("I was born in Poland", [("was born in Poland", .place)]),
    ]

    static let work: [XCase] = [
        XCase("I'm a doctor", [("is a doctor", .work)]),
        XCase("I'm a nurse", [("is a nurse", .work)]),
        XCase("I am an engineer", [("is an engineer", .work)]),
        XCase("I'm a software developer at Apple", [("is a software developer at Apple", .work)]),
        XCase("I work as a nurse", [("works as a nurse", .work)]),
        XCase("I work at the hospital", [("works at the hospital", .work)]),
        XCase("I work for Forensic Intelligence", [("works for Forensic Intelligence", .work)]),
        XCase("I work from home", [("works from home", .work)]),
        XCase("I'm retired", [("is retired", .work)]),
        XCase("I study biology at McGill", [("studies biology at McGill", .work)]),
        XCase("I'm a student", [("is a student", .work)]),
        XCase("My job is teacher", [("works as a teacher", .work)]),
        XCase("My job is boring", []),
        XCase("I teach maths", [("teaches maths", .work)]),
        XCase("I own a bakery", [("owns a bakery", .work)]),
        XCase("I'm in grade 5", [("is in grade 5", .work)]),
    ]

    static let preferences: [XCase] = [
        XCase("I like jazz", [("likes jazz", .preference)]),
        XCase("I love pizza", [("loves pizza", .preference)]),
        XCase("I really love hiking in the mountains", [("loves hiking in the mountains", .preference)]),
        XCase("I enjoy reading", [("enjoys reading", .preference)]),
        XCase("I'm a big fan of the Leafs", [("likes the Leafs", .preference)]),
        XCase("I'm really into astronomy", [("likes astronomy", .preference)]),
        XCase("I like playing with my dog", [("likes playing with their dog", .preference)]),
        XCase("I like jazz too", [("likes jazz", .preference)]),
        XCase("I love cats and dogs", [("loves cats and dogs", .preference)]),
        XCase("I hate mornings", [("hates mornings", .dislike)]),
        XCase("I don't like broccoli", [("dislikes broccoli", .dislike)]),
        XCase("I do not like spiders at all", [("dislikes spiders", .dislike)]),
        XCase("I can't stand country music", [("dislikes country music", .dislike)]),
        XCase("I'm not a fan of horror movies", [("dislikes horror movies", .dislike)]),
        XCase("I'm scared of spiders", [("is afraid of spiders", .dislike)]),
        XCase("I dislike loud noises", [("dislikes loud noises", .dislike)]),
        XCase("My favourite colour is blue", [("favourite colour is blue", .preference)]),
        XCase("My favorite food's sushi", [("favourite food is sushi", .preference)]),
        XCase("Pizza is my favourite food", [("favourite food is Pizza", .preference)]),
        XCase("I play the guitar", [("plays the guitar", .preference)]),
        XCase("I collect stamps", [("collects stamps", .preference)]),
        XCase("I'm a huge jazz fan", [("is a huge jazz fan", .preference)]),
        XCase("I'm a tennis player", [("plays tennis", .preference)]),
        XCase("My hobbies are knitting and baking", [("enjoys knitting and baking", .preference)]),
    ]

    static let pets: [XCase] = [
        XCase("I have a cat called Miso", [("has a cat named Miso", .pet)]),
        XCase("I've got a dog named Rex", [("has a dog named Rex", .pet)]),
        XCase("We have two cats named Salt and Pepper", [("has two cats named Salt and Pepper", .pet)]),
        XCase("My dog's name is Biscuit", [("has a dog named Biscuit", .pet)]),
        XCase("My cat is called Luna", [("has a cat named Luna", .pet)]),
        XCase("my dog Rex is sick", [("has a dog named Rex", .pet)]),
        XCase("I have a hamster", [("has a hamster", .pet)]),
        XCase("I have three dogs", [("has three dogs", .pet)]),
        XCase("Miso is my cat", [("has a cat named Miso", .pet)]),
        XCase("I don't have any pets", [("has no pets", .pet)]),
    ]

    static let family: [XCase] = [
        XCase("My daughter Emma", [("has a daughter named Emma", .relationship)]),
        XCase("my daughter's name is Emma", [("has a daughter named Emma", .relationship)]),
        XCase("My wife is called Sarah", [("has a wife named Sarah", .relationship)]),
        XCase("My wife is Sarah", [("has a wife named Sarah", .relationship)]),
        XCase("My wife is lovely", []),
        XCase("I have two kids", [("has two kids", .relationship)]),
        XCase("I have a son named Max", [("has a son named Max", .relationship)]),
        XCase("Emma is my sister", [("has a sister named Emma", .relationship)]),
        XCase("I'm married", [("is married", .relationship)]),
        XCase("I'm married to Sarah", [("is married to Sarah", .relationship)]),
        XCase("I'm a proud dad of three", [("is a dad of three", .relationship)]),
        XCase("I don't have kids", [("has no kids", .relationship)]),
        XCase("My mom's birthday is June 5th", [("their mom's birthday is June 5", .relationship)]),
        XCase("This is my husband Dave", [("has a husband named Dave", .relationship)]),
    ]

    static let identityAndHealth: [XCase] = [
        XCase("I'm 42", [("is 42 years old", .identity)]),
        XCase("I am 42 years old", [("is 42 years old", .identity)]),
        XCase("I'm forty-two", [("is 42 years old", .identity)]),
        XCase("I just turned 30", [("is 30 years old", .identity)]),
        XCase("I'm 5 minutes away", []),
        XCase("My birthday is March 3rd", [("birthday is March 3", .birthday)]),
        XCase("my birthday's on the 21st of July", [("birthday is July 21", .birthday)]),
        XCase("I was born on December 25", [("birthday is December 25", .birthday)]),
        XCase("Today is my birthday", [("birthday is October 8", .birthday)]),
        XCase("I was born in 1984", [("was born in 1984", .identity)]),
        XCase("I'm allergic to peanuts", [("is allergic to peanuts", .health)]),
        XCase("I have a nut allergy", [("has a nut allergy", .health)]),
        XCase("I have a peanut allergy", [("has a peanut allergy", .health)]),
        XCase("I'm vegetarian", [("is vegetarian", .health)]),
        XCase("I'm a vegan", [("is vegan", .health)]),
        XCase("I have asthma", [("has asthma", .health)]),
        XCase("I have ADHD", [("has ADHD", .health)]),
        XCase("I can't eat gluten", [("can't eat gluten", .health)]),
        XCase("I'm lactose intolerant", [("is lactose intolerant", .health)]),
        XCase("I wear glasses", [("wears glasses", .health)]),
        XCase("I have an allergy to cats", [("is allergic to cats", .health)]),
        XCase("I'm Christian", [("is Christian", .other)]),
        XCase("Hi, I'm Christian", [("is called Christian", .identity)], name: "Christian"),
    ]

    static let events: [XCase] = [
        XCase("I have an exam tomorrow", [("has an exam on Fri 9 Oct 2026", .event)]),
        XCase("Tomorrow I have a job interview", [("has a job interview on Fri 9 Oct 2026", .event)]),
        XCase("I've got a dentist appointment on Monday", [("has a dentist appointment on Mon 12 Oct 2026", .event)]),
        XCase("I have a big presentation next week", [("has a big presentation the week of Mon 12 Oct 2026", .event)]),
        XCase("I'm going to Paris this weekend", [("is going to Paris on Sat 10 Oct 2026", .event)]),
        XCase("I'm flying to Tokyo on the 20th of October", [("is flying to Tokyo on Tue 20 Oct 2026", .event)]),
        XCase("My exam is on Friday", [("has an exam on Fri 9 Oct 2026", .event)]),
        XCase("I'm getting married next month", [("is getting married in November 2026", .event)]),
        XCase("I have a party tonight", [("has a party on Thu 8 Oct 2026", .event)]),
        XCase("I have a match in 3 days", [("has a match on Sun 11 Oct 2026", .event)]),
        XCase("I'm going to bed tonight", []),
        XCase("I have work tomorrow", []),
        XCase("I have an exam", []),
    ]

    /// Everyday chit-chat that must not become a "fact".
    static let chitChat: [XCase] = [
        XCase("I'm Dee's friend", []),
        XCase("I think so", []),
        XCase("I have a question for you", []),
        XCase("I like your eyes", []),
        XCase("I'm going to sleep", []),
        XCase("I'm just kidding", []),
        XCase("I love it when you do that", []),
        XCase("I'm on my way", []),
        XCase("I have to work tomorrow", []),
        XCase("I hate when that happens", []),
        XCase("I don't like that", []),
        XCase("That's my favourite", []),
        XCase("I'm doing my homework tomorrow", []),
        XCase("I hate you", []),
        XCase("I'm Lucky", []),
        XCase("I'm a little bit hungry", []),
        XCase("Are you okay?", []),
    ]

    static let more: [XCase] = [
        XCase("I'm Mark and this is my wife Julie", [("is called Mark", .identity), ("has a wife named Julie", .relationship)], name: "Mark"),
        XCase("I'm Thomas but everyone calls me Tom", [("is called Thomas", .identity), ("goes by Tom", .identity)], name: "Thomas"),
        XCase("we have a golden retriever named Max", [("has a retriever named Max", .pet)]),
        XCase("I work in IT", [("works in IT", .work)]),
        XCase("My mother lives in Poland", [("their mother lives in Poland", .relationship)]),
        XCase("my son is 7", [("their son is 7 years old", .relationship)]),
        XCase("My partner Alex and I live in Vancouver", [("has a partner named Alex", .relationship), ("lives in Vancouver", .place)]),
        XCase("My kids are called Ava and Leo", [("has kids named Ava and Leo", .relationship)]),
        XCase("I'm turning 50 next week", [("is turning 50 the week of Mon 12 Oct 2026", .event)]),
        XCase("So my birthday is next Tuesday", [("birthday is October 13", .birthday)]),
        XCase("Remember that I hate cilantro", [("hates cilantro", .dislike)]),
        XCase("I don't eat meat", [("doesn't eat meat", .health)]),
        XCase("It's me, Sarah", [("is called Sarah", .identity)], name: "Sarah"),
        XCase("Honestly I prefer tea over coffee", [("prefers tea over coffee", .preference)]),
        XCase("I'm a pentester", [("is a pentester", .work)]),
        XCase("I have a flight on Saturday morning at 7", [("has a flight on Sat 10 Oct 2026", .event)]),
    ]

    static let all: [XCase] = names + notNames + places + work + preferences + pets + family + identityAndHealth + events + chitChat + more
}

@Suite("FactExtractor")
struct FactExtractorTests {
    @Test(arguments: Cases.all)
    func extracts(_ c: XCase) {
        let got = extract(c.utterance)
        #expect(Set(got.map(\.text)) == Set(c.expected.map(\.text)), "got \(got)")
        for e in c.expected {
            let g = got.first { $0.text == e.text }
            #expect(g?.category == e.category, "category for '\(e.text)'")
            if let n = e.name { #expect(g?.name == n) }
        }
        // Only self-introductions carry a name.
        for g in got where g.name != nil {
            #expect(g.category == .identity)
        }
    }

    @Test func atLeastEightyUtterancesAreCovered() {
        #expect(Cases.all.count >= 80)
    }

    @Test func multiClauseUtteranceYieldsSeveralFacts() {
        let got = extract("Hi! I'm Maya, I live in Lisbon and I have a cat called Tofu. I hate the cold but I love surfing.")
        let texts = Set(got.map(\.text))
        #expect(texts.contains("is called Maya"))
        #expect(texts.contains("lives in Lisbon"))
        #expect(texts.contains("has a cat named Tofu"))
        #expect(texts.contains("hates the cold"))
        #expect(texts.contains("loves surfing"))
        #expect(got.first { $0.name != nil }?.name == "Maya")
    }

    @Test func factsAreThirdPerson() {
        for g in extract("I love walking my dog with my wife. I like our garden.") {
            #expect(!g.text.lowercased().contains(" my "))
            #expect(!g.text.lowercased().contains(" our "))
            #expect(!g.text.hasPrefix("I "))
        }
    }

    @Test func weekdayOnSameDayMeansNextWeek() {
        // Thursday saying "on Thursday" means the following Thursday.
        #expect(extract("I have a meeting on Thursday").map(\.text) == ["has a meeting on Thu 15 Oct 2026"])
    }

    @Test func pastMonthDayRollsToNextYear() {
        #expect(extract("I have a concert on March 3rd").map(\.text) == ["has a concert on Wed 3 Mar 2027"])
    }

    @Test func emptyAndJunkInput() {
        #expect(extract("").isEmpty)
        #expect(extract("   ").isEmpty)
        #expect(extract("...!!!").isEmpty)
        #expect(extract("asdf qwer").isEmpty)
    }

    @Test func numberWords() {
        #expect(FactExtractor.parseNumber("forty two") == 42)
        #expect(FactExtractor.parseNumber("seventy-seven") == 77)
        #expect(FactExtractor.parseNumber("12") == 12)
        #expect(FactExtractor.parseNumber("blue") == nil)
    }
}
