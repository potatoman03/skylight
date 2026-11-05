import Testing
@testable import SkylightCore

@Suite struct SidebarLayoutTests {
    @Test func pinnedAndTodaySwapPlaces() {
        let order = SidebarSection.standardOrder.moving(.today, by: -1)
        #expect(order == [.favorites, .today, .pinned])
        #expect(order.todayFirst)
        #expect(!order.favoritesLast)
        #expect(order.moving(.today, by: 1) == SidebarSection.standardOrder)
    }

    @Test func favoritesJumpToTheFarEnd() {
        let order = SidebarSection.standardOrder.moving(.favorites, by: 1)
        #expect(order == [.pinned, .today, .favorites])
        #expect(order.favoritesLast)
        #expect(order.moving(.favorites, by: -1) == SidebarSection.standardOrder)
    }

    @Test func movingPastTheEndChangesNothing() {
        let order = SidebarSection.standardOrder
        #expect(order.moving(.pinned, by: -1) == order)
        #expect(order.moving(.today, by: 1) == order)
        #expect(order.moving(.favorites, by: -1) == order)
    }

    @Test func tabsSwapAroundFavoritesAtTheBottom() {
        let order: [SidebarSection] = [.pinned, .today, .favorites]
        #expect(order.moving(.today, by: -1) == [.today, .pinned, .favorites])
    }

    @Test func normalizingRepairsAnyOrder() {
        #expect([SidebarSection]().normalized == SidebarSection.standardOrder)
        #expect(([.today, .today] as [SidebarSection]).normalized == [.today, .favorites, .pinned].normalized)
        #expect(([.pinned, .favorites, .today] as [SidebarSection]).normalized == [.favorites, .pinned, .today])
        for order in [[.today, .pinned, .favorites], [.favorites, .today, .pinned]] as [[SidebarSection]] {
            #expect(order.normalized == order)
        }
    }
}

@Suite struct IconSearchTests {
    @Test func symbolsAreFoundByNameOrSymbol() {
        #expect(IconSearch.symbols(matching: "coffee").map(\.symbol) == ["cup.and.saucer"])
        #expect(IconSearch.symbols(matching: "knife").map(\.symbol) == ["fork.knife"])
        #expect(IconSearch.symbols(matching: "MOU").map(\.symbol) == ["mountain.2"])
        #expect(IconSearch.symbols(matching: "zzz").isEmpty)
        #expect(IconSearch.symbols(matching: "  ") == IconSearch.symbols)
    }

    @Test func everySymbolIsListedOnce() {
        #expect(Set(IconSearch.symbols.map(\.symbol)).count == IconSearch.symbols.count)
        #expect(IconSearch.symbols.count == 39)
    }

    @Test func emojiAreFoundBeyondTheFeaturedOnes() {
        #expect(IconSearch.emoji(matching: "rocket").first == "🚀")
        #expect(IconSearch.emoji(matching: "penguin").contains("🐧"))
        #expect(IconSearch.emoji(matching: "heart").contains("❤️"))
        #expect(IconSearch.emoji(matching: "zzzz").isEmpty)
    }

    @Test func aliasesFindWhatUnicodeNamesMiss() {
        let results = IconSearch.emoji(matching: "coffee")
        #expect(results == ["☕️"])
    }

    @Test func colorlessEmojiAskForColor() {
        // ☀ draws as plain text on its own; ☕ is in color already.
        #expect(IconSearch.emoji(matching: "sun").contains("\u{2600}\u{FE0F}"))
        #expect(IconSearch.emoji(matching: "beverage").contains("\u{2615}"))
    }

    @Test func blankSearchShowsTheFeaturedOnesAndResultsStopAtTheLimit() {
        #expect(IconSearch.emoji(matching: " ") == IconSearch.featuredEmoji)
        #expect(IconSearch.emoji(matching: "face", limit: 12).count == 12)
        #expect(IconSearch.emoji(matching: "face", limit: 12).allSatisfy { !$0.isEmpty })
    }

    @Test func skinTonesAreNotOffered() {
        #expect(IconSearch.emoji(matching: "fitzpatrick").isEmpty)
    }
}
