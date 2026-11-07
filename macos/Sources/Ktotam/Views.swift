import SwiftUI
import AppKit

private let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal, .yellow, .mint, .indigo, .cyan]
func personColor(_ id: Int64?) -> Color {
    guard let id else { return .gray }
    if id == Track.unknown { return .red }
    return palette[Int(id) % palette.count]
}

func fmt(_ d: Float) -> String { d > 8 ? "—" : String(format: "%.2f", d) }

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var tab = 0
    @State private var askName = false
    @State private var newName = ""
    @State private var nameTarget: Target = .none

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                header
                CameraPane()
                LiveStrip(ask: ask)
                EnrollBar()
            }
            .padding(12)
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Люди").tag(0)
                    Text("Проверка").tag(1)
                    Text("Журнал").tag(2)
                    Text("Настройки").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch tab {
                case 0: PeoplePane(ask: ask)
                case 1: ReviewPane(ask: ask)
                case 2: EventsPane()
                default: SettingsPane()
                }
            }
            .padding(12)
            .frame(width: 400)
        }
        .frame(minWidth: 980, minHeight: 640)
        .alert("Кто это?", isPresented: $askName) {
            TextField("Имя", text: $newName)
            Button("Добавить") { m.addPerson(newName, from: nameTarget); newName = "" }
            Button("Отмена", role: .cancel) { newName = "" }
        } message: {
            Text(nameTarget == .none ? "Имя нового человека" : "Снимок сохранится к этому человеку")
        }
    }

    func ask(_ t: Target) { nameTarget = t; newName = ""; askName = true }

    var header: some View {
        HStack {
            Image(systemName: "person.crop.rectangle.stack").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.presentNames.isEmpty ? "Перед компом никого" : "Перед компом: " + m.presentNames.joined(separator: ", "))
                    .font(.headline)
                Text("В базе: \(m.people.count) чел., \(m.people.reduce(0) { $0 + $1.count }) снимков")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !m.status.isEmpty { Text(m.status).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
        }
    }
}

/// Картинка с камеры и рамки лиц с именами.
struct CameraPane: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
            if let f = m.frame {
                Image(decorative: f, scale: 1)
                    .resizable()
                    .scaleEffect(x: m.mirror ? -1 : 1, y: 1)
                    .aspectRatio(CGFloat(f.width) / CGFloat(f.height), contentMode: .fit)
                    .overlay(GeometryReader { g in
                        ForEach(m.faces) { face in box(face, g.size) }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text("Нет картинки с камеры")
                }.foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func rect(_ r: CGRect, _ s: CGSize) -> CGRect {
        let x = m.mirror ? 1 - r.maxX : r.minX
        return CGRect(x: x * s.width, y: (1 - r.maxY) * s.height, width: r.width * s.width, height: r.height * s.height)
    }

    @ViewBuilder func box(_ f: LiveFace, _ s: CGSize) -> some View {
        let r = rect(f.rect, s)
        let c = personColor(f.label)
        let title: String = {
            switch f.label {
            case nil: return "…"
            case Track.unknown?: return "Не знаю" + (f.match.best != nil ? " (≈ \(m.name(f.match.best)))" : "")
            default: return m.name(f.label)
            }
        }()
        RoundedRectangle(cornerRadius: 6).stroke(c, lineWidth: 3)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
        Text("\(title)  \(fmt(f.match.dist))")
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
            .fixedSize()
            .position(x: r.midX, y: max(12, r.minY - 14))
    }
}

/// Кнопки «верно / это другой» для того, кто в кадре.
struct FaceActions: View {
    @EnvironmentObject var m: Model
    var target: Target
    var match: Match
    var ask: (Target) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let b = match.best {
                Button { m.confirm(target) } label: { Label("Да, \(m.name(b))", systemImage: "checkmark") }
                    .help("Сохранить снимок к «\(m.name(b))»")
            }
            Menu {
                ForEach(m.people) { p in
                    Button(p.name) { m.assign(target, to: p.id) }
                }
                if !m.people.isEmpty { Divider() }
                Button("Новый человек…") { ask(target) }
            } label: { Text(match.best == nil ? "Это…" : "Нет, это…") }
            .fixedSize()
        }
        .controlSize(.small)
    }
}

struct Thumb: View {
    var img: CGImage
    var size: CGFloat = 56
    var body: some View {
        Image(decorative: img, scale: 1).resizable().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct LiveStrip: View {
    @EnvironmentObject var m: Model
    var ask: (Target) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if m.faces.isEmpty {
                    Text("Лиц в кадре нет").foregroundStyle(.secondary).padding(.vertical, 22)
                }
                ForEach(m.faces) { f in
                    HStack(spacing: 8) {
                        Thumb(img: f.crop)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(caption(f)).font(.callout.weight(.semibold))
                            Text("расстояние \(fmt(f.match.dist)) · следующий \(fmt(f.match.second))")
                                .font(.caption2).foregroundStyle(.secondary)
                            FaceActions(target: .live(f.id), match: f.match, ask: ask)
                        }
                    }
                    .padding(8)
                    .background(personColor(f.label).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(height: 88)
    }

    func caption(_ f: LiveFace) -> String {
        guard let b = f.match.best else { return "База пуста — кто это?" }
        return f.match.known ? "Думаю, это \(m.name(b))" : "Не уверена… похоже на \(m.name(b))"
    }
}

struct EnrollBar: View {
    @EnvironmentObject var m: Model
    @State private var who: Int64 = 0

    var body: some View {
        HStack {
            if let u = m.enrollUser {
                ProgressView(value: Double(20 - m.enrollLeft), total: 20).frame(width: 160)
                Text("Снимаю «\(m.name(u))»: осталось \(m.enrollLeft). Покрутите головой, подвигайтесь.")
                    .font(.callout)
                Spacer()
                Button("Стоп") { m.stopEnroll() }
            } else {
                Text("Серия снимков:").font(.callout)
                Picker("", selection: $who) {
                    Text("— кто перед камерой —").tag(Int64(0))
                    ForEach(m.people) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 220)
                Button("Снять 20 кадров") { m.startEnroll(who) }.disabled(who == 0)
                Spacer()
            }
        }
    }
}

// MARK: правая панель

struct PeoplePane: View {
    @EnvironmentObject var m: Model
    var ask: (Target) -> Void
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Имя нового человека", text: $newName).onSubmit(add)
                Button("Добавить", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if m.people.isEmpty {
                Text("Пока никого. Добавьте человека, затем «Снять 20 кадров» под камерой — или нажмите «Это… → Новый человек» у лица в кадре.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(m.people) { PersonRow(person: $0) }
                }
            }
        }
    }

    func add() { m.addPerson(newName); newName = "" }
}

struct PersonRow: View {
    @EnvironmentObject var m: Model
    var person: Person
    @State private var open = false
    @State private var name = ""
    @State private var thumbs: [(Int64, CGImage)] = []
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(personColor(person.id)).frame(width: 10, height: 10)
                TextField("Имя", text: $name).textFieldStyle(.plain).font(.headline)
                    .onSubmit { m.rename(person.id, name) }
                Text("\(person.count) фото").font(.caption).foregroundStyle(.secondary)
                Button { m.startEnroll(person.id) } label: { Image(systemName: "camera") }
                    .help("Снять серию из 20 кадров").buttonStyle(.borderless)
                Button { open.toggle(); load() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
            if open {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 4)], spacing: 4) {
                    ForEach(thumbs, id: \.0) { item in
                        Thumb(img: item.1, size: 52)
                            .contextMenu {
                                Button("Удалить снимок", role: .destructive) { m.deleteSample(item.0) }
                                Menu("Перенести к…") {
                                    ForEach(m.people.filter { $0.id != person.id }) { p in
                                        Button(p.name) { m.moveSample(item.0, to: p.id) }
                                    }
                                }
                            }
                    }
                }
                Text("Правый клик по снимку — удалить или перенести к другому человеку.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { name = person.name }
        .onChange(of: m.revision) { name = person.name; if open { load() } }
        .confirmationDialog("Удалить «\(person.name)» и все снимки?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { m.deletePerson(person.id) }
        }
    }

    func load() {
        guard open else { return }
        thumbs = m.store.thumbs(of: person.id).compactMap { id, j in FaceEngine.cgImage(jpeg: j).map { (id, $0) } }
    }
}

struct ReviewPane: View {
    @EnvironmentObject var m: Model
    var ask: (Target) -> Void
    @State private var onlyOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Что думала программа. Подтвердите или поправьте — снимок уйдёт в базу.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Только непроверенные", isOn: $onlyOpen).toggleStyle(.checkbox)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(m.reviews.filter { !onlyOpen || $0.resolved == nil }) { r in
                        HStack(spacing: 8) {
                            Thumb(img: r.crop, size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.match.best == nil ? "Не знала, кто это"
                                     : (r.match.known ? "Думала: \(m.name(r.match.best))" : "Сомневалась: \(m.name(r.match.best))?"))
                                    .font(.callout.weight(.semibold))
                                Text("\(r.time.formatted(date: .omitted, time: .standard)) · \(fmt(r.match.dist))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let s = r.resolved {
                                    Text(s).font(.caption).foregroundStyle(.green)
                                } else {
                                    HStack {
                                        FaceActions(target: .review(r.id), match: r.match, ask: ask)
                                        Button { m.dismiss(r.id) } label: { Image(systemName: "xmark") }
                                            .controlSize(.small).help("Пропустить (плохой снимок)")
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(personColor(r.match.known ? r.match.best : Track.unknown).opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

struct EventsPane: View {
    @EnvironmentObject var m: Model
    var body: some View {
        List(m.events) { e in
            HStack(alignment: .top) {
                Text(e.time.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                Text(e.text)
            }
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Form {
            Section("Узнавание") {
                VStack(alignment: .leading) {
                    Text("Порог «узнал»: \(String(format: "%.2f", m.threshold))")
                    Slider(value: $m.threshold, in: 0.6...1.25, step: 0.01)
                    Text("Меньше — строже (чаще «не знаю»), больше — смелее (чаще путает). Ориентир — число «расстояние» у лица в кадре.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Самообучение: уверенные снимки сами пополняют базу", isOn: $m.autoLearn)
            }
            Section("Приветствие") {
                Toggle("Говорить голосом", isOn: $m.speak)
                Toggle("Здороваться с незнакомцами", isOn: $m.greetUnknown)
                VStack(alignment: .leading) {
                    Text("«Пока» через \(String(format: "%.1f", m.absence)) с отсутствия")
                    Slider(value: $m.absence, in: 1...15)
                }
                Picker("Голос", selection: $m.voiceId) {
                    Text("Авто (русский)").tag("")
                    ForEach(Speaker.russianVoices(), id: \.identifier) { v in
                        Text("\(v.name)\(v.quality == .enhanced ? " (улучш.)" : v.quality == .premium ? " (премиум)" : "")")
                            .tag(v.identifier)
                    }
                }
                Button("Проверить голос") { m.speaker.say("Привет, \(m.people.first?.name ?? "друг")!") }
            }
            Section("Камера") {
                Picker("Камера", selection: $m.cameraId) {
                    Text("Встроенная").tag("")
                    ForEach(Camera.devices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Toggle("Зеркалить картинку", isOn: $m.mirror)
            }
            Section("База") {
                Text(m.store.path).font(.caption2).textSelection(.enabled)
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.store.path)])
                }
            }
        }
        .formStyle(.grouped)
    }
}
