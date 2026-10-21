// The Linux details pane: the selected paper's metadata, episode, actions and conversion state.

#if os(Linux)
import Foundation
import SwiftCrossUI

/// The selected paper: what it is, where its conversion stands, its episode
/// and what can be done with it, like the macOS inspector.
struct DetailPane: View {
    @State var bridge: StoreBridge

    var body: some View {
        if let paper = bridge.store.selectedPaper() {
            PaperDetail(bridge: bridge, paper: paper)
        } else {
            VStack(spacing: 6) {
                Text(LibraryPresentation.noSelection.title).font(.headline)
                Text(LibraryPresentation.noSelection.message).foregroundColor(.gray)
            }
            .padding(24)
        }
    }
}

/// One paper's details, below the pane's empty state.
struct PaperDetail: View {
    var bridge: StoreBridge
    var paper: Paper

    var body: some View {
        let store = bridge.store
        let player = store.player
        let isLoaded = store.playingPaperId == paper.id
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CoverView(bridge: bridge, paperId: paper.id, width: 120, height: 156)
                VStack(alignment: .leading, spacing: 6) {
                    Text(paper.displayTitle).font(.title2)
                    Text(PaperPresentation.authorLine(paper.authors)).foregroundColor(.gray)
                    if let published = PaperPresentation.publishedDate(paper) {
                        Text(published).font(.caption).foregroundColor(.gray)
                    }
                    Text(PaperPresentation.statusText(paper)).font(.caption)
                    if !paper.tags.isEmpty {
                        Text(paper.tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundColor(.blue)
                    }
                }
            }

            if PaperPresentation.showsConversionCard(paper) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Conversion")).font(.headline)
                    if paper.isError {
                        Text(PaperPresentation.failureMessage(paper)).foregroundColor(.red)
                    } else {
                        HStack {
                            Text(ImportProgressPresentation.stage(paper))
                            Spacer()
                            Text(ConversionPresentation.percentLabel(paper.progress)).foregroundColor(.gray)
                        }
                        ProgressView("", value: ConversionPresentation.barValue(paper.progress))
                    }
                }
            }

            if PaperPresentation.showsEpisodeCard(paper) {
                let progress = EpisodeProgress(paper: paper, isLoaded: isLoaded, playerTime: player.currentTime,
                                               playerDuration: player.duration, playerIsPlaying: player.isPlaying)
                let play = PaperPresentation.playButton(paper, isPlaying: isLoaded && player.isPlaying)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Episode")).font(.headline)
                    HStack {
                        Text(progress.headline)
                        Spacer()
                        Text(progress.percentLabel ?? "").foregroundColor(.gray)
                    }
                    ProgressView("", value: progress.fraction)
                    Button(play.title) { store.togglePlayback(paper.id) }
                        .disabled(!PaperPresentation.isPlayable(paper))
                    if let warning = PaperPresentation.liveAudioWarning(paper) {
                        Text(warning).font(.caption).foregroundColor(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(PaperPresentation.favoriteButton(paper).title) { store.toggleFavorite(paper.id) }
                Button(PaperPresentation.listenedToggle(paper).title) { store.toggleRead(paper.id) }
                Button(L("Open PDF")) { store.openPDF(paper.id) }
                    .disabled(!paper.hasPdf)
                if store.isStandalone {
                    Button(L("Show in Files")) { store.revealInFinder(paper.id) }
                }
            }
            HStack(spacing: 8) {
                Button(L("Rerun…")) { store.requestRerun(paper) }
                    .disabled(!PaperPresentation.canRerun(paper))
                Button(L("Delete…")) { store.pendingConfirmation = .delete(paper) }
            }
        }
        .padding(20)
    }
}
#endif
