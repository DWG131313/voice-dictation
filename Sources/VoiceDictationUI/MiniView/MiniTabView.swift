import AppKit
import SwiftUI
import VoiceDictationLib

/// The mini view's tab: its mark, and under it, 8 pt apart, the time, the
/// clipboard and a word turned to read top to bottom, as `MiniTabFace` has
/// them. Black, a 1 pt hairline, square corners. The mark is the mini view's
/// only colour (DESIGN.md `mini-tab`).
struct MiniTabView: View {
    static let markSize = CGSize(width: 26, height: 18)

    let face: MiniTabFace
    /// The live line, drawn only for `.liveSpectrum`.
    let line: LevelLine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            mark
                .frame(width: Self.markSize.width, height: Self.markSize.height)
                .accessibilityHidden(true)
            if let time = face.time {
                Text(time)
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(face.timeIsMuted ? Theme.Color.textMuted : Theme.Color.text)
            }
            if face.showsClipboard {
                ClipboardMark()
                    .foregroundStyle(Theme.Color.text)
            }
            if let word = face.word {
                TurnedQuarter {
                    Text(word)
                        .font(Theme.Font.ui(9, medium: true))
                        .tracking(0.8)
                        .foregroundStyle(face.wordIsMuted ? Theme.Color.textMuted : Theme.Color.text)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                }
            }
        }
        .padding(.vertical, 12)
        .frame(width: MiniViewLayout.tabWidth)
        // The tab keeps its tallest face's height; a shorter face sits at the top.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.bg)
        .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
    }

    @ViewBuilder private var mark: some View {
        switch face.mark {
        case .restLine:
            Canvas { context, _ in
                context.stroke(Self.flatLine, with: .color(Theme.Color.text), lineWidth: 1)
            }
        case .liveSpectrum:
            // The pill's line at the tab's size, drawn every frame at the
            // present on the clock the slices are timed by (Task 24A); flat,
            // still in colour, with Reduce Motion on.
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                Canvas { context, size in
                    let path = reduceMotion ? Self.flatLine : Path { $0.addLines(line.points(at: now)) }
                    // The first and last vertices lie just outside the canvas.
                    context.clip(to: Path(CGRect(origin: .zero, size: size)))
                    context.stroke(path, with: Self.spectrum,
                                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .miter, miterLimit: 4))
                }
            }
        case .flatSpectrum:
            Canvas { context, _ in
                context.stroke(Self.flatLine, with: Self.spectrum, lineWidth: 1.5)
            }
        case .split:
            // A white line to the middle, then six rays, red at the top to violet.
            Canvas { context, _ in
                let middle = CGPoint(x: 12, y: Self.markSize.height / 2)
                context.stroke(Path { $0.addLines([CGPoint(x: 0, y: middle.y), middle]) },
                               with: .color(Theme.Color.text), lineWidth: 1)
                for (y, colour) in zip(Self.rayEnds, Theme.Color.spectrumStops) {
                    context.stroke(Path { $0.addLines([middle, CGPoint(x: Self.markSize.width, y: y)]) },
                                   with: .color(colour), lineWidth: 1)
                }
            }
        }
    }

    /// Across the mark at its middle, y 9.
    private static let flatLine = Path {
        $0.addLines([CGPoint(x: 0, y: markSize.height / 2), CGPoint(x: markSize.width, y: markSize.height / 2)])
    }

    /// Where the split's rays meet the right edge, top to bottom.
    private static let rayEnds: [CGFloat] = [3, 5.4, 7.8, 10.2, 12.6, 15]

    /// The spectrum, red to violet across the mark and fixed in place, so the
    /// moving line travels through the colours, as on the app icon.
    private static var spectrum: GraphicsContext.Shading {
        .linearGradient(Gradient(colors: Theme.Color.spectrumStops),
                        startPoint: .zero, endPoint: CGPoint(x: markSize.width, y: 0))
    }

    /// The tab's height: its tallest face's, measured as the indicator
    /// measures its size, so the tab keeps one height in every state. Measure
    /// once the app has registered its fonts.
    static func height() -> CGFloat {
        let now = Date()
        let here = WindowIdentity(pid: 0, token: 0)
        let working: [DictationState] = [.recording(since: now), .transcribing]
        let ended: [DictationOutcome.Status] = [.pasted, .copied, .failed]
        let faces = working.map { MiniTab.face(work: $0, result: nil, window: here, now: now) }
            + ended.map { status in
                MiniTab.face(work: .idle, result: MiniTabResult(status: status, dictated: now, arrived: now, window: here),
                             window: here, now: now)
            }
        let tallest = faces.map { NSHostingView(rootView: MiniTabView(face: $0, line: LevelLine(.tab))).fittingSize.height }
        return (tallest.max() ?? 0).rounded(.up)
    }
}

/// What the tab shows at each moment: the face for the work under way, the
/// last result and the window it sits on. While recording it is drawn again
/// on each whole second after the recording started, so the clock ticks;
/// otherwise as of `now`, and `MiniViewController` draws it again when a word
/// goes stale.
struct MiniTabContent: View {
    var work: DictationState = .idle
    var result: MiniTabResult?
    var window: WindowIdentity?
    var line = LevelLine(.tab)
    var now = Date()

    var body: some View {
        if case .recording(let since) = work {
            TimelineView(.periodic(from: since, by: 1)) { timeline in
                MiniTabView(face: face(at: timeline.date), line: line)
            }
        } else {
            MiniTabView(face: face(at: now), line: line)
        }
    }

    private func face(at date: Date) -> MiniTabFace {
        MiniTab.face(work: work, result: result, window: window, now: date)
    }
}

/// The clipboard, 12 by 15 pt: a 1 pt outline board with its clip and a
/// tick, in the foreground style. The board's top stops at the clip, so it
/// needs no fill and sits on any background.
struct ClipboardMark: View {
    var body: some View {
        Canvas { context, _ in
            let board = Path {
                $0.addLines([CGPoint(x: 3.5, y: 2.5), CGPoint(x: 0.5, y: 2.5), CGPoint(x: 0.5, y: 14.5),
                             CGPoint(x: 11.5, y: 14.5), CGPoint(x: 11.5, y: 2.5), CGPoint(x: 8.5, y: 2.5)])
            }
            let clip = Path(CGRect(x: 3.5, y: 0.5, width: 5, height: 3.5))
            let tick = Path { $0.addLines([CGPoint(x: 3, y: 9), CGPoint(x: 5.2, y: 11.2), CGPoint(x: 9, y: 7)]) }
            for part in [board, clip, tick] {
                context.stroke(part, with: .foreground, lineWidth: 1)
            }
        }
        .frame(width: 12, height: 15)
        .accessibilityHidden(true)
    }
}

/// Lays its one subview out turned a quarter: as wide as the subview is
/// tall and as tall as it is wide. The subview turns itself
/// (`rotationEffect`), which moves nothing in layout.
private struct TurnedQuarter: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}
