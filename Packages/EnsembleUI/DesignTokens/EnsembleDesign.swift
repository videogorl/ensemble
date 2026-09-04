import EnsembleDomain
import SwiftUI

/// Portable semantic design tokens shared by Ensemble's app clients.
public enum EnsembleDesign {
    public enum Spacing {
        public static let none: CGFloat = 0
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32

        public static let rowHorizontal: CGFloat = lg
        public static let rowVertical: CGFloat = sm
        public static let rowItemGap: CGFloat = md
        public static let detailGutter: CGFloat = 40
        public static let cardTextGap: CGFloat = xxs
        public static let cardGridGap: CGFloat = lg
        public static let cardRowGap: CGFloat = xl
        public static let chipHorizontal: CGFloat = md
        public static let chipVertical: CGFloat = 6
        public static let sheetRowVertical: CGFloat = 10
        public static let sheetOuterHorizontal: CGFloat = xxxl
        public static let sheetOuterVertical: CGFloat = 28
        public static let sheetSectionPadding: CGFloat = 18
        public static let popoverActionHorizontal: CGFloat = 14
        public static let popoverActionVertical: CGFloat = 9
        public static let compactControlVertical: CGFloat = 10
    }

    public enum Radius {
        public static let control: CGFloat = 10
        public static let compactControl: CGFloat = 8
        public static let card: CGFloat = 12
        public static let sheet: CGFloat = 20
        public static let chip: CGFloat = 20
        public static let miniPlayer: CGFloat = 28
        public static let toolbarPill: CGFloat = 28

        public static func artworkSquare(for dimension: CGFloat) -> CGFloat {
            guard dimension > 0 else { return 4 }
            return min(max(dimension * 0.08, 4), 20)
        }

        public static func artworkCircle(for dimension: CGFloat) -> CGFloat {
            max(0, dimension / 2)
        }
    }

    public enum Color {
        public static let primaryText = SwiftUI.Color.primary
        public static let secondaryText = SwiftUI.Color.secondary
        public static let mutedPrimaryText = SwiftUI.Color.primary.opacity(0.7)
        public static let placeholderText = SwiftUI.Color.secondary
        public static let accent = SwiftUI.Color.accentColor
        public static let accentSelection = SwiftUI.Color.accentColor.opacity(0.12)
        public static let accentBadge = SwiftUI.Color.accentColor.opacity(0.15)
        public static let neutralBadge = SwiftUI.Color.secondary.opacity(0.15)
        public static let secondaryControlFill = SwiftUI.Color.gray.opacity(0.2)
        public static let subtleFill = SwiftUI.Color.secondary.opacity(0.18)
        public static let destructive = SwiftUI.Color.red
        public static let warning = SwiftUI.Color.orange
        public static let pending = SwiftUI.Color.yellow
        public static let success = SwiftUI.Color.green
        public static let neutralStatus = SwiftUI.Color.gray
        public static let favorite = SwiftUI.Color.pink
        public static let generated = SwiftUI.Color.purple
        public static let addToPlaylist = SwiftUI.Color.orange
        public static let onAccent = SwiftUI.Color.white
        public static let onArtwork = SwiftUI.Color.white.opacity(0.9)
        public static let divider = SwiftUI.Color.secondary.opacity(0.18)
        public static let placeholderArtwork = SwiftUI.Color.primary.opacity(0.1)
        public static let placeholderArtworkIcon = SwiftUI.Color.gray.opacity(0.5)
        public static let modalProgressScrim = SwiftUI.Color.black.opacity(0.12)
    }

    public enum Icon {
        public static let add = "plus"
        public static let addCircle = "plus.circle.fill"
        public static let addCircleOutline = "plus.circle"
        public static let addToPlaylist = "text.badge.plus"
        public static let removeFromPlaylist = "text.badge.minus"
        public static let album = "square.stack"
        public static let artist = "music.mic"
        public static let artists = artist
        public static let autoplay = "infinity.circle.fill"
        public static let back = "chevron.left"
        public static let chevronDown = "chevron.down"
        public static let chevronRight = "chevron.right"
        public static let chevronUp = "chevron.up"
        public static let checkmark = "checkmark.circle.fill"
        public static let checkmarkOutline = "checkmark.circle"
        public static let cloud = "icloud"
        public static let selectionCheckmark = "checkmark"
        public static let close = "xmark"
        public static let closeCircle = "xmark.circle.fill"
        public static let copy = "doc.on.doc"
        public static let delete = "trash"
        public static let download = "arrow.down.circle"
        public static let downloaded = "arrow.down.circle.fill"
        public static let dragReorder = "line.3.horizontal"
        public static let dragHandle = "circle.grid.2x3.fill"
        public static let edit = "pencil"
        public static let editPlaylist = "slider.horizontal.3"
        public static let error = "exclamationmark.triangle.fill"
        public static let errorOutline = "exclamationmark.triangle"
        public static let failure = "xmark.octagon.fill"
        public static let externalLink = "arrow.up.forward.app"
        public static let externalLinkSquare = "arrow.up.right.square"
        public static let favorite = "heart"
        public static let favoriteFilled = "heart.fill"
        public static let favoriteRemove = "heart.slash"
        public static let favoriteRemoveFilled = "heart.slash.fill"
        public static let filter = "line.3.horizontal.decrease"
        public static let filterCircle = "line.3.horizontal.decrease.circle"
        public static let filterCircleFilled = "line.3.horizontal.decrease.circle.fill"
        public static let forward = "forward.fill"
        public static let generatedBadge = "sparkles"
        public static let genre = "music.note.list"
        public static let genreEmpty = "guitars"
        public static let library = "music.note.house.fill"
        public static let libraryBuilding = "building.columns"
        public static let home = "house"
        public static let logs = "doc.text.magnifyingglass"
        public static let logsVerified = "text.badge.checkmark"
        public static let merge = "arrow.triangle.merge"
        public static let more = "ellipsis"
        public static let moreCircle = "ellipsis.circle"
        public static let musicNote = "music.note"
        public static let notification = "bell.fill"
        public static let notificationBadge = "bell.badge"
        public static let next = "forward.fill"
        public static let offline = "wifi.slash"
        public static let recentSearchReuse = "arrow.up.left"
        public static let removeAccounts = "person.2.slash"
        public static let removeCircle = "minus.circle"
        public static let selectionCircle = "circle"
        public static let server = "server.rack"
        public static let pin = "pin.fill"
        public static let playLast = "text.append"
        public static let playNext = "text.insert"
        public static let play = "play.fill"
        public static let playCircleFilled = "play.circle.fill"
        public static let pause = "pause.fill"
        public static let pauseCircleFilled = "pause.circle.fill"
        public static let profile = "person.crop.circle"
        public static let profilePlaceholder = "person.circle"
        public static let playlist = "music.note.list"
        public static let previous = "backward.fill"
        public static let radio = "dot.radiowaves.left.and.right"
        public static let recentPlaylist = "clock.arrow.circlepath"
        public static let refreshCycle = "arrow.triangle.2.circlepath"
        public static let removeDownload = "xmark.circle"
        public static let retry = "arrow.clockwise"
        public static let search = "magnifyingglass"
        public static let settings = "gear"
        public static let signIn = "person.circle.fill"
        public static let shareAudioFile = "square.and.arrow.up"
        public static let shareLink = "link"
        public static let shuffle = "shuffle"
        public static let smartPlaylist = "gearshape.fill"
        public static let sort = "arrow.up.arrow.down"
        public static let speakerPlaying = "speaker.wave.3.fill"
        public static let unpin = "pin.slash"
        public static let aurora = "sparkles"
        public static let scrobble = "checkmark.circle"
        public static let waveform = "waveform"
        public static let secureConnection = "lock.shield"
        public static let info = "info.circle"
        public static let help = "questionmark.circle"
        public static let ticket = "ticket.fill"
        public static let lyrics = "quote.bubble.fill"
        public static let infinity = "infinity"
        public static let clock = "clock"
        public static let unknown = "questionmark.circle"
        public static let libraryStack = "square.stack.3d.up"
        public static let paintPalette = "paintpalette"
        public static let tapGesture = "hand.tap"
        public static let saveQueue = "square.and.arrow.down"
        public static let instrumentalOn = "mic.slash.circle"
        public static let instrumentalOff = "mic.circle"
        public static let lyricsUnavailable = "text.quote"
        public static let scrubFine = "minus"
        public static let scrubUp = "chevron.compact.up"
        public static let scrubDown = "chevron.compact.down"
        public static let trackActions = more
        public static let trackActionsCircle = moreCircle

        public static let airPlayAudio = "airplayaudio"
        public static let devicePhone = "iphone"
        public static let deviceWatch = "applewatch"
        public static let librarySelections = "books.vertical"
        public static let linkCircle = "link.circle"
        public static let linkCircleFilled = "link.circle.fill"
        public static let plexLinkCode = "key"
        public static let queue = "list.bullet"
        public static let repeatMode = "repeat"
    }
}

public extension AppAccentColor {
    var color: SwiftUI.Color {
        switch self {
        case .purple: return .purple
        case .blue: return .blue
        case .pink: return SwiftUI.Color(red: 1, green: 0, blue: 1)
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        }
    }
}
