import SwiftUI
import UIKit
import AVKit

struct MessageRow: View {
    @EnvironmentObject var theme: HarnessTheme
    let m: ChatMessage
    var onSuggest: ((String) -> Void)? = nil
    @State private var videoURL: URL?

    var body: some View {
        if m.role == .user {
            HStack(alignment: .bottom) {
                Spacer(minLength: 48)
                Text(m.text.isEmpty ? " " : m.text)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.bubbleUser, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !m.text.isEmpty || !m.streaming {
                    Text(m.text)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                }
                if m.streaming && m.text.isEmpty {
                    running
                } else if m.streaming {
                    Circle().fill(theme.blue).frame(width: 6, height: 6).modifier(PulseModifier())
                }
                if !m.images.isEmpty { images }
                if let v = m.videoURL { videoChip(v) }
                if !m.suggestions.isEmpty && !m.streaming { suggestions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 运行中鲸鱼 + 蓝色 pending 点脉冲（规格 §8.3）
    private var running: some View {
        HStack(spacing: 8) {
            Image("running_whale")
                .resizable().scaledToFit().frame(width: 24, height: 24)
            Circle()
                .fill(theme.blue)
                .frame(width: 6, height: 6)
                .opacity(0.35)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                        // 触发脉冲
                    }
                }
                .modifier(PulseModifier())
            Text("思考中…")
                .font(.system(size: 12))
                .foregroundStyle(theme.labelTertiary)
        }
    }

    private var images: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(m.images, id: \.self) { url in
                AsyncImage(url: URL(string: url)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.06))
                        ProgressView()
                    }
                }
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture {
                    if let u = URL(string: url) { UIApplication.shared.open(u) }
                }
            }
        }
    }

    private func videoChip(_ url: String) -> some View {
        Button {
            videoURL = URL(string: url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.blue)
                Text("视频已生成 · 点击播放")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.blue)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .fullScreenCover(item: Binding(
            get: { videoURL.map { VideoItem(url: $0) } },
            set: { videoURL = $0?.url })) { item in
            VideoPlayerView(url: item.url)
        }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(m.suggestions, id: \.self) { s in
                    Button {
                        onSuggest?(s)
                    } label: {
                        Text(s)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.labelSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct VideoItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct VideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .padding(16)
            }
        }
    }
}
