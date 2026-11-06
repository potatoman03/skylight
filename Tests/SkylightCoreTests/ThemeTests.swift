import Foundation
import Testing
@testable import SkylightCore

struct ThemeTests {
    @Test func hexRoundTrips() throws {
        let color = try #require(RGB(hex: "#3B6FD8"))
        #expect(color.hex == "#3B6FD8")
        #expect(RGB(hex: "3b6fd8") == color)
        #expect(RGB(hex: "#12345") == nil)
        #expect(RGB(hex: "nothex") == nil)
    }

    @Test func hsvMatchesKnownColors() {
        #expect(RGB(h: 0, s: 1, v: 1).hex == "#FF0000")
        #expect(RGB(h: 1.0 / 3, s: 1, v: 1).hex == "#00FF00")
        #expect(RGB(h: 2.0 / 3, s: 1, v: 1).hex == "#0000FF")
        #expect(RGB(h: 0.5, s: 0, v: 0.5).hex == "#808080")
        let hsv = RGB(hex: "#3B6FD8")!.hsv
        #expect(RGB(h: hsv.h, s: hsv.s, v: hsv.v).hex == "#3B6FD8")
    }

    @Test func followingThemesTurnWithTheSpace() {
        let theme = SkyTheme.standard
        #expect(theme.palette(dark: false, spaceHue: SkyTheme.baseHue) == theme.light)
        let red = theme.palette(dark: false, spaceHue: 0)
        #expect(abs(red.sky.hsv.h - (theme.light.sky.hsv.h - SkyTheme.baseHue + 1).truncatingRemainder(dividingBy: 1)) < 0.01)
        #expect(abs(red.sky.hsv.s - theme.light.sky.hsv.s) < 0.01)
        let paper = SkyTheme.preset("paper")!
        #expect(paper.palette(dark: true, spaceHue: 0.1) == paper.dark)
    }

    @Test func spaceTintIsSavedAndSurvivesOlderFiles() throws {
        var state = BrowserState.initial()
        let space = state.activeSpaceID
        #expect(state.activeSpace.tint == .none)
        BrowserReducer.reduce(&state, .setSpaceTint(space, .strong), env: ReducerEnvironment())
        #expect(state.activeSpace.tint == .strong)
        #expect(!BrowserReducer.reduce(&state, .setSpaceTint(SpaceID(), .subtle), env: ReducerEnvironment()).applied)

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state.activeSpace)) as? [String: Any])
        #expect(try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(state.activeSpace)).tint == .strong)
        // Files from before tints have no such field; files from newer builds may hold one we don't know.
        json["tint"] = nil
        #expect(try JSONDecoder().decode(Space.self, from: JSONSerialization.data(withJSONObject: json)).tint == .none)
        json["tint"] = "neon"
        #expect(try JSONDecoder().decode(Space.self, from: JSONSerialization.data(withJSONObject: json)).tint == .none)
    }

    @Test func spaceIconTakesEmojiAndClearsWhenBlank() {
        var state = BrowserState.initial()
        let space = state.activeSpaceID
        BrowserReducer.reduce(&state, .setSpaceIcon(space, " 🧑‍🚀\n"), env: ReducerEnvironment())
        #expect(state.activeSpace.icon == "🧑‍🚀")
        BrowserReducer.reduce(&state, .setSpaceIcon(space, "   "), env: ReducerEnvironment())
        #expect(state.activeSpace.icon == nil)
    }

    @Test func presetsHaveUniqueIDs() {
        #expect(Set(SkyTheme.presets.map(\.id)).count == SkyTheme.presets.count)
        #expect(SkyTheme.presets.first == .standard)
    }

    @Test func themesSaveAsHex() throws {
        let data = try JSONEncoder().encode(SkyTheme.preset("dusk")!)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"#C5B3F2\""))
        #expect(try JSONDecoder().decode(SkyTheme.self, from: data) == SkyTheme.preset("dusk"))
    }

    @Test func spacesAndProfilesKeepTheirLooks() throws {
        var state = BrowserState.initial()
        let space = state.activeSpaceID
        BrowserReducer.reduce(&state, .setSpaceTheme(space, "forest"), env: ReducerEnvironment())
        #expect(state.activeSpace.themeID == "forest")
        BrowserReducer.reduce(&state, .setProfileIcon(.standard, "🧪"), env: ReducerEnvironment())
        BrowserReducer.reduce(&state, .setProfileHue(.standard, 1.25), env: ReducerEnvironment())
        #expect(state.profiles[0].icon == "🧪")
        #expect(state.profiles[0].hue == 0.25)

        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.activeSpace.themeID == "forest")
        #expect(decoded.profiles[0].icon == "🧪")

        // Older files have neither field.
        let old = #"{"id":"s","name":"Old","hue":0.3}"#
        #expect(try JSONDecoder().decode(Space.self, from: Data(old.utf8)).themeID == nil)
        #expect(try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"p","name":"P"}"#.utf8)).icon == nil)
    }

    @Test func everyAsciiThemeHasItsFieldAndInkInBothLooks() {
        let themes = SkyTheme.asciiThemes + SkyTheme.quietThemes
        #expect(SkyTheme.asciiThemes.count == 16 && SkyTheme.quietThemes.count == 10)
        #expect(Set(themes.map { $0.light.ascii?.pattern }).count == AsciiPattern.allCases.count)
        #expect(Set(SkyTheme.presets.map(\.id)).count == SkyTheme.presets.count)
        #expect(Set(SkyTheme.presets.map(\.name)).count == SkyTheme.presets.count)
        for theme in themes {
            #expect(!theme.followsSpace && theme.light.ascii?.pattern == theme.dark.ascii?.pattern)
            for look in [theme.light, theme.dark] {
                #expect(look.ascii != nil && look.image == nil && look.rays == 0)
                #expect(look.text != nil && look.secondaryText != nil && look.selection != nil && look.scrim != nil)
            }
        }
        #expect(SkyTheme.presets == SkyTheme.skies + themes + SkyTheme.pictureThemes)
    }

    @Test func everyPatternFillsTheGlyphAtlas() {
        for pattern in AsciiPattern.allCases { #expect(pattern.glyphs.count == 8) }
    }

    @Test func everyPictureThemeHasItsPicturesInBothLooks() {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Themes")
        #expect(SkyTheme.pictureThemes.count == 9)
        #expect(SkyTheme.pictureThemes.contains { $0.id == SkyTheme.startingID })
        for theme in SkyTheme.pictureThemes {
            for look in [theme.light, theme.dark] {
                #expect(look.image?.builtIn == true && look.rays == 0 && look.text != nil && look.scrim != nil)
                #expect(FileManager.default.fileExists(atPath: folder.appending(path: look.image!.file).path), "\(theme.name)")
                #expect(look.accent.ink.contrast(with: look.accent) >= 4.5, "\(theme.name)")
            }
        }
    }

    @Test func quietThemesStayQuiet() {
        for theme in SkyTheme.quietThemes {
            for look in [theme.light, theme.dark] {
                #expect(look.sky.hsv.s * look.sky.hsv.v < 0.11, "\(theme.name)")
                #expect(look.ascii!.opacity <= 0.3, "\(theme.name)")
            }
        }
    }

    @Test func eachAsciiThemesTextReadsOnItsOwnSky() {
        for theme in SkyTheme.asciiThemes + SkyTheme.quietThemes {
            for look in [theme.light, theme.dark] {
                let ground = look.sky.mixed(with: look.scrim!.color, look.scrim!.opacity)
                #expect(look.text!.contrast(with: ground) >= 4.5, "\(theme.name)")
                #expect(look.accent.ink.contrast(with: look.accent) >= 4.5, "\(theme.name)")
            }
        }
    }

    @Test func aThemeSavedBeforePicturesStillLoads() throws {
        let look = ##"{"sky":"#112233","horizon":"#445566","glow":"#778899","accent":"#AABBCC","sunlight":"#DDEEFF","rays":0.5,"glass":1}"##
        let old = ##"{"id":"mine","name":"Mine","followsSpace":false,"light":\##(look),"dark":\##(look)}"##
        let theme = try JSONDecoder().decode(SkyTheme.self, from: Data(old.utf8))
        #expect(theme.light.image == nil && theme.light.ascii == nil && theme.light.text == nil && theme.light.scrim == nil && theme.basedOn == nil)
    }

    @Test func picturesAndHandSetColorsSurviveFollowingASpace() {
        var theme = SkyTheme.standard
        theme.light.image = ThemeImage(file: "mine.gif", zoom: 1.5, blur: 8)
        theme.light.text = RGB(hex: "#123456")
        theme.light.ascii = AsciiLayer(pattern: .stars, color: RGB(hex: "#FF0000")!, opacity: 0.5)
        let turned = theme.palette(dark: false, spaceHue: 0.1)
        #expect(turned.image == theme.light.image && turned.text == theme.light.text)
        #expect(turned.sky != theme.light.sky && turned.ascii?.color != theme.light.ascii?.color)
        #expect(turned.image?.isAnimated == true)
    }

    @Test func aCopyResetsToWhatItCameFrom() throws {
        var copy = SkyTheme.preset("wildwood")!
        copy.id = "mine"
        copy.name = "My Wildwood"
        copy.basedOn = "wildwood"
        copy.dark.accent = RGB(hex: "#000000")!
        let reset = try #require(copy.reset)
        #expect(reset.dark == SkyTheme.preset("wildwood")!.dark)
        #expect(reset.id == "mine" && reset.name == "My Wildwood" && reset.basedOn == "wildwood")
        #expect(SkyTheme.standard.reset == nil)
    }

    @Test func aPictureGetsColorsThatReadOnIt() {
        let sunset = [RGB](repeating: RGB(hex: "#FF7A2F")!, count: 60) + [RGB](repeating: RGB(hex: "#6A1E8C")!, count: 30)
            + [RGB](repeating: RGB(hex: "#FFF2C0")!, count: 10)
        for dark in [false, true] {
            let look = ThemePalette.suited(to: sunset, dark: dark, image: ThemeImage(file: "sunset.jpg"))
            #expect(look.image?.file == "sunset.jpg" && look.rays == 0)
            let hue = look.accent.hsv.h
            #expect(hue < 0.17, "the accent should come from the picture's orange")
            let scrim = look.scrim!
            for pixel in [RGB(hex: "#FF7A2F")!, RGB(hex: "#6A1E8C")!] {
                #expect(look.text!.contrast(with: pixel.mixed(with: scrim.color, scrim.opacity)) >= 3)
            }
            #expect(look.accent.ink.contrast(with: look.accent) >= 4.5)
        }
    }

    @Test func aGreyPictureGetsAGreyTheme() {
        let look = ThemePalette.suited(to: [RGB(0.4, 0.4, 0.4), RGB(0.6, 0.6, 0.6)], dark: true)
        #expect(look.accent.hsv.s < 0.01 && look.sky.hsv.s < 0.01)
    }

    @Test func noPixelsStillMakesATheme() {
        #expect(ThemePalette.suited(to: [], dark: false).text != nil)
    }

    @Test func aThemeFileRoundTrips() throws {
        var theme = SkyTheme.preset("sakura")!
        theme.light.image = ThemeImage(file: "a.png", zoom: 2)
        let file = ThemeFile(theme: theme, pictures: ["a.png": Data([1, 2, 3])])
        let decoded = try ThemeFile.decoded(from: file.encoded())
        #expect(decoded.theme == theme && decoded.pictures["a.png"] == Data([1, 2, 3]))
    }

    @Test func aThemeFileFromTheFutureIsRefused() throws {
        var json = try JSONSerialization.jsonObject(with: ThemeFile(theme: .standard, pictures: [:]).encoded()) as! [String: Any]
        json["format"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ThemeFile.Problem.newerFormat) { try ThemeFile.decoded(from: data) }
    }

    @Test func anImportedThemeCantReachOutOfRange() {
        var theme = SkyTheme.standard
        theme.id = "sky"
        theme.name = "   "
        theme.basedOn = "nonsense"
        theme.light.rays = .infinity
        theme.light.image = ThemeImage(file: "x.png", zoom: 1000, blur: 1e9, fade: -4)
        theme.dark.image = ThemeImage(file: "../../secret", builtIn: true)
        theme.dark.scrim = ThemeScrim(color: RGB(0, 0, 0), opacity: 7)
        let imported = ThemeFile(theme: theme, pictures: [:]).importedTheme(id: "new")
        #expect(imported.id == "new" && imported.name == "Imported Theme" && imported.basedOn == nil)
        #expect(imported.light.rays == 0)
        #expect(imported.light.image?.zoom == 3 && imported.light.image?.blur == 40 && imported.light.image?.fade == 0)
        #expect(imported.dark.image == nil, "a file can't point at the app's own pictures")
        #expect(imported.dark.scrim?.opacity == 1)
    }
}

@Suite struct LaunchEnvironmentTests {
    @Test func aPublishedBuildIgnoresTheEnvironment() {
        let environment = ["SKYLIGHT_DEBUG_PORT": "9222", "SKYLIGHT_DEV": "1"]
        #expect(AppPaths.launchEnvironment(environment, published: true).isEmpty)
        #expect(AppPaths.launchEnvironment(environment, published: false) == environment)
    }
}
