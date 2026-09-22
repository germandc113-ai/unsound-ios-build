import SwiftUI

/// Instagram-style five-page rail. RootView currently places this at the top.
/// Tapping selects a page; holding and gliding across the rail continuously
/// moves between pages, while the parent TabView still supports normal swipes.
struct BottomNavigationView: View {
    @Binding var page: Int

    private let items: [(String, String)] = [
        ("Search", "magnifyingglass"),
        ("Playlists", "music.note.list"),
        ("Home", "house.fill"),
        ("Replay", "chart.bar.fill"),
        ("Settings", "gearshape.fill")
    ]

    @State private var touching = false

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = max(1, proxy.size.width / CGFloat(items.count))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.20))
                    .usGlass(Capsule(), tint: Color.white.opacity(touching ? 0.025 : 0.012))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )

                Capsule()
                    .fill(Color.white.opacity(touching ? 0.13 : 0.085))
                    .frame(width: itemWidth - 7, height: 44)
                    .usGlass(Capsule(), tint: page == 2 ? Color.white.opacity(0.035) : USTheme.accent.opacity(0.065))
                    .overlay(alignment: .topLeading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: max(20, (itemWidth - 7) * 0.44), height: 4)
                            .blur(radius: 2.3)
                            .offset(x: 9, y: 5)
                    }
                    .offset(x: CGFloat(page) * itemWidth + 3.5)
                    .animation(.snappy(duration: 0.18), value: page)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button {
                            page = index
                        } label: {
                            Image(systemName: item.1)
                                .font(.system(size: index == 2 ? 19 : 17, weight: .bold))
                                .foregroundStyle(page == index ? .white : .white.opacity(0.42))
                                .frame(width: itemWidth, height: 50)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(AppLocalization.text(item.0)))
                    }
                }
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        touching = true
                        let x = min(max(0, value.location.x), proxy.size.width - 0.001)
                        let index = min(items.count - 1, max(0, Int(floor(x / itemWidth))))
                        if index != page {
                            page = index
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.16)) { touching = false }
                    }
            )
            .sensoryFeedback(.selection, trigger: page)
        }
        .frame(height: 51)
        .accessibilityElement(children: .contain)
    }
}
