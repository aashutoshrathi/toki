import Foundation

let tokiLogoLines: [String] = [
    "            @@@@ @@@@            ",
    "   @@@@@@@@@@@     @@@@@@@       ",
    "   @@@@@@@@@@@     @@@@@@@       ",
    "            @@@@@@@@@            ",
    "              @@@@@              ",
    "               @@@               ",
    "               @@@    @@@        ",
    "               @@@   @@@@        ",
    "               @@@@@@@@@         ",
    "               @@@@@@@           ",
    "               @@@@@              ",
    "               @@@@               ",
    "               @@@@@              ",
    "                @@@@@@@@@@",
]

let tokiBannerLines: [String] = [
    "/toki",
    "v\(appVersion)",
    "github.com/aashutoshrathi/toki",
]

var tokiBannerString: String {
    let logoWidth = tokiLogoLines.map(\.count).max() ?? 0
    let gap = "  "
    let verticalOffset = 5
    let maxLines = max(tokiLogoLines.count, tokiBannerLines.count + verticalOffset)
    var result = ""
    for i in 0..<maxLines {
        let logoPart: String
        if i < tokiLogoLines.count {
            logoPart = tokiLogoLines[i].padding(toLength: logoWidth, withPad: " ", startingAt: 0)
        } else {
            logoPart = String(repeating: " ", count: logoWidth)
        }
        let bannerIndex = i - verticalOffset
        if bannerIndex >= 0, bannerIndex < tokiBannerLines.count {
            result += logoPart + gap + tokiBannerLines[bannerIndex] + "\n"
        } else {
            result += logoPart + "\n"
        }
    }
    result += "\n"
    return result
}

func printTokiBanner() {
    print(tokiBannerString, terminator: "")
}
