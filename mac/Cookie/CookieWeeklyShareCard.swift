import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private struct CookieWeeklyPNG: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in item.data }
    }
}

enum CookieWeeklyCardPresentation {
    static let compactHeight: CGFloat = 42
    static let expandedHeight: CGFloat = 82

    static func isCompact(availableHeight: CGFloat) -> Bool {
        availableHeight < 620
    }
}

struct CookieWeeklyShareCard: View {
    let summary: CookieWeeklySummary
    var compact = false
    @State private var shareImage: CookieWeeklyPNG?
    @State private var shareError: String?

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 9) {
                    Eyebrow("Your week")
                    Text("\(summary.words.formatted()) words · \(summary.dictations) dictations · \(summary.activeDays) days")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    shareControl
                }
            } else {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("Your week")
                        Text("\(summary.words.formatted()) words spoken")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(summary.dictations) dictations · \(summary.activeDays) active days")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    shareControl
                }
            }
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: summary) { prepareShareImage() }
    }

    @ViewBuilder private var shareControl: some View {
        if let shareImage {
            ShareLink(item: shareImage, preview: SharePreview("Your week with Cookie")) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SecondaryButton())
            .accessibilityLabel("Share your weekly Cookie dictation card")
        } else if let shareError {
            Text(shareError).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("Preparing share card")
        }
    }

    @MainActor private func prepareShareImage() {
        let renderer = ImageRenderer(content: CookieWeeklyArtwork(summary: summary))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            shareError = "Couldn't prepare the card."
            return
        }
        shareImage = CookieWeeklyPNG(data: data)
    }
}

private struct CookieWeeklyArtwork: View {
    let summary: CookieWeeklySummary

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.04, green: 0.05, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Theme.accent.opacity(0.23)).frame(width: 430, height: 430).blur(radius: 90)
                .offset(x: 770, y: -220)
            VStack(alignment: .leading, spacing: 34) {
                HStack(spacing: 12) {
                    CookieAvatar(size: 38)
                    Text("COOKIE · YOUR WEEK").font(.system(size: 18, weight: .semibold)).tracking(1.6)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Text("\(summary.words.formatted()) words\nspoken, naturally.")
                    .font(.system(size: 62, weight: .semibold, design: .rounded)).tracking(-2.8)
                    .foregroundStyle(.white).lineSpacing(-4)
                HStack(spacing: 34) {
                    statistic("DICTATIONS", summary.dictations.formatted())
                    statistic("ACTIVE DAYS", summary.activeDays.formatted())
                    if let pace = summary.averageWordsPerMinute { statistic("WORDS / MIN", pace.formatted()) }
                }
                Text("Week of \(summary.weekStarting.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(64)
        }
        .frame(width: 1200, height: 630)
        .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(label).font(.system(size: 12, weight: .semibold)).tracking(1.1).foregroundStyle(.white.opacity(0.48))
        }
    }
}
