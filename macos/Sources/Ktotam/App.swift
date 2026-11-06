import SwiftUI
import AppKit

/// Аргументы запуска:
///   --selftest [папка]       логика + (если дана папка «человек/фото») точность узнавания, без окна
///   --fake-camera <папка>    вместо камеры — фото из папки по кругу
///   --db <файл>              другая база (для тестов)
///   --import <папка>         добавить в базу фото: папка/Имя/*.jpg (вложенные папки тоже)
///   --mute                   не говорить вслух (события печатаются в консоль)
///   --snapshot <png> <сек>   снимок окна через N секунд и выход
enum Args {
    static let all = CommandLine.arguments
    static func value(_ k: String) -> String? {
        guard let i = all.firstIndex(of: k), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    static func has(_ k: String) -> Bool { all.contains(k) }
}

@main
struct Main {
    static func main() {
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        if let dir = Args.value("--import") {
            exit(SelfTest.importFolder(dir, db: Args.value("--db") ?? Store.defaultPath) ? 0 : 1)
        }
        if Args.has("--selftest") {
            let dir = Args.value("--selftest").flatMap { $0.hasPrefix("--") ? nil : $0 }
            exit(SelfTest.run(dir) ? 0 : 1)
        }
        KtotamApp.main()
    }
}

struct KtotamApp: App {
    @StateObject private var model = Model(dbPath: Args.value("--db") ?? Store.defaultPath,
                                           fakeFolder: Args.value("--fake-camera").map { URL(fileURLWithPath: $0) })
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Кто там") {
            ContentView().environmentObject(model)
                .onAppear { Snapshot.schedule(); TestScript.run(model) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

enum Snapshot {
    /// Своё окно можно снять без разрешения на запись экрана. Функция помечена устаревшей — берём через dlsym.
    static func windowImage(_ id: Int) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        let f = unsafeBitCast(sym, to: Fn.self)
        return f(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(id),
                 CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
    }

    static func schedule() {
        guard let path = Args.value("--snapshot") else { return }
        let secs = Double(Args.value(path) ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            if let w = NSApp.windows.first(where: { $0.isVisible }), let cg = windowImage(w.windowNumber) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot:", path)
            } else if let w = NSApp.windows.first(where: { $0.isVisible }), let v = w.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot:", path)
            }
            NSApp.terminate(nil)
        }
    }
}

/// `--test-fix <имя>`: через 3 с поправить лицо в кадре на этого человека (проверка сценария поправки).
@MainActor enum TestScript {
    static func run(_ m: Model) {
        guard let who = Args.value("--test-fix") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let f = m.faces.first, let p = m.people.first(where: { $0.name == who }) else { print("тест: нет лица"); return }
            print("тест: было «\(m.name(f.label))», поправляю на «\(who)»")
            m.assign(.live(f.id), to: p.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("тест: теперь «\(m.faces.map { m.name($0.label) }.joined(separator: ","))», перед компом: \(m.presentNames)")
            }
        }
    }
}
