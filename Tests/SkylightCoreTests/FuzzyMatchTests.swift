import Testing
@testable import SkylightCore

@Suite struct FuzzyMatchTests {
    @Test func aTitleMatchWithNoAddressMatchDoesNotOverflow() {
        // The address doesn't contain the query's letters in order; the title does.
        #expect(FuzzyMatch.score("zq", title: "Zebra quiz", url: "https://example.com/") != nil)
    }

    @Test func matchesByAddressWhenTheTitleDoesNot() {
        let score = FuzzyMatch.score("github", title: "Pull requests", url: "https://github.com/pulls")
        #expect(score == FuzzyMatch.score("github", in: "https://github.com/pulls")! - 50)
    }

    @Test func noMatchIsNil() {
        #expect(FuzzyMatch.score("xyz", title: "Pull requests", url: "https://github.com/") == nil)
    }
}
