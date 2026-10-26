import Foundation

public struct ManualUpdateSource: Sendable {
    public let url: URL
    public let note: String
    public static func forBundle(_ bundle: String) -> Self? {
        switch bundle {
        case "net.battle.app":
            return .init(url: URL(string: "https://www.battle.net/")!, note: "Battle.net 启动器版本与公开安装器版本不同，请使用应用内更新；未确认是否有更新。")
        case "com.electron.lark":
            return .init(url: URL(string: "https://www.feishu.cn/download")!, note: "此安装可能使用浏览器内核版本或不同产品渠道，无法可靠比较公开版本。请使用应用内更新；未确认是否有更新。")
        default: return nil
        }
    }
}
