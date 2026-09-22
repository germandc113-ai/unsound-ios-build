import SwiftUI

struct GreetingView: View {
    @Binding var portalProgress: CGFloat
    var onEnter: () -> Void

    @State private var isEntering = false
    @State private var eyeOpen: CGFloat = 0
    @State private var creditOpacity: Double = 0
    @State private var hintOpacity: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = proxy.size.width
            let fullHeight = proxy.size.height
            let startDiameter: CGFloat = 62
            let pupilOffset: CGFloat = -34
            let finishDiameter = hypot(fullWidth, fullHeight) * 1.26 + abs(pupilOffset) * 2
            let aperture = startDiameter + (finishDiameter - startDiameter) * portalProgress

            ZStack {
                // This entire foreground is cut open at the pupil. The REAL Home
                // screen lives underneath in RootView, so there is no fake screen
                // swap during the transition.
                ZStack {
                    Color.black.ignoresSafeArea()

                    RadialGradient(
                        colors: [USTheme.accentDeep.opacity(isEntering ? 0.24 : 0.07), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: 380
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 17) {
                        ZStack {
                            // Keep the existing eye artwork unchanged. Only its
                            // eyelid reveal and the pupil aperture animate.
                            PunkEyeLogo(entering: isEntering)
                                .frame(width: 250, height: 142)
                                .mask(alignment: .center) {
                                    Rectangle()
                                        .frame(width: 270, height: max(0.5, 142 * eyeOpen))
                                }
                                .opacity(eyeOpen)

                            ClosedEyeLineShape()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.92), .white.opacity(0.46)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: 230, height: 54)
                                .opacity(1 - eyeOpen)
                                .shadow(color: .white.opacity(0.08), radius: 5)
                        }
                        .frame(width: 250, height: 142)

                        Text("PRESENTED BY UNSEEN / ADRIAN")
                            .font(.system(size: 17, weight: .black, design: .default))
                            .fontWidth(.condensed)
                            .tracking(1.35)
                            .foregroundStyle(.white)
                            .opacity(creditOpacity)

                        Text("TAP TO OPEN")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(3.0)
                            .foregroundStyle(.white.opacity(0.30))
                            .opacity(hintOpacity * (1 - Double(min(1, portalProgress * 2.3))))
                    }
                    .offset(y: pupilOffset)

                    // Cut the pupil open after the eye has opened. At first the
                    // whole Home interface is visible inside the pupil. The hole
                    // then grows until Home literally becomes the entire screen.
                    if isEntering {
                        Circle()
                            .frame(width: aperture, height: aperture)
                            .offset(y: pupilOffset)
                            .blendMode(.destinationOut)
                            .shadow(color: .white.opacity(0.16 * Double(1 - portalProgress)), radius: 12)
                    }
                }
                .compositingGroup()

                // Small glass rim around the aperture while it is still inside
                // the eye. It disappears before Home fills the display.
                if isEntering && portalProgress < 0.58 {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.06),
                                    USTheme.accent.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2 + 1.8 * (1 - portalProgress)
                        )
                        .frame(width: aperture, height: aperture)
                        .offset(y: pupilOffset)
                        .shadow(color: USTheme.accent.opacity(0.22), radius: 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .onAppear {
            portalProgress = 0
            withAnimation(.easeOut(duration: 0.34)) { creditOpacity = 1 }
            withAnimation(.easeOut(duration: 0.44).delay(0.12)) { hintOpacity = 1 }
        }
        .onTapGesture { enter() }
        .sensoryFeedback(.impact(weight: .medium), trigger: isEntering)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open UnSound")
    }

    private func enter() {
        guard !isEntering else { return }
        isEntering = true

        // 1. The eye opens first. Home is not swapped in afterwards; it is
        // already underneath and becomes visible through the pupil.
        withAnimation(.spring(response: 0.31, dampingFraction: 0.76)) {
            eyeOpen = 1
            hintOpacity = 0
        }

        // 2. Briefly show the complete Home interface inside the open pupil.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            portalProgress = 0.015
        }

        // 3. Camera-like zoom through the eye: the real Home interface and the
        // aperture grow together until Home covers the complete display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.47) {
            withAnimation(.easeInOut(duration: 0.98)) {
                portalProgress = 1
            }
        }

        // 4. Remove the splash only after the real Home screen is already full size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.50) {
            onEnter()
        }
    }
}

private struct PunkEyeLogo: View {
    let entering: Bool

    var body: some View {
        ZStack {
            EyeOutlineShape()
                .stroke(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.64)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: 108, height: 108)

            Circle()
                .fill(Color.black)
                .frame(width: 84, height: 84)
                .overlay(Circle().stroke(USTheme.accent, lineWidth: 7))
                .shadow(color: USTheme.accent.opacity(0.76), radius: entering ? 24 : 12)

            ZStack {
                Text("UN").offset(x: -12, y: -4)
                Text("SEEN").offset(x: 9, y: 8)
            }
            .font(.system(size: 13, weight: .black, design: .default))
            .fontWidth(.condensed)
            .italic()
            .foregroundStyle(.white)
            .rotationEffect(.degrees(-7))

            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .offset(x: 16, y: -18)
                .shadow(color: .white.opacity(0.9), radius: 5)
        }
        .drawingGroup()
    }
}

private struct EyeOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = CGPoint(x: rect.minX + rect.width * 0.055, y: rect.midY)
        let right = CGPoint(x: rect.maxX - rect.width * 0.055, y: rect.midY)

        path.move(to: left)
        path.addCurve(
            to: right,
            control1: CGPoint(x: rect.minX + rect.width * 0.29, y: rect.minY + rect.height * 0.02),
            control2: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.07)
        )
        path.addCurve(
            to: left,
            control1: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.maxY - rect.height * 0.01),
            control2: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.08)
        )
        return path
    }
}

private struct ClosedEyeLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.midY - 2))
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.midY - 2),
            control1: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.midY + rect.height * 0.20),
            control2: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.midY + rect.height * 0.20)
        )
        return path
    }
}
