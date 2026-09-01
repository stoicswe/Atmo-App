import Foundation
import Observation
import ATProtoKit

// MARK: - Post Thread Payload
/// A value snapshot of everything the composer wants published — taken at
/// the moment the user hits Post, so the composer can dismiss immediately
/// while PostPublisher works from the copy.
public struct PostThreadPayload: Sendable {
    public struct Slot: Sendable {
        public let text: String
        public let images: [Image]
        public let video: PostSlot.VideoAttachment?
        public let gif: GIFItem?

        public struct Image: Sendable {
            public let data: Data
            public let fileName: String
            public let altText: String

            public init(data: Data, fileName: String, altText: String) {
                self.data = data
                self.fileName = fileName
                self.altText = altText
            }
        }

        public init(text: String, images: [Image], video: PostSlot.VideoAttachment?, gif: GIFItem?) {
            self.text = text
            self.images = images
            self.video = video
            self.gif = gif
        }
    }

    public let slots: [Slot]
    public let replyTo: PostItem?
    public let quotedPost: PostItem?
    public let interactionSettings: PostInteractionSettings
    public let includeTranslationDisclosure: Bool

    public init(
        slots: [Slot],
        replyTo: PostItem?,
        quotedPost: PostItem?,
        interactionSettings: PostInteractionSettings,
        includeTranslationDisclosure: Bool
    ) {
        self.slots = slots
        self.replyTo = replyTo
        self.quotedPost = quotedPost
        self.interactionSettings = interactionSettings
        self.includeTranslationDisclosure = includeTranslationDisclosure
    }

    /// Short first-slot preview for status surfaces (pill, Live Activity).
    public var summary: String {
        let text = slots.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return String(text.prefix(80)) }
        if slots.first?.video?.isVoiceMemo == true { return "Voice memo" }
        if slots.first?.video != nil { return "Video post" }
        if slots.first?.images.isEmpty == false { return "Photo post" }
        if slots.first?.gif != nil { return "GIF post" }
        return "New post"
    }
}

// MARK: - Post Publisher
/// Publishes a composed thread: resolves media references (transcoding a
/// picked video, rendering a voice memo) through the platform seam, then
/// creates the post records in order.
///
/// Two entry points share one engine:
///   • `publishNow` — awaited inline by the composer (macOS keeps the
///     in-sheet spinner).
///   • `enqueue` — fire-and-forget for iOS: the composer dismisses at
///     once and the observable phase/progress state drives the in-app
///     status pill and the Live Activity (via `onUpdate`). On failure the
///     text is saved back to Drafts so nothing is lost.
@Observable
@MainActor
public final class PostPublisher {

    public static let shared = PostPublisher()

    // MARK: Observable state (latest job)

    public enum Phase: Equatable, Sendable {
        case idle
        /// Transcoding / rendering a slot's media reference.
        case preparingMedia(slot: Int, of: Int)
        /// Uploading + creating the record for one slot.
        case posting(slot: Int, of: Int)
        case finished
        case failed(message: String)
    }

    public private(set) var phase: Phase = .idle
    /// 0…1 across all steps of the current job.
    public private(set) var progress: Double = 0
    public private(set) var isPublishing = false
    /// First-slot preview of the job being published.
    public private(set) var summary: String = ""

    /// One progress snapshot, delivered on every phase change — the Apple
    /// layer forwards these to the Live Activity.
    public struct Update: Sendable {
        public let summary: String
        public let stageDescription: String
        public let progress: Double
        public let isFinished: Bool
        public let isFailed: Bool
    }

    /// Set by the app layer to mirror progress into platform UI
    /// (Live Activity). Called on the main actor at every transition.
    public var onUpdate: (@MainActor (Update) -> Void)? = nil

    /// Set by the app layer to hold a background-execution assertion while
    /// a job runs (UIApplication background task on iOS). Called with
    /// `true` when a queued job starts, `false` when the queue drains.
    public var backgroundActivityHandler: (@MainActor (_ active: Bool) -> Void)? = nil

    /// Serializes queued jobs (a second Post while one is uploading).
    private var queueTail: Task<Void, Never>? = nil

    public init() {}

    // MARK: - Entry points

    /// Inline publish: runs the job and throws on failure. The caller owns
    /// error presentation (composer sheet stays open).
    public func publishNow(_ payload: PostThreadPayload, service: ATProtoService) async throws {
        beginJob(payload)
        do {
            try await run(payload, service: service)
            finishJob()
        } catch {
            failJob(message: Self.failureMessage(for: error), savedDraft: false)
            throw error
        }
    }

    /// Background publish: returns immediately; the job runs (after any
    /// already-queued jobs) with progress exposed via the observable state
    /// and `onUpdate`. On failure the thread's text is saved to Drafts.
    public func enqueue(_ payload: PostThreadPayload, service: ATProtoService) {
        let previous = queueTail
        queueTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.backgroundActivityHandler?(true)
            self.beginJob(payload)
            do {
                try await self.run(payload, service: service)
                self.finishJob()
            } catch {
                self.saveFailureDraft(payload)
                self.failJob(message: Self.failureMessage(for: error), savedDraft: true)
            }
            self.backgroundActivityHandler?(false)
        }
    }

    // MARK: - State bookkeeping

    private func beginJob(_ payload: PostThreadPayload) {
        isPublishing = true
        summary = payload.summary
        progress = 0
        setPhase(.posting(slot: 1, of: payload.slots.count))
    }

    private func finishJob() {
        progress = 1
        isPublishing = false
        setPhase(.finished)
    }

    private func failJob(message: String, savedDraft: Bool) {
        isPublishing = false
        let full = savedDraft ? message + " Your post was saved to Drafts." : message
        setPhase(.failed(message: full))
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onUpdate?(Update(
            summary: summary,
            stageDescription: Self.describe(newPhase),
            progress: progress,
            isFinished: newPhase == .finished,
            isFailed: { if case .failed = newPhase { return true }; return false }()
        ))
    }

    public static func describe(_ phase: Phase) -> String {
        switch phase {
        case .idle:
            return ""
        case .preparingMedia(let slot, let count):
            return count > 1 ? "Preparing media (post \(slot) of \(count))…" : "Preparing media…"
        case .posting(let slot, let count):
            return count > 1 ? "Posting \(slot) of \(count)…" : "Posting…"
        case .finished:
            return "Posted"
        case .failed(let message):
            return message
        }
    }

    private static func failureMessage(for error: Error) -> String {
        if error is UnsupportedMediaProcessor.Unsupported {
            return "This platform can't process video attachments."
        }
        return "Couldn't publish the post."
    }

    /// Content must survive a failed background publish — the composer is
    /// long gone. Everything goes back to Drafts: text, reply/quote
    /// context, image data (written to the composer media store), and the
    /// video/memo reference (its file was preserved through submission).
    private func saveFailureDraft(_ payload: PostThreadPayload) {
        let posts = payload.slots.map { slot in
            DraftPost(
                id: UUID(),
                text: slot.text,
                attachedImageFileNames: slot.images.map(\.fileName),
                images: slot.images.map { image in
                    let id = UUID()
                    ComposerMediaFiles.saveImage(image.data, id: id)
                    return DraftImageRef(id: id, fileName: image.fileName, altText: image.altText)
                },
                video: slot.video.map { video in
                    DraftVideoRef(
                        kind: video.isVoiceMemo ? .voiceMemo : .video,
                        filePath: video.fileURL.path,
                        duration: video.duration,
                        aspectWidth: video.aspectRatio?.width,
                        aspectHeight: video.aspectRatio?.height,
                        altText: video.altText
                    )
                }
            )
        }
        let draft = ComposerDraft(
            id: UUID(),
            posts: posts,
            replyToURI: payload.replyTo?.uri,
            quotedPostURI: payload.quotedPost?.uri,
            modifiedAt: Date()
        )
        guard !draft.isEmpty else { return }
        DraftStore.shared.save(draft)
    }

    // MARK: - The publish engine

    /// Total progress units for a job: one per slot post, plus one per
    /// slot whose media (video reference or images) needs processing first.
    private static func totalUnits(of payload: PostThreadPayload) -> Int {
        payload.slots.reduce(0) {
            $0 + 1 + (($1.video != nil || !$1.images.isEmpty) ? 1 : 0)
        }
    }

    private func run(_ payload: PostThreadPayload, service: ATProtoService) async throws {
        guard let bluesky = service.atProtoBluesky,
              let kit = service.atProtoKit else {
            throw AtmoError.notAuthenticated
        }

        let slotCount = payload.slots.count
        let totalUnits = Double(Self.totalUnits(of: payload))
        var unitsDone = 0.0

        // Build the reply reference for the first post in the thread.
        var firstReplyRef: AppBskyLexicon.Feed.PostRecord.ReplyReference? = nil
        if let replyPost = payload.replyTo,
           let session = try? await kit.getUserSession() {
            let strongRef = ComAtprotoLexicon.Repository.StrongReference(
                recordURI: replyPost.uri,
                cidHash: replyPost.cid
            )
            firstReplyRef = try await ATProtoTools().createReplyReference(
                from: strongRef,
                session: session
            )
        }

        // Post each slot in sequence. After the first, each post replies to
        // the previous one to form a proper AT Protocol thread.
        var previousRef: ComAtprotoLexicon.Repository.StrongReference? = nil
        var threadRootRef: ComAtprotoLexicon.Repository.StrongReference? = nil

        for (index, slot) in payload.slots.enumerated() {
            // ── Resolve media, if any ──
            // Videos transcode/render; images fit into the ~1 MB blob cap
            // (raw picker/camera bytes routinely exceed it, which failed
            // the whole post before this step existed).
            var preparedVideo: PreparedUploadVideo? = nil
            var imageQueries: [ATProtoTools.ImageQuery] = []
            if slot.video != nil || !slot.images.isEmpty {
                progress = unitsDone / totalUnits
                setPhase(.preparingMedia(slot: index + 1, of: slotCount))
                let processor = Atmo.platform.mediaProcessor

                if let video = slot.video {
                    preparedVideo = video.isVoiceMemo
                        ? try await processor.renderVoiceMemo(at: video.fileURL)
                        : try await processor.prepareVideo(at: video.fileURL)
                }

                for image in slot.images {
                    let prepared = try await processor.prepareImage(image.data)
                    // Re-encoded uploads are JPEG regardless of source.
                    let stem = image.fileName.split(separator: ".").first.map(String.init) ?? image.fileName
                    imageQueries.append(ATProtoTools.ImageQuery(
                        imageData: prepared.data,
                        fileName: stem + ".jpg",
                        altText: image.altText.isEmpty ? nil : image.altText,
                        aspectRatio: prepared.aspectRatio.map {
                            AppBskyLexicon.Embed.AspectRatioDefinition(width: $0.width, height: $0.height)
                        }
                    ))
                }
                unitsDone += 1
            }

            progress = unitsDone / totalUnits
            setPhase(.posting(slot: index + 1, of: slotCount))

            // Embed: quote only on first post; a video or images on any
            // post (mutually exclusive — PostSlot enforces it).
            let embed: ATProtoBluesky.EmbedIdentifier?
            if index == 0, let quoted = payload.quotedPost {
                let quoteRef = ComAtprotoLexicon.Repository.StrongReference(
                    recordURI: quoted.uri,
                    cidHash: quoted.cid
                )
                embed = .record(strongReference: quoteRef)
            } else if let video = slot.video, let prepared = preparedVideo {
                let ratio = prepared.aspectRatio ?? video.aspectRatio
                embed = .video(
                    video: prepared.data,
                    captions: nil,
                    altText: video.altText.isEmpty ? nil : video.altText,
                    aspectoRatio: ratio.map {
                        AppBskyLexicon.Embed.AspectRatioDefinition(width: $0.width, height: $0.height)
                    }
                )
            } else if let gif = slot.gif {
                // GIFs travel as external embeds pointing at the media
                // URL with ww/hh dimensions — the Bluesky convention.
                embed = .external(
                    url: gif.embedURL,
                    title: gif.title,
                    description: "Animated GIF",
                    thumbnailURL: gif.previewURL
                )
            } else if !imageQueries.isEmpty {
                embed = .images(images: imageQueries)
            } else {
                embed = nil
            }

            // Translation disclosure only on the first post.
            let postText = (index == 0 && payload.includeTranslationDisclosure)
                ? slot.text + ComposerViewModel.translationDisclosureSuffix
                : slot.text

            // Reply reference: first post uses the incoming replyRef;
            // subsequent posts reply to the previous slot's result.
            let replyRef: AppBskyLexicon.Feed.PostRecord.ReplyReference?
            if index == 0 {
                replyRef = firstReplyRef
            } else if let prev = previousRef, let root = threadRootRef {
                replyRef = AppBskyLexicon.Feed.PostRecord.ReplyReference(
                    root: root,
                    parent: prev
                )
            } else {
                replyRef = nil
            }

            let result = try await bluesky.createPostRecord(
                text: postText,
                locales: [Locale.current],
                replyTo: replyRef,
                embed: embed
            )
            unitsDone += 1
            progress = unitsDone / totalUnits

            let thisRef = ComAtprotoLexicon.Repository.StrongReference(
                recordURI: result.recordURI,
                cidHash: result.recordCID
            )
            previousRef = thisRef

            // The root of this thread is:
            //   • the replyRef's root (if replying to an existing thread), OR
            //   • this very first post (if starting a new thread)
            if index == 0 {
                threadRootRef = firstReplyRef?.root ?? thisRef

                // ── Interaction gates ──
                // Applied best-effort (try?): the post already exists at
                // this point, and failing a gate must not surface an
                // error that would tempt a duplicate resubmission.
                //
                // Threadgate (who can reply) — only meaningful on a NEW
                // thread's root; a reply can't gate someone else's thread.
                if payload.replyTo == nil, payload.interactionSettings.needsThreadgate {
                    var rules: [ATProtoBluesky.ThreadgateAllowRule] = []
                    if payload.interactionSettings.mentionedCanReply { rules.append(.allowMentions) }
                    if payload.interactionSettings.followingCanReply { rules.append(.allowFollowing) }
                    if payload.interactionSettings.followersCanReply { rules.append(.allowFollowers) }
                    // Empty rules == nobody can reply.
                    _ = try? await bluesky.createThreadgateRecord(
                        postURI: thisRef.recordURI,
                        replyControls: rules
                    )
                }

                // Postgate (quote control) — applies to any post.
                if !payload.interactionSettings.allowQuotePosts {
                    _ = try? await bluesky.createPostgateRecord(
                        postURI: thisRef.recordURI,
                        embeddingRules: [.disable]
                    )
                }
            }
        }

        // Referenced media files were composer-owned temp copies — done
        // with them once every slot is out.
        for slot in payload.slots {
            if let video = slot.video {
                try? FileManager.default.removeItem(at: video.fileURL)
            }
        }

        // Notify observers (e.g. ProfileViewModel) that a new post was
        // submitted so they can refresh without a full app reload.
        NotificationCenter.default.post(name: .atmoDidSubmitPost, object: nil)
    }
}
