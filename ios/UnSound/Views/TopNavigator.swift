import SwiftUI

struct TopNavigator: View {
    @Binding var page: Int

    private let labels = ["Search", "Home", "Playlists", "Settings"]
    private let icons = ["magnifyingglass", "waveform", "music.note.list", "gearshape.fill"]

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = max(1, proxy.size.width)
            let settingsWidth: CGFloat = 48
            let mainWidth = max(1, (totalWidth - settingsWidth) / 3)
            let selectedWidth = page == 3 ? settingsWidth - 6 : mainWidth - 6
            let selectedOffset = page == 3
                ? mainWidth * 3 + 3
                : CGFloat(page) * mainWidth + 3

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.16))
                    .usGlass(Capsule(), tint: Color.black.opacity(0.20))

                Capsule()
                    .fill(Color.white.opacity(0.075))
                    .frame(width: selectedWidth, height: 43)
                    .usGlass(
                        Capsule(),
                        tint: page == 1 ? Color.white.opacity(0.025) : USTheme.accent.opacity(0.07)
                    )
                    .overlay(alignment: .topLeading) {
                        Capsule()
                            .fill(Color.white.opacity(0.11))
                            .frame(width: max(22, selectedWidth * 0.42), height: 5)
                            .blur(radius: 3)
                            .offset(x: 9, y: 5)
                    }
                    .offset(x: selectedOffset)
                    .animation(.spring(response: 0.30, dampingFraction: 0.78), value: page)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Button {
                            select(index)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: icons[index])
                                    .font(.system(size: 11, weight: .bold))
                                Text(AppLocalization.text(labels[index]))
                                    .font(.system(size: 11, weight: page == index ? .bold : .semibold, design: .rounded))
                            }
                            .foregroundStyle(page == index ? .white : .white.opacity(0.44))
                            .frame(width: mainWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        select(3)
                    } label: {
                        Image(systemName: icons[3])
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(page == 3 ? .white : .white.opacity(0.44))
                            .frame(width: settingsWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalization.text("Settings")))
                }
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 22, coordinateSpace: .local)
                    .onEnded { value in
                        let horizontal = value.predictedEndTranslation.width
                        let vertical = value.predictedEndTranslation.height
                        guard abs(horizontal) > abs(vertical) * 1.25,
                              abs(horizontal) > 48 else { return }

                        if horizontal < 0 {
                            select(min(labels.count - 1, page + 1))
                        } else {
                            select(max(0, page - 1))
                        }
                    }
            )
            .sensoryFeedback(.selection, trigger: page)
        }
        .frame(height: 49)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppLocalization.text("Main pages")))
        .accessibilityValue(AppLocalization.text(labels[min(labels.count - 1, max(0, page))]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                select(min(labels.count - 1, page + 1))
            case .decrement:
                select(max(0, page - 1))
            @unknown default:
                break
            }
        }
    }

    private func select(_ index: Int) {
        guard index != page else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            page = index
        }
    }
}
