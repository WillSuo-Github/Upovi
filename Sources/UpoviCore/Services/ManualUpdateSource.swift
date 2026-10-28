import Foundation

public struct ManualUpdateSource: Sendable {
    public let url: URL
    public let note: String
    public static func forBundle(_ bundle: String) -> Self? {
        switch bundle {
        case "dev.appbinnacle.AppBinnacle":
            return .init(url: URL(string: "https://github.com/WillSuo-Github/AppBinnacle/releases")!, note: String(localized: "此安装没有内置公开更新源，请查看开发者发布页；未确认是否有更新。"))
        case "com.ws.youtube-music":
            return .init(url: URL(string: "https://apps.apple.com/app/id6482353962")!, note: String(localized: "此安装未识别到 App Store 凭据，开发者提供商店版本。请使用官方商店检查，不自动替换不同渠道的应用。"))
        case "net.battle.app":
            return .init(url: URL(string: "https://www.battle.net/")!, note: String(localized: "Battle.net 启动器版本与公开安装器版本不同，请使用应用内更新；未确认是否有更新。"))
        case "com.electron.lark":
            return .init(url: URL(string: "https://www.feishu.cn/download")!, note: String(localized: "此安装可能使用浏览器内核版本或不同产品渠道，无法可靠比较公开版本。请使用应用内更新；未确认是否有更新。"))
        default: return nil
        }
    }
}
