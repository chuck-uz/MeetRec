// Проверка обновлений через GitHub Releases. Ничего не устанавливает сам —
// предлагает открыть страницу релиза, где лежит свежий DMG.
import Foundation

struct AppRelease {
    let version: String   // «1.10»
    let pageURL: URL
}

enum UpdateChecker {
    static let repo = "chuck-uz/MeetRec"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func latestRelease() async -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct GH: Decodable { let tag_name: String; let html_url: String }
        guard let gh = try? JSONDecoder().decode(GH.self, from: data),
              let page = URL(string: gh.html_url) else { return nil }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return AppRelease(version: version, pageURL: page)
    }

    /// true, если версия `a` новее `b` (сравнение по числовым компонентам: 1.10 > 1.9).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
