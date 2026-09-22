import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"
    case russian = "ru"

    static let storageKey = "unsound.app.language"

    var id: String { rawValue }

    // Intentionally always shown in English in the language picker.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .russian: return "Russian"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

enum AppLocalization {
    // Feature strings added after the first localization bundle shipped. Keeping
    // these here lets the draft stay fully translated without replacing the
    // existing, much larger Localizable.strings files.
    private static let featureTranslations: [AppLanguage: [String: String]] = [
        .german: [
            "DOWNLOAD SONGS": "SONGS HERUNTERLADEN",
            "DOWNLOAD ALL FILES": "ALLE DATEIEN HERUNTERLADEN",
            "DOWNLOAD CERTAIN FILES": "BESTIMMTE DATEIEN HERUNTERLADEN",
            "Imported MP3s upload automatically. Download them here at any time, even when the other iPhone is offline.": "Importierte MP3s werden automatisch hochgeladen. Du kannst sie hier jederzeit laden, auch wenn das andere iPhone offline ist.",
            "New imports upload automatically": "Neue Importe werden automatisch hochgeladen",
            "Downloads remain available while the other phone is offline": "Downloads bleiben verfügbar, wenn das andere Handy offline ist",
            "Choose every file or search and select individual songs": "Alle Dateien wählen oder einzelne Songs suchen und auswählen",
            "Search title, artist or filename": "Titel, Künstler oder Dateiname suchen",
            "Download": "Herunterladen",
            "Cancel": "Abbrechen",
            "SKIP": "ÜBERSPRINGEN",
            "SKIP ALL": "ALLE ÜBERSPRINGEN",
            "SAVE": "SPEICHERN",
            "CONNECT IPHONES": "IPHONES VERBINDEN",
            "Create a short code on one iPhone. Enter it on the other iPhone once — no links or server addresses.": "Erstelle auf einem iPhone einen kurzen Code. Gib ihn einmal auf dem anderen iPhone ein – ohne Links oder Serveradressen.",
            "GENERATE A CODE": "CODE ERSTELLEN",
            "Enter code": "Code eingeben",
            "APPLY": "ANWENDEN",
            "START LISTENING PARTY": "LISTENING PARTY STARTEN",
            "LEAVE LISTENING PARTY": "LISTENING PARTY VERLASSEN",
            "TAKE OVER LISTENING PARTY": "LISTENING PARTY ÜBERNEHMEN",
            "Last sync": "Letzter Sync",
            "Cloud connected": "Cloud verbunden",
            "Cloud not configured": "Cloud nicht eingerichtet",
            "Cloud empty": "Cloud ist leer",
            "Cloud unavailable": "Cloud nicht verfügbar",
            "Imported songs upload automatically.": "Importierte Songs werden automatisch hochgeladen.",
            "Songs are available even when the other iPhone is offline.": "Songs sind verfügbar, auch wenn das andere iPhone offline ist.",
            "Checking new imports…": "Neue Importe werden geprüft …",
            "Connection code ready": "Verbindungscode bereit",
            "Connected": "Verbunden",
            "Connection failed": "Verbindung fehlgeschlagen",
            "Listening Party live": "Listening Party läuft",
            "Listening Party ended": "Listening Party beendet"
        ],
        .russian: [
            "DOWNLOAD SONGS": "СКАЧАТЬ ТРЕКИ",
            "DOWNLOAD ALL FILES": "СКАЧАТЬ ВСЕ ФАЙЛЫ",
            "DOWNLOAD CERTAIN FILES": "СКАЧАТЬ ВЫБРАННЫЕ ФАЙЛЫ",
            "Imported MP3s upload automatically. Download them here at any time, even when the other iPhone is offline.": "Импортированные MP3 загружаются автоматически. Скачивайте их здесь в любое время, даже если другой iPhone не в сети.",
            "New imports upload automatically": "Новые импорты загружаются автоматически",
            "Downloads remain available while the other phone is offline": "Скачивание доступно, даже когда другой телефон не в сети",
            "Choose every file or search and select individual songs": "Выберите все файлы или найдите отдельные треки",
            "Search title, artist or filename": "Поиск по названию, исполнителю или файлу",
            "Download": "Скачать",
            "Cancel": "Отмена",
            "SKIP": "ПРОПУСТИТЬ",
            "SKIP ALL": "ПРОПУСТИТЬ ВСЕ",
            "SAVE": "СОХРАНИТЬ",
            "CONNECT IPHONES": "ПОДКЛЮЧИТЬ IPHONE",
            "Create a short code on one iPhone. Enter it on the other iPhone once — no links or server addresses.": "Создайте короткий код на одном iPhone и один раз введите его на другом — без ссылок и адресов сервера.",
            "GENERATE A CODE": "СОЗДАТЬ КОД",
            "Enter code": "Введите код",
            "APPLY": "ПРИМЕНИТЬ",
            "START LISTENING PARTY": "НАЧАТЬ LISTENING PARTY",
            "LEAVE LISTENING PARTY": "ПОКИНУТЬ LISTENING PARTY",
            "TAKE OVER LISTENING PARTY": "ПРИНЯТЬ УПРАВЛЕНИЕ",
            "Last sync": "Последняя синхронизация",
            "Cloud connected": "Облако подключено",
            "Cloud not configured": "Облако не настроено",
            "Cloud empty": "Облако пусто",
            "Cloud unavailable": "Облако недоступно",
            "Imported songs upload automatically.": "Импортированные треки загружаются автоматически.",
            "Songs are available even when the other iPhone is offline.": "Треки доступны, даже когда другой iPhone не в сети.",
            "Checking new imports…": "Проверка новых импортов…",
            "Connection code ready": "Код подключения готов",
            "Connected": "Подключено",
            "Connection failed": "Ошибка подключения",
            "Listening Party live": "Listening Party запущена",
            "Listening Party ended": "Listening Party завершена"
        ]
    ]

    static var language: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: AppLanguage.storageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .english
        }
        return language
    }

    static func text(_ key: String) -> String {
        if let translated = featureTranslations[language]?[key] {
            return translated
        }
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
