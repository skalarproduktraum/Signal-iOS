//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

enum AvatarContext {
    case groupId(Data)
    case profile

    var key: String {
        switch self {
        case .groupId(let data): return "group.\(data.hexadecimalString)"
        case .profile: return "profile"
        }
    }
}

enum AvatarHistoryManager {

    static let keyValueStore = SDSKeyValueStore(collection: "AvatarHistory")

    static func models(for context: AvatarContext, transaction: SDSAnyReadTransaction) -> [AvatarModel] {
        var (models, icons) = persisted(for: context, transaction: transaction)

        let defaultIcons: [AvatarIcon]
        switch context {
        case .groupId: defaultIcons = AvatarIcon.defaultGroupIcons
        case .profile: defaultIcons = AvatarIcon.defaultProfileIcons
        }

        // Insert models for default icons that aren't persisted
        for icon in Set(defaultIcons).subtracting(icons).sorted(by: { $0.rawValue > $1.rawValue }) {
            models.append(.init(
                type: .icon(icon),
                theme: .forSeed(icon.rawValue)
            ))
        }

        return models
    }

    static func touchedModel(_ model: AvatarModel, in context: AvatarContext, transaction: SDSAnyWriteTransaction) {
        var (models, _) = persisted(for: context, transaction: transaction)

        models.removeAll { $0.identifier == model.identifier }
        models.insert(model, at: 0)

        let records: [AvatarRecord] = models.map { model in
            switch model.type {
            case .icon(let icon):
                owsAssertDebug(model.identifier == icon.rawValue)
                return AvatarRecord(kind: .icon, identifier: model.identifier, imageUrl: nil, text: nil, theme: model.theme.rawValue)
            case .image(let url):
                return AvatarRecord(kind: .image, identifier: model.identifier, imageUrl: url, text: nil, theme: model.theme.rawValue)
            case .text(let text):
                return AvatarRecord(kind: .text, identifier: model.identifier, imageUrl: nil, text: text, theme: model.theme.rawValue)
            }
        }

        do {
            try keyValueStore.setCodable(records, key: context.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to touch avatar history \(error)")
        }
    }

    static func deletedModel(_ model: AvatarModel, in context: AvatarContext, transaction: SDSAnyWriteTransaction) {
        var (models, _) = persisted(for: context, transaction: transaction)

        models.removeAll { $0.identifier == model.identifier }

        if case .image(let url) = model.type {
            OWSFileSystem.deleteFileIfExists(url.path)
        }

        let records: [AvatarRecord] = models.map { model in
            switch model.type {
            case .icon(let icon):
                owsAssertDebug(model.identifier == icon.rawValue)
                return AvatarRecord(kind: .icon, identifier: model.identifier, imageUrl: nil, text: nil, theme: model.theme.rawValue)
            case .image(let url):
                return AvatarRecord(kind: .image, identifier: model.identifier, imageUrl: url, text: nil, theme: model.theme.rawValue)
            case .text(let text):
                return AvatarRecord(kind: .text, identifier: model.identifier, imageUrl: nil, text: text, theme: model.theme.rawValue)
            }
        }

        do {
            try keyValueStore.setCodable(records, key: context.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to touch avatar history \(error)")
        }
    }

    static let appSharedDataDirectory = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
    static let imageHistoryDirectory = URL(fileURLWithPath: "AvatarHistory", isDirectory: true, relativeTo: appSharedDataDirectory)

    static func recordModelForImage(_ image: UIImage, in context: AvatarContext, transaction: SDSAnyWriteTransaction) -> AvatarModel? {
        OWSFileSystem.ensureDirectoryExists(imageHistoryDirectory.path)

        let identifier = UUID().uuidString
        let url = URL(fileURLWithPath: identifier + ".jpg", relativeTo: imageHistoryDirectory)

        // TODO: Make sure orphan data is cleaned up correctly
        let avatarData = OWSProfileManager.avatarData(forAvatarImage: image)
        do {
            try avatarData.write(to: url)
        } catch {
            owsFailDebug("Failed to record model for image \(error)")
            return nil
        }

        let model = AvatarModel(identifier: identifier, type: .image(url), theme: .default)
        touchedModel(model, in: context, transaction: transaction)
        return model
    }

    private static func persisted(
        for context: AvatarContext,
        transaction: SDSAnyReadTransaction
    ) -> (models: [AvatarModel], persistedIcons: Set<AvatarIcon>) {
        let records: [AvatarRecord]?

        do {
            records = try keyValueStore.getCodableValue(forKey: context.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to load persisted avatar records \(error)")
            records = nil
        }

        var icons = Set<AvatarIcon>()
        var models = [AvatarModel]()

        for record in records ?? [] {
            switch record.kind {
            case .icon:
                guard let icon = AvatarIcon(rawValue: record.identifier) else {
                    owsFailDebug("Invalid avatar icon \(record.identifier)")
                    continue
                }
                icons.insert(icon)
                models.append(.init(
                    identifier: record.identifier,
                    type: .icon(icon),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            case .image:
                guard let imageUrl = record.imageUrl, OWSFileSystem.fileOrFolderExists(url: imageUrl) else {
                    owsFailDebug("Invalid avatar image \(record.identifier)")
                    continue
                }
                models.append(.init(
                    identifier: record.identifier,
                    type: .image(imageUrl),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            case .text:
                guard let text = record.text else {
                    owsFailDebug("Missing avatar text")
                    continue
                }
                models.append(.init(
                    identifier: record.identifier,
                    type: .text(text),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            }
        }

        return (models, icons)
    }
}

// We don't encode an AvatarModel directly to future proof
// us against changes to AvatarIcon, AvatarType, etc. enums
// since Codable is brittle when it encounters things it
// doesn't know about.
private struct AvatarRecord: Codable {
    enum Kind: String, Codable {
        case icon, text, image
    }
    let kind: Kind
    let identifier: String
    let imageUrl: URL?
    let text: String?
    let theme: String
}